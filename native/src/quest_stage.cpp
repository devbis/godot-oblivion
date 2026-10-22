#include "oblivion/quest_stage.hpp"

#include <cctype>
#include <optional>

#include "oblivion/quest_runtime.hpp"

namespace oblivion {
namespace {

std::string lower_text(std::string text) {
    for (auto& c : text) c = static_cast<char>(std::tolower(static_cast<unsigned char>(c)));
    return text;
}

// Records every command as an action and answers it with 0.
class RecordingStageHost final : public ScriptHost {
public:
    RecordingStageHost(const QuestRecord& quest, unsigned stage, const ScriptRecord* quest_script, const QuestState& state)
        : quest_(quest.form_id), stage_(stage), quest_script_(quest_script), state_(state), quest_key_(lower(quest.editor_id)) {}

    std::vector<ScriptAction> actions;

    std::optional<ScriptValue> call_command(std::string_view name, const ScriptValue* target,
                                            const std::vector<ScriptValue>& arguments) override {
        ScriptAction action;
        action.command = std::string(name);
        if (target) action.target = target->text;
        action.arguments = arguments;
        actions.push_back(std::move(action));
        return ScriptValue::from_number(0.0);
    }

    std::optional<double> call_condition(std::uint16_t function_index, std::uint32_t parameter1, std::uint32_t parameter2) override {
        constexpr std::uint16_t kGetStage = 58;          // opcode 0x103A
        constexpr std::uint16_t kGetQuestVariable = 79;  // opcode 0x104F
        if (function_index == kGetStage && parameter1 == quest_) return static_cast<double>(stage_);
        if (function_index == kGetQuestVariable && parameter1 == quest_ && quest_script_) {
            // The index is the SLSD index of the variable in the quest script. An index the script does
            // not declare names no variable, and reads as 0.
            for (const auto& variable : quest_script_->variables) {
                if (variable.index != parameter2) continue;
                const auto found = state_.variables.find(quest_key_ + "." + lower(variable.name));
                return found == state_.variables.end() ? 0.0 : found->second;
            }
            return 0.0;
        }
        return std::nullopt;
    }

private:
    static std::string lower(std::string text) {
        for (auto& c : text) c = static_cast<char>(std::tolower(static_cast<unsigned char>(c)));
        return text;
    }

    std::uint32_t quest_;
    unsigned stage_;
    const ScriptRecord* quest_script_;
    const QuestState& state_;
    std::string quest_key_;
};

} // namespace

std::vector<StageEntryRun> run_quest_stage(const QuestRecord& quest, unsigned stage_index,
                                           const ScriptCommandLookup& lookup, const ScriptRecord* quest_script,
                                           QuestState& state) {
    std::vector<StageEntryRun> runs;
    const QuestStage* stage = nullptr;
    for (const auto& candidate : quest.stages)
        if (candidate.index == stage_index) stage = &candidate;
    if (!stage) return runs;

    // Fragments run with no script of their own; the interpreter only needs a script to outlive it.
    const ScriptAst no_script;
    ScriptInterpreter interpreter(no_script);
    const auto quest_prefix = lower_text(quest.editor_id) + ".";
    for (const auto& entry : stage->entries) {
        StageEntryRun run;
        run.completes = entry.completes;
        run.log_text = entry.log_text;
        RecordingStageHost host(quest, stage_index, quest_script, state);
        run.conditions_hold = evaluate_conditions(entry.conditions, host, &run.missing_conditions);
        if (run.conditions_hold) {
            // Quest variables set by earlier runs are visible to this fragment, and its writes are kept.
            for (const auto& [key, value] : state.variables)
                if (key.compare(0, quest_prefix.size(), quest_prefix) == 0) interpreter.set_variable(key, ScriptValue::from_number(value));
            const auto fragment = parse_fragment(entry.result_source, lookup);
            for (const auto& diagnostic : fragment.diagnostics)
                run.parse_errors.push_back("line " + std::to_string(diagnostic.line) + ": " + diagnostic.message);
            interpreter.run_body(fragment.statements, host);
            for (const auto& [key, value] : interpreter.variables())
                if (key.compare(0, quest_prefix.size(), quest_prefix) == 0 && value.is_text == false)
                    state.variables[key] = value.number;
            run.actions = std::move(host.actions);
        }
        runs.push_back(std::move(run));
    }
    return runs;
}

} // namespace oblivion
