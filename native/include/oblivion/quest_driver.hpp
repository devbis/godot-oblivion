#pragma once

#include <cstdint>
#include <functional>
#include <optional>
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

private:
    friend class QuestTickHost;

    const QuestRecord& quest_;
    const ScriptRecord& script_;
    ScriptCommandLookup lookup_;
    ScriptAst ast_;
    unsigned stage_ = 0;
    QuestState state_;

    void append_stage_runs(unsigned stage, QuestTick& tick, const DistanceFunction& distance, int depth);
};

} // namespace oblivion
