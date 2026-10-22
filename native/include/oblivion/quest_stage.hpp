#pragma once

#include <cstdint>
#include <functional>
#include <map>
#include <optional>
#include <string>
#include <utility>
#include <vector>

#include "oblivion/script_interpreter.hpp"
#include "oblivion/script_parser.hpp"
#include "oblivion/script_records.hpp"

namespace oblivion {

// A game command a stage result asked for, with its resolved target and arguments.
struct ScriptAction {
    std::string command;
    std::string target;  // the reference of a member call, empty for a plain call
    std::vector<ScriptValue> arguments;
};

// Quest variables that persist between stage runs, keyed by lowercase "quest.variable".
// Stage scripts write them with `set quest.variable to …`; GetQuestVariable reads them.
struct QuestState {
    std::map<std::string, double> variables;
};

// The value of a variable of another quest (by quest and variable name), or nullopt when that quest or variable is unknown.
using ForeignVariableReader = std::function<std::optional<double>(std::string_view quest, std::string_view variable)>;

struct StageEntryRun {
    bool conditions_hold = false;
    bool completes = false;
    std::string log_text;
    std::vector<ScriptAction> actions;
    std::vector<std::string> parse_errors;      // "line N: message"
    std::vector<std::string> missing_conditions;  // condition functions the runner does not answer
    std::vector<std::pair<std::string, double>> foreign_writes;  // "quest.variable" of other quests, set by the run
};

// Runs every entry of one stage of a quest, as if the quest were in that stage.
// Conditions are evaluated: GetStage of this quest answers `stage_index`, other
// condition functions are not answered (their conditions are false and reported).
// Result scripts run in order, and each command call is recorded as an action
// and answered with 0, so a script's arithmetic on command results is not
// meaningful yet. Commands are named and resolved through `lookup`.
// `quest_script` is the quest's SCRI script (its variables are the quest variables) and may be null.
// `read_foreign` answers reads of other quests' variables (`Quest.variable`); writes to them are returned in
// each run's foreign_writes for the caller to apply, since the other quests' state is not known here.
std::vector<StageEntryRun> run_quest_stage(const QuestRecord& quest, unsigned stage_index,
                                           const ScriptCommandLookup& lookup, const ScriptRecord* quest_script,
                                           QuestState& state, const ForeignVariableReader& read_foreign = {});

} // namespace oblivion
