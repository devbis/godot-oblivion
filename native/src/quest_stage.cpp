#include "oblivion/quest_stage.hpp"

#include <optional>

#include "oblivion/quest_runtime.hpp"

namespace oblivion {
namespace {

// Records every command as an action and answers it with 0.
class RecordingStageHost final : public ScriptHost {
public:
    RecordingStageHost(std::uint32_t quest, unsigned stage) : quest_(quest), stage_(stage) {}

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

    std::optional<double> call_condition(std::uint16_t function_index, std::uint32_t parameter1, std::uint32_t) override {
        constexpr std::uint16_t kGetStage = 58;  // opcode 0x103A
        if (function_index == kGetStage && parameter1 == quest_) return static_cast<double>(stage_);
        return std::nullopt;
    }

private:
    std::uint32_t quest_;
    unsigned stage_;
};

} // namespace

std::vector<StageEntryRun> run_quest_stage(const QuestRecord& quest, unsigned stage_index,
                                           const ScriptCommandLookup& lookup) {
    std::vector<StageEntryRun> runs;
    const QuestStage* stage = nullptr;
    for (const auto& candidate : quest.stages)
        if (candidate.index == stage_index) stage = &candidate;
    if (!stage) return runs;

    // Fragments run with no script of their own; the interpreter only needs a script to outlive it.
    const ScriptAst no_script;
    ScriptInterpreter interpreter(no_script);
    for (const auto& entry : stage->entries) {
        StageEntryRun run;
        run.completes = entry.completes;
        run.log_text = entry.log_text;
        RecordingStageHost host(quest.form_id, stage_index);
        run.conditions_hold = evaluate_conditions(entry.conditions, host, &run.missing_conditions);
        if (run.conditions_hold) {
            const auto fragment = parse_fragment(entry.result_source, lookup);
            for (const auto& diagnostic : fragment.diagnostics)
                run.parse_errors.push_back("line " + std::to_string(diagnostic.line) + ": " + diagnostic.message);
            interpreter.run_body(fragment.statements, host);
            run.actions = std::move(host.actions);
        }
        runs.push_back(std::move(run));
    }
    return runs;
}

} // namespace oblivion
