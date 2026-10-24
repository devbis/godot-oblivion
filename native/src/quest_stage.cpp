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

// Records every command as an action and answers it with 0 unless a stage command-value callback supplies a result.
class RecordingStageHost final : public ScriptHost {
public:
    RecordingStageHost(const QuestRecord& quest, unsigned stage, const ScriptRecord* quest_script, QuestState& state,
                       const ForeignVariableReader& read_foreign, const PickIdleHook& pick_idle,
                       const StageCommandValue& command_value)
        : quest_(quest.form_id), stage_(stage), quest_script_(quest_script), state_(state), quest_key_(lower(quest.editor_id)),
          read_foreign_(read_foreign), pick_idle_(pick_idle), command_value_(command_value) {}

    std::vector<ScriptAction> actions;
    ScriptInterpreter* interpreter = nullptr;  // set by the runner; bare quest variables are kept in step through it

    std::optional<ScriptValue> call_command(std::string_view name, const ScriptValue* target,
                                            const std::vector<ScriptValue>& arguments) override {
        // `Quest.variable` with no arguments reads a quest variable: this quest's own, or another quest's.
        if (target && target->is_text && arguments.empty()) {
            if (lower(target->text) == quest_key_ && quest_script_) {
                for (const auto& variable : quest_script_->variables) {
                    if (lower(variable.name) != lower(std::string(name))) continue;
                    const auto found = state_.variables.find(quest_key_ + "." + lower(variable.name));
                    return ScriptValue::from_number(found == state_.variables.end() ? 0.0 : found->second);
                }
            } else if (read_foreign_) {
                if (const auto value = read_foreign_(target->text, name)) return ScriptValue::from_number(*value);
            }
        }
        if (pick_idle_ && lower(std::string(name)) == "pickidle") {
            // The idle depends on the quest variables set so far (characterGen.uniqueIdle): bring them into the state first.
            if (interpreter) {
                const auto prefix = quest_key_ + ".";
                for (const auto& [key, value] : interpreter->variables())
                    if (!value.is_text && key.compare(0, prefix.size(), prefix) == 0) state_.variables[key] = value.number;
            }
            actions.push_back(pick_idle_(target && target->is_text ? target->text : std::string()));
            return ScriptValue::from_number(0.0);
        }
        if (command_value_) {
            const auto lowered_name = lower(std::string(name));
            if ((lowered_name == "say" || lowered_name == "sayto") && interpreter) {
                const auto prefix = quest_key_ + ".";
                for (const auto& [key, value] : interpreter->variables())
                    if (!value.is_text && key.compare(0, prefix.size(), prefix) == 0) state_.variables[key] = value.number;
            }
            if (const auto value = command_value_(name, target, arguments)) {
                ScriptAction action;
                action.command = std::string(name);
                if (target) action.target = target->text;
                action.arguments = arguments;
                actions.push_back(std::move(action));
                return value;
            }
        }
        ScriptAction action;
        action.command = std::string(name);
        if (target) action.target = target->text;
        action.arguments = arguments;
        actions.push_back(std::move(action));
        return ScriptValue::from_number(0.0);
    }

    // A bare name that is one of the quest's variables and `quest.name` are the same variable: a write to one is
    // seen through the other, as in the quest's own GameMode.
    void variable_written(std::string_view name, const ScriptValue& value) override {
        if (!interpreter || value.is_text) return;
        const auto key = lower(std::string(name));
        const auto prefix = quest_key_ + ".";
        if (key.compare(0, prefix.size(), prefix) == 0) {
            const auto alias = key.substr(prefix.size());
            if (is_declared(alias)) interpreter->set_variable(alias, value);
        } else if (key.find('.') == std::string::npos && is_declared(key)) {
            interpreter->set_variable(prefix + key, value);
        }
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
    bool is_declared(const std::string& name) const {
        if (!quest_script_) return false;
        for (const auto& variable : quest_script_->variables)
            if (lower(variable.name) == name) return true;
        return false;
    }

    static std::string lower(std::string text) {
        for (auto& c : text) c = static_cast<char>(std::tolower(static_cast<unsigned char>(c)));
        return text;
    }

    std::uint32_t quest_;
    unsigned stage_;
    const ScriptRecord* quest_script_;
    QuestState& state_;
    std::string quest_key_;
    const ForeignVariableReader& read_foreign_;
    const PickIdleHook& pick_idle_;
    const StageCommandValue& command_value_;
};

} // namespace

std::vector<StageEntryRun> run_quest_stage(const QuestRecord& quest, unsigned stage_index,
                                           const ScriptCommandLookup& lookup, const ScriptRecord* quest_script,
                                           QuestState& state, const ForeignVariableReader& read_foreign,
                                           const PickIdleHook& pick_idle, const StageCommandValue& command_value) {
    std::vector<StageEntryRun> runs;
    const QuestStage* stage = nullptr;
    for (const auto& candidate : quest.stages)
        if (candidate.index == stage_index) stage = &candidate;
    if (!stage) return runs;

    const auto quest_prefix = lower_text(quest.editor_id) + ".";
    // The quest script's declarations say which of its variables are integers.
    std::vector<std::string> integer_names;
    if (quest_script) {
        for (const auto& declaration : parse_script(quest_script->source, lookup).declarations)
            if (declaration.type == "short" || declaration.type == "long" || declaration.type == "int")
                integer_names.push_back(lower_text(declaration.name));
    }
    for (const auto& entry : stage->entries) {
        StageEntryRun run;
        run.completes = entry.completes;
        run.log_text = entry.log_text;
        RecordingStageHost host(quest, stage_index, quest_script, state, read_foreign, pick_idle, command_value);
        run.conditions_hold = evaluate_conditions(entry.conditions, host, &run.missing_conditions);
        if (run.conditions_hold) {
            // Fragments run with no script of their own; the interpreter only needs a script to outlive it.
            const ScriptAst no_script;
            ScriptInterpreter interpreter(no_script);
            interpreter.set_trace(false);
            host.interpreter = &interpreter;
            // Quest variables are visible to this fragment, by `quest.name` and by the bare name, and its writes are kept.
            if (quest_script) {
                for (const auto& variable : quest_script->variables) {
                    const auto name = lower_text(variable.name);
                    const auto found = state.variables.find(quest_prefix + name);
                    const auto value = ScriptValue::from_number(found == state.variables.end() ? 0.0 : found->second);
                    interpreter.set_variable(name, value);
                    interpreter.set_variable(quest_prefix + name, value);
                }
            }
            for (const auto& [key, value] : state.variables)
                if (key.compare(0, quest_prefix.size(), quest_prefix) == 0) interpreter.set_variable(key, ScriptValue::from_number(value));
            for (const auto& name : integer_names) {
                interpreter.declare_integer(name);
                interpreter.declare_integer(quest_prefix + name);
            }
            const auto fragment = parse_fragment(entry.result_source, lookup);
            for (const auto& diagnostic : fragment.diagnostics)
                run.parse_errors.push_back("line " + std::to_string(diagnostic.line) + ": " + diagnostic.message);
            interpreter.run_body(fragment.statements, host);
            for (const auto& [key, value] : interpreter.variables()) {
                if (value.is_text) continue;
                // Bare names are the aliases of `quest.name`, which carries the value.
                if (key.compare(0, quest_prefix.size(), quest_prefix) == 0) state.variables[key] = value.number;
                else if (key.find('.') != std::string::npos) run.foreign_writes.emplace_back(key, value.number);
            }
            run.actions = std::move(host.actions);
        }
        runs.push_back(std::move(run));
    }
    return runs;
}

} // namespace oblivion
