#pragma once

#include <cstdint>
#include <functional>
#include <map>
#include <memory>
#include <optional>
#include <set>
#include <string>
#include <string_view>
#include <unordered_map>
#include <vector>

#include "oblivion/esm4_database.hpp"
#include "oblivion/quest_runtime.hpp"
#include "oblivion/quest_stage.hpp"
#include "oblivion/script_parser.hpp"
#include "oblivion/script_records.hpp"

namespace oblivion {

// Who a topic is spoken by and to. GetIsID is answered for the speaker or the listener; GetIsRace and
// GetIsSex are answered for the listener (the prisoner a taunt is addressed to).
struct DialogueContext {
    std::uint32_t speaker_base = 0;
    std::uint32_t listener_base = 0;
    std::uint32_t listener_race = 0;
    bool listener_female = false;
    // The idle manager asks about one actor: its base is both speaker and listener. `current_package` is the package
    // the actor runs now (GetIsCurrentPackage); `for_idle` makes MenuMode answer 0, as the game is not in a menu.
    bool for_idle = false;
    std::uint32_t current_package = 0;
};

// Distance between two named references, or nullopt when the world cannot answer.
using DistanceFunction = std::function<std::optional<double>(std::string_view from, std::string_view to)>;

struct QuestTick {
    unsigned stage = 0;                          // stage after this tick
    std::vector<std::string> stage_changes;      // stages entered during the tick, in order
    std::vector<ScriptAction> actions;           // stage results and GameMode calls, in order
    std::vector<std::string> unanswered;         // functions the driver could not answer (value 0)
    std::vector<std::string> parse_errors;
    unsigned stage_entries = 0;                  // stages entered so far in this tick, counted against kMaxStageEntriesPerTick
};

// Total stages one tick may enter, over every branch of its stage chains. The depth limit alone bounds a chain, but a
// stage that sets b stages each could still enter b^depth of them.
constexpr unsigned kMaxStageEntriesPerTick = 256;

struct TopicRun {
    const DialogResponse* reply = nullptr;  // the reply whose conditions held first, or null
    QuestTick tick;                          // what its result did
};

class QuestWorld;

// A parsed script of an actor or object, and the values of its variables between the events that run it. The script
// is parsed once; each event continues with the variables the previous one left.
struct CachedScript {
    std::string source;                       // what `ast` was parsed from; a changed source is parsed again
    ScriptAst ast;
    std::map<std::string, double> variables;  // lowercase name
};

class ScriptCache {
public:
    // The entry for a script record (by form ID and editor ID), parsed on first use.
    CachedScript& get(const ScriptRecord& script, const ScriptCommandLookup& lookup);

private:
    std::map<std::string, std::unique_ptr<CachedScript>> entries_;
};

// Drives one quest: keeps its stage and variables, runs the quest script's GameMode
// block on every tick, and runs a stage's results when the stage is set.
// Commands are recorded as actions for the caller to perform; the only answers the
// driver gives are GetStage, SetStage, GetSecondsPassed and GetDistance.
class QuestDriver {
public:
    QuestDriver(const QuestRecord& quest, const ScriptRecord& script, ScriptCommandLookup lookup);

    // Sets the first stage and runs its results.
    QuestTick start(unsigned stage, const DistanceFunction& distance = {});

    // Runs GameMode once, after `seconds_passed` has elapsed since the last tick.
    QuestTick tick(double seconds_passed, const DistanceFunction& distance = {});

    // Speaks a topic: the first reply, in order, whose conditions hold for this context runs its result.
    // `depth` counts the SayTo and SetStage hops that led here, and bounds the chain.
    TopicRun run_topic(const DialogTopic& topic, const DialogueContext& context, const DistanceFunction& distance = {},
                       int depth = 0);

    // Runs an event block of an actor's script (for example OnPackageDone with the package's name).
    // The actor's script may set this quest's stage, and the results of the new stage run.
    // `actor_base` is the NPC base the script belongs to: a PickIdle without a reference is for that actor.
    QuestTick run_actor_event(const ScriptRecord& actor_script, std::string_view event, std::string_view detail,
                              const DistanceFunction& distance = {}, std::uint32_t actor_base = 0);

    // The package an actor starts now: the first of its packages whose conditions hold, judged with this
    // quest in its current stage and state. Null when none holds.
    const AiPackageRecord* select_package(const std::vector<const AiPackageRecord*>& packages) const;

    unsigned stage() const { return stage_; }
    const QuestState& state() const { return state_; }
    QuestState& state() { return state_; }
    const QuestRecord& quest() const { return quest_; }

    // True once the quest has entered this stage (set, or passed through by a result).
    bool has_entered(unsigned stage) const { return entered_.count(stage) != 0; }

    // Enters a stage and runs its results. Used for SetStage, from this quest's own results or from another quest.
    void enter_stage(unsigned stage, QuestTick& tick, const DistanceFunction& distance, int depth);

    // The value of a quest variable by its SLSD index, or 0 when the script does not declare it.
    double variable_at(std::uint32_t index) const;

    // The value of a quest variable by name, or nullopt when the script does not declare it.
    std::optional<double> variable(std::string_view name) const;

    // The registry this quest belongs to, for stages and conditions of other quests.
    void attach(QuestWorld* world) { world_ = world; }
    const std::string& lower_editor_id() const { return lower_editor_id_; }

private:
    friend class QuestTickHost;

    ScriptCache& script_cache();

    const QuestRecord& quest_;
    const ScriptRecord& script_;
    ScriptCommandLookup lookup_;
    ScriptAst ast_;
    std::string lower_editor_id_;  // lowercase editor ID, and the "id." prefix of this quest's variable keys
    std::string prefix_;
    std::set<unsigned> running_stages_;  // stages whose results are running now: entering one again is a cycle
    ScriptCache own_scripts_;            // used when the quest belongs to no world
    unsigned stage_ = 0;
    QuestState state_;
    std::set<unsigned> entered_;
    QuestWorld* world_ = nullptr;
};

// The player's values in a fresh game, as far as the quests read them: full health, magicka and fatigue.
// Other values stay unanswered. A game with a real player state answers these itself.
std::optional<ScriptValue> answer_fresh_player(std::string_view command, const ScriptValue* target,
                                               const std::vector<ScriptValue>& arguments);

// The quests of the game that run together. A stage set in one quest, a stage or a variable read from
// another, and a started quest all go through here. Quests are found by editor ID or by form ID.
class QuestWorld {
public:
    // Answers the world commands a quest asks for, such as GetActorValue of the player. Nullopt leaves the command
    // unanswered: the quest records it and sees 0.
    using WorldAnswer = std::function<std::optional<ScriptValue>(std::string_view command, const ScriptValue* target,
                                                                 const std::vector<ScriptValue>& arguments)>;
    // Finds a dialogue topic by editor ID, for SayTo.
    using TopicFinder = std::function<const DialogTopic*(std::string_view editor_id)>;
    // Seconds a reply takes to say, from the speaker's base, the quest and topic, the reply's form ID and text; nullopt
    // when the scene does not know (the length is then estimated from the text).
    using SpeechLength = std::function<std::optional<double>(std::uint32_t speaker, std::string_view quest,
                                                             std::string_view topic, std::uint32_t reply, std::string_view text)>;

    explicit QuestWorld(ScriptCommandLookup lookup);

    // Registers a quest with its script. The quest does not run until it is started.
    QuestDriver& add(const QuestRecord& quest, const ScriptRecord& script);

    // Registers an actor whose script's GameMode runs on every tick, with its own variables. `form_id` is the NPC's base.
    void add_actor(std::uint32_t form_id, const ScriptRecord& script, std::string reference_name = {});

    // Drops actor scripts and reference mappings for the cell being unloaded. While the world runs (a callback of
    // the scene calls this in the middle of a tick) the change waits until the run ends.
    void clear_actors();

    QuestDriver* find(std::string_view editor_id);
    QuestDriver* find_form(std::uint32_t form_id);

    // Starts a registered quest at a stage and runs its results.
    QuestTick start(std::string_view editor_id, unsigned stage, const DistanceFunction& distance = {});

    // Runs GameMode of every started quest, then of every actor, once.
    QuestTick tick(double seconds_passed, const DistanceFunction& distance = {});

    // Enters a stage of a quest by name, and starts the quest if it was not running. Does nothing for an unknown quest.
    void set_stage(std::string_view editor_id, unsigned stage, QuestTick& tick, const DistanceFunction& distance, int depth);

    // StartQuest: enters the first stage of a quest that is not running yet. Does nothing otherwise.
    void begin(std::string_view editor_id, QuestTick& tick, const DistanceFunction& distance, int depth);

    // SayTo: the first reply of the topic whose conditions hold for this speaker and listener runs, and the
    // seconds it takes to speak are returned (0 when nothing is said).
    // `depth` counts the hops of the chain (SayTo, SetStage) that led here; a chain deeper than the limit stops.
    double say(std::string_view topic_editor_id, std::uint32_t speaker, std::uint32_t listener, QuestTick& tick,
               const DistanceFunction& distance, int depth = 0);

    // Runs an event of an object's script (OnTrigger with the player as the detail) in the world, as an actor's would run.
    QuestTick run_object_event(const ScriptRecord& script, std::string_view event, std::string_view detail,
                               const DistanceFunction& distance = {});

    // The NPC base a placed reference of the scene stands for, so that SayTo to the reference names its base.
    void set_reference_base(std::string_view reference, std::uint32_t base);
    std::optional<std::uint32_t> reference_base(std::string_view reference) const;

    // `Reference.variable = value` for an actor: the actor's own variable, taken by its GameMode run.
    // Returns false when no actor stands for the reference.
    bool set_actor_variable(std::string_view reference, std::string_view variable, double value);

    // The player as a listener: the race and sex that topic conditions read (GetIsRace, GetIsSex).
    void set_listener(std::uint32_t race, bool female) {
        listener_race_ = race;
        listener_female_ = female;
    }

    // The value of a GLOB record, for conditions compared against a global (CTDA "use global"). Nullopt: unknown,
    // and the condition counts as false.
    using GlobalValue = std::function<std::optional<double>(std::uint32_t form_id)>;
    // The idle manager: the idle tree PickIdle walks, and the race and sex of an NPC base (for GetIsRace and
    // GetIsSex in idle conditions). Without a tree PickIdle only records the command.
    using ActorTraits = std::function<std::optional<std::pair<std::uint32_t, bool>>(std::uint32_t base)>;
    void set_idle_tree(IdleChildren children) { idle_children_ = std::move(children); }
    void set_actor_traits(ActorTraits traits) { actor_traits_ = std::move(traits); }

    // The package a placed actor runs now, by reference name, for idle conditions (GetIsCurrentPackage).
    void set_actor_package(std::string_view reference, std::uint32_t package_form_id);

    // True once the quest has been started (StartQuest, SetStage or start()).
    bool is_started(const QuestDriver* driver) const { return started_.count(const_cast<QuestDriver*>(driver)) != 0; }

    // PickIdle for a reference (empty: the actor `speaker_base` stands for). Picks the first idle of the tree whose
    // conditions hold for that actor and the current quest state (see select_idle) and records the action
    // "pickidle": target is the reference, arguments are the .kf path, the IDLE editor ID, its form ID and its
    // group flags. When nothing matches the paths are empty and the form ID is 0: the actor returns to its default idle.
    const IdleRecord* pick_idle(std::string_view reference, std::uint32_t speaker_base, QuestTick& tick);

    void set_global_value(GlobalValue value) { global_value_ = std::move(value); }
    const GlobalValue& global_value() const { return global_value_; }

    void set_answer(WorldAnswer answer) { answer_ = std::move(answer); }
    const WorldAnswer& answer() const { return answer_; }

    // Parsed scripts and variables of the actor and object scripts that run events here.
    ScriptCache& script_cache() { return scripts_; }

    // Marks the world as running for its lifetime, so changes to the actors wait until the outermost run ends.
    class RunGuard {
    public:
        explicit RunGuard(QuestWorld& world) : world_(world) { ++world_.running_; }
        ~RunGuard() {
            if (--world_.running_ == 0) world_.apply_pending();
        }
        RunGuard(const RunGuard&) = delete;
        RunGuard& operator=(const RunGuard&) = delete;

    private:
        QuestWorld& world_;
    };

    void set_topic_finder(TopicFinder finder) { find_topic_ = std::move(finder); }
    void set_speech_length(SpeechLength length) { speech_length_ = std::move(length); }

private:
    struct ActorState {
        std::uint32_t form_id = 0;
        std::string reference_name;
        ScriptAst ast;
        std::map<std::string, double> variables;  // lowercase name, persists across ticks
        std::map<std::string, double> pending;    // written by other scripts during a run, not yet taken by it
    };

    void apply_pending();
    void run_or_defer(std::function<void()> change);
    void run_actor_game_mode(ActorState& actor, QuestTick& tick, double seconds_passed, const DistanceFunction& distance);

    ScriptCommandLookup lookup_;
    WorldAnswer answer_;
    GlobalValue global_value_;
    std::map<std::string, std::uint32_t> package_by_reference_;  // lowercase reference name -> package form ID
    IdleChildren idle_children_;
    ActorTraits actor_traits_;
    TopicFinder find_topic_;
    SpeechLength speech_length_;
    std::map<std::string, std::uint32_t> reference_bases_;  // lowercase reference name -> NPC base
    std::uint32_t listener_race_ = 0;
    bool listener_female_ = false;
    std::vector<std::unique_ptr<QuestDriver>> drivers_;
    std::vector<std::unique_ptr<ActorState>> actors_;
    std::set<QuestDriver*> started_;
    std::unordered_map<std::string, QuestDriver*> by_editor_id_;  // lowercase editor ID
    std::unordered_map<std::uint32_t, QuestDriver*> by_form_id_;
    ScriptCache scripts_;
    int running_ = 0;
    std::vector<std::function<void()>> pending_;
};

} // namespace oblivion
