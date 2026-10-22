#pragma once

#include <cstdint>
#include <functional>
#include <map>
#include <memory>
#include <optional>
#include <set>
#include <string>
#include <string_view>
#include <vector>

#include "oblivion/esm4_database.hpp"
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
};

// Distance between two named references, or nullopt when the world cannot answer.
using DistanceFunction = std::function<std::optional<double>(std::string_view from, std::string_view to)>;

struct QuestTick {
    unsigned stage = 0;                          // stage after this tick
    std::vector<std::string> stage_changes;      // stages entered during the tick, in order
    std::vector<ScriptAction> actions;           // stage results and GameMode calls, in order
    std::vector<std::string> unanswered;         // functions the driver could not answer (value 0)
    std::vector<std::string> parse_errors;
};

struct TopicRun {
    const DialogResponse* reply = nullptr;  // the reply whose conditions held first, or null
    QuestTick tick;                          // what its result did
};

class QuestWorld;

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
    TopicRun run_topic(const DialogTopic& topic, const DialogueContext& context, const DistanceFunction& distance = {});

    // Runs an event block of an actor's script (for example OnPackageDone with the package's name).
    // The actor's script may set this quest's stage, and the results of the new stage run.
    QuestTick run_actor_event(const ScriptRecord& actor_script, std::string_view event, std::string_view detail,
                              const DistanceFunction& distance = {});

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

private:
    friend class QuestTickHost;

    const QuestRecord& quest_;
    const ScriptRecord& script_;
    ScriptCommandLookup lookup_;
    ScriptAst ast_;
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

    explicit QuestWorld(ScriptCommandLookup lookup);

    // Registers a quest with its script. The quest does not run until it is started.
    QuestDriver& add(const QuestRecord& quest, const ScriptRecord& script);

    // Registers an actor whose script's GameMode runs on every tick, with its own variables. `form_id` is the NPC's base.
    void add_actor(std::uint32_t form_id, const ScriptRecord& script);

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
    double say(std::string_view topic_editor_id, std::uint32_t speaker, std::uint32_t listener, QuestTick& tick,
               const DistanceFunction& distance);

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

    void set_answer(WorldAnswer answer) { answer_ = std::move(answer); }
    const WorldAnswer& answer() const { return answer_; }

    void set_topic_finder(TopicFinder finder) { find_topic_ = std::move(finder); }

private:
    struct ActorState {
        std::uint32_t form_id = 0;
        ScriptAst ast;
        std::map<std::string, double> variables;  // lowercase name, persists across ticks
        std::map<std::string, double> pending;    // written by other scripts during a run, not yet taken by it
    };

    void run_actor_game_mode(ActorState& actor, QuestTick& tick, double seconds_passed, const DistanceFunction& distance);

    ScriptCommandLookup lookup_;
    WorldAnswer answer_;
    TopicFinder find_topic_;
    std::map<std::string, std::uint32_t> reference_bases_;  // lowercase reference name -> NPC base
    std::uint32_t listener_race_ = 0;
    bool listener_female_ = false;
    std::vector<std::unique_ptr<QuestDriver>> drivers_;
    std::vector<std::unique_ptr<ActorState>> actors_;
    std::set<QuestDriver*> started_;
};

} // namespace oblivion
