#pragma once

#include <cstddef>
#include <map>
#include <optional>
#include <set>
#include <string>
#include <string_view>
#include <vector>

#include "oblivion/script_ast.hpp"

namespace oblivion {

// A script value: a number (short, long, int, float) or text, which is how
// references, quests and other named game objects are passed to commands.
struct ScriptValue {
    double number = 0.0;
    std::string text;
    bool is_text = false;

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

    // Runs a statement list on its own, such as a quest stage's result script. Variables are
    // the script's; names that are not variables resolve to text for the host.
    ScriptRunResult run_body(const std::vector<ScriptStmt>& body, ScriptHost& host, const ScriptValue* target = nullptr);

    const std::map<std::string, ScriptValue>& variables() const { return variables_; }
    void set_variable(const std::string& name, ScriptValue value) { variables_[lower(name)] = std::move(value); }

    // Upper bound on statements per run, so a bad script cannot hang the game.
    void set_step_limit(std::size_t limit) { step_limit_ = limit; }

private:
    const ScriptAst& script_;
    std::map<std::string, ScriptValue> variables_;  // keyed by lowercase name
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
    static bool truthy(const ScriptValue& value) { return value.number != 0.0 || (value.is_text && !value.text.empty()); }
};

} // namespace oblivion
