#pragma once

#include <cstddef>
#include <map>
#include <optional>
#include <set>
#include <string>
#include <string_view>
#include <cstdint>
#include <vector>

#include "oblivion/script_ast.hpp"

namespace oblivion {

// A script value: a number (short, long, int, float) or text, which is how
// references, quests and other named game objects are passed to commands.
struct ScriptValue {
    double number = 0.0;
    std::string text;
    bool is_text = false;
    // A bare name that is no variable: text for the host to resolve (a quest, a reference), never a truth value.
    bool unresolved = false;

    static ScriptValue from_number(double value) {
        ScriptValue result;
        result.number = value;
        return result;
    }
    static ScriptValue from_text(std::string value) {
        ScriptValue result;
        result.text = std::move(value);
        result.is_text = true;
        return result;
    }
};

// The game side of a script. The interpreter knows the language; the host knows
// the world. A command the host does not implement returns nullopt, and the
// interpreter logs it once and continues with 0.
class ScriptHost {
public:
    virtual ~ScriptHost() = default;

    // `target` is the reference a member call is made on (`ref.Command`), or null.
    virtual std::optional<ScriptValue> call_command(std::string_view name, const ScriptValue* target,
                                                    const std::vector<ScriptValue>& arguments) = 0;

    // A CTDA condition function (for example GetStage with the quest as parameter1). Returns
    // nullopt when the host does not implement it; the condition then counts as false.
    virtual std::optional<double> call_condition(std::uint16_t function_index, std::uint32_t parameter1,
                                                 std::uint32_t parameter2) {
        static_cast<void>(function_index);
        static_cast<void>(parameter1);
        static_cast<void>(parameter2);
        return std::nullopt;
    }

    // Conditions with a TES4 runOn selector can use the actor the condition targets. Older hosts keep their existing
    // behavior through this default forwarding implementation.
    virtual std::optional<double> call_condition(std::uint16_t function_index, std::uint32_t parameter1,
                                                 std::uint32_t parameter2, std::uint32_t run_on) {
        static_cast<void>(run_on);
        return call_condition(function_index, parameter1, parameter2);
    }

    // The value of a GLOB record, for a condition compared against a global (CTDA "use global"). Returns
    // nullopt when the host does not know it; the condition then counts as false.
    virtual std::optional<double> global_value(std::uint32_t form_id) {
        static_cast<void>(form_id);
        return std::nullopt;
    }

    // Called after a script variable is assigned. Hosts can keep aliases or
    // externally persisted variables in sync with the interpreter.
    virtual void variable_written(std::string_view name, const ScriptValue& value) {
        static_cast<void>(name);
        static_cast<void>(value);
    }
};

struct ScriptRunResult {
    bool found_block = false;
    bool returned = false;      // a `return` ended the block
    bool step_limit_hit = false;
    std::vector<std::string> trace;          // one line per executed statement, with the source line
    std::vector<std::string> unimplemented;  // commands the host did not implement, each once
};

// Runs the blocks of one parsed script. Variables are created from the
// script's declarations, and undeclared names are created on first assignment.
class ScriptInterpreter {
public:
    explicit ScriptInterpreter(const ScriptAst& script);

    // Runs the first block whose name matches `event`, case-insensitively.
    ScriptRunResult run(std::string_view event, ScriptHost& host, const ScriptValue* target = nullptr);

    // Runs the block named `event` whose target is `detail` (for example OnPackageDone with the package's name).
    // Blocks without a target match only an empty detail.
    ScriptRunResult run_event(std::string_view event, std::string_view detail, ScriptHost& host, const ScriptValue* target = nullptr);

    // Runs a statement list on its own, such as a quest stage's result script. Variables are
    // the script's; names that are not variables resolve to text for the host.
    ScriptRunResult run_body(const std::vector<ScriptStmt>& body, ScriptHost& host, const ScriptValue* target = nullptr);

    const std::map<std::string, ScriptValue>& variables() const { return variables_; }
    void set_variable(const std::string& name, ScriptValue value) { variables_[lower(name)] = std::move(value); }

    // Marks a variable as a short or long: values assigned to it by `set` are truncated toward zero.
    // The script's own `short`, `long` and `int` declarations are marked already.
    void declare_integer(const std::string& name) { integers_.insert(lower(name)); }

    // The trace holds one line per executed statement and is costly to build; the game turns it off.
    void set_trace(bool enabled) { trace_enabled_ = enabled; }

    // Upper bound on statements per run, so a bad script cannot hang the game.
    void set_step_limit(std::size_t limit) { step_limit_ = limit; }

private:
    const ScriptAst& script_;
    std::map<std::string, ScriptValue> variables_;  // keyed by lowercase name
    std::set<std::string> integers_;                // lowercase names of short/long variables
    bool trace_enabled_ = true;
    std::size_t step_limit_ = 100000;
    std::size_t steps_ = 0;

    struct RunState {
        ScriptHost* host = nullptr;
        const ScriptValue* target = nullptr;
        ScriptRunResult* result = nullptr;
        std::set<std::string> reported;
        bool stop = false;
    };

    void run_statements(const std::vector<ScriptStmt>& statements, RunState& state);
    void run_statement(const ScriptStmt& statement, RunState& state);
    ScriptValue evaluate(const ScriptExpr& expr, RunState& state);
    ScriptValue call(const ScriptExpr& call, const ScriptValue* target, RunState& state);
    ScriptValue lookup_name(const std::string& name) const;

    static std::string lower(std::string_view text);
    static bool truthy(const ScriptValue& value) {
        if (value.unresolved) return false;
        return value.number != 0.0 || (value.is_text && !value.text.empty());
    }
};

} // namespace oblivion
