#include "oblivion/script_interpreter.hpp"

#include <cctype>
#include <cmath>
#include <cstdlib>
#include <sstream>

namespace oblivion {
namespace {

std::string describe(const ScriptValue& value) {
    if (value.is_text) return "\"" + value.text + "\"";
    std::ostringstream text;
    text << value.number;
    return text.str();
}

double number_of(const std::string& literal) {
    return std::strtod(literal.c_str(), nullptr);
}

// A short or long holds a 32-bit integer: the fraction is dropped, and what cannot be represented becomes 0 or the limit.
double truncate_integer(double value) {
    if (std::isnan(value)) return 0.0;
    constexpr double kLimit = 2147483647.0;
    if (value > kLimit) return kLimit;
    if (value < -kLimit) return -kLimit;
    return std::trunc(value);
}

// `a % b` on integers. A divisor that truncates to 0 or -1, and values that are not finite or do not fit, give 0:
// the hardware division would trap on them.
double integer_modulo(double a, double b) {
    if (!std::isfinite(a) || !std::isfinite(b)) return 0.0;
    constexpr double kLimit = 9.0e18;  // below the range of long long
    if (std::fabs(a) > kLimit || std::fabs(b) > kLimit) return 0.0;
    const auto divisor = static_cast<long long>(b);
    if (divisor == 0 || divisor == -1) return 0.0;
    return static_cast<double>(static_cast<long long>(a) % divisor);
}

} // namespace

std::string ScriptInterpreter::lower(std::string_view text) {
    std::string result(text);
    for (auto& c : result) c = static_cast<char>(std::tolower(static_cast<unsigned char>(c)));
    return result;
}

ScriptInterpreter::ScriptInterpreter(const ScriptAst& script) : script_(script) {
    for (const auto& declaration : script.declarations) {
        if (declaration.type == "short" || declaration.type == "long" || declaration.type == "int")
            integers_.insert(lower(declaration.name));
        // A `ref` holds a name (empty until set); the numeric types start at zero.
        if (declaration.type == "ref") variables_[lower(declaration.name)] = ScriptValue::from_text("");
        else variables_[lower(declaration.name)] = ScriptValue::from_number(0.0);
    }
}

ScriptRunResult ScriptInterpreter::run(std::string_view event, ScriptHost& host, const ScriptValue* target) {
    const auto wanted = lower(event);
    for (const auto& block : script_.blocks) {
        if (lower(block.name) != wanted) continue;
        auto result = run_body(block.body, host, target);
        result.found_block = true;
        return result;
    }
    return ScriptRunResult{};
}

ScriptRunResult ScriptInterpreter::run_event(std::string_view event, std::string_view detail, ScriptHost& host, const ScriptValue* target) {
    const auto wanted = lower(event);
    const auto wanted_detail = lower(detail);
    for (const auto& block : script_.blocks) {
        if (lower(block.name) != wanted || lower(block.target) != wanted_detail) continue;
        auto result = run_body(block.body, host, target);
        result.found_block = true;
        return result;
    }
    return ScriptRunResult{};
}

ScriptRunResult ScriptInterpreter::run_body(const std::vector<ScriptStmt>& body, ScriptHost& host, const ScriptValue* target) {
    ScriptRunResult result;
    steps_ = 0;
    RunState state;
    state.host = &host;
    state.target = target;
    state.result = &result;
    run_statements(body, state);
    return result;
}

void ScriptInterpreter::run_statements(const std::vector<ScriptStmt>& statements, RunState& state) {
    for (const auto& statement : statements) {
        if (state.stop) return;
        run_statement(statement, state);
    }
}

void ScriptInterpreter::run_statement(const ScriptStmt& statement, RunState& state) {
    if (++steps_ > step_limit_) {
        state.result->step_limit_hit = true;
        state.stop = true;
        return;
    }
    switch (statement.kind) {
    case ScriptStmtKind::Set: {
        auto value = evaluate(statement.children[0], state);
        const auto key = lower(statement.name);
        if (!value.is_text && integers_.count(key) != 0) value.number = truncate_integer(value.number);
        variables_[key] = value;
        state.host->variable_written(statement.name, value);
        if (trace_enabled_) state.result->trace.push_back("line " + std::to_string(statement.line) + ": set " + statement.name + " = " + describe(value));
        return;
    }
    case ScriptStmtKind::If: {
        for (const auto& branch : statement.branches) {
            const auto condition = evaluate(branch.condition, state);
            if (trace_enabled_ && !state.stop) state.result->trace.push_back("line " + std::to_string(branch.condition.line) + ": if " + (truthy(condition) ? "true" : "false"));
            if (truthy(condition)) {
                run_statements(branch.body, state);
                return;
            }
        }
        run_statements(statement.else_body, state);
        return;
    }
    case ScriptStmtKind::Return:
        if (trace_enabled_) state.result->trace.push_back("line " + std::to_string(statement.line) + ": return");
        state.result->returned = true;
        state.stop = true;
        return;
    case ScriptStmtKind::Expression:
        evaluate(statement.children[0], state);
        return;
    }
}

ScriptValue ScriptInterpreter::evaluate(const ScriptExpr& expr, RunState& state) {
    switch (expr.kind) {
    case ScriptExprKind::Number:
        return ScriptValue::from_number(number_of(expr.text));
    case ScriptExprKind::String:
        return ScriptValue::from_text(expr.text);
    case ScriptExprKind::Name: {
        // `Ref.name` written without a member call is a read of the ref's variable: a variable this run has set
        // is used as it is, and anything else is a call on the ref, which the host answers.
        const auto dot = expr.text.find('.');
        if (dot != std::string::npos && variables_.find(lower(expr.text)) == variables_.end()) {
            const auto target = ScriptValue::from_text(expr.text.substr(0, dot));
            ScriptExpr member;
            member.kind = ScriptExprKind::Call;
            member.text = expr.text.substr(dot + 1);
            member.line = expr.line;
            return call(member, &target, state);
        }
        return lookup_name(expr.text);
    }
    case ScriptExprKind::Call:
        return call(expr, state.target, state);
    case ScriptExprKind::Member: {
        const auto target = evaluate(expr.children[0], state);
        return call(expr.children[1], &target, state);
    }
    case ScriptExprKind::Unary: {
        const auto operand = evaluate(expr.children[0], state);
        if (expr.text == "-") return ScriptValue::from_number(-operand.number);
        return ScriptValue::from_number(truthy(operand) ? 0.0 : 1.0);
    }
    case ScriptExprKind::Binary: {
        const auto& op = expr.text;
        const auto left = evaluate(expr.children[0], state);
        // && and || decide from the left side when they can, so the right side (and any command in it) is not asked.
        if (op == "&&" && !truthy(left)) return ScriptValue::from_number(0.0);
        if (op == "||" && truthy(left)) return ScriptValue::from_number(1.0);
        const auto right = evaluate(expr.children[1], state);
        if (op == "&&" || op == "||") return ScriptValue::from_number(truthy(right) ? 1.0 : 0.0);
        if (op == "==" || op == "!=") {
            bool equal = false;
            if (left.is_text || right.is_text) equal = left.is_text && right.is_text && lower(left.text) == lower(right.text);
            else equal = left.number == right.number;
            return ScriptValue::from_number((op == "==") == equal ? 1.0 : 0.0);
        }
        const auto a = left.number;
        const auto b = right.number;
        if (op == "<") return ScriptValue::from_number(a < b ? 1.0 : 0.0);
        if (op == ">") return ScriptValue::from_number(a > b ? 1.0 : 0.0);
        if (op == "<=") return ScriptValue::from_number(a <= b ? 1.0 : 0.0);
        if (op == ">=") return ScriptValue::from_number(a >= b ? 1.0 : 0.0);
        if (op == "+") return ScriptValue::from_number(a + b);
        if (op == "-") return ScriptValue::from_number(a - b);
        if (op == "*") return ScriptValue::from_number(a * b);
        if (op == "/") return ScriptValue::from_number(b == 0.0 ? 0.0 : a / b);
        if (op == "%") return ScriptValue::from_number(integer_modulo(a, b));
        return ScriptValue::from_number(0.0);
    }
    }
    return ScriptValue::from_number(0.0);
}

ScriptValue ScriptInterpreter::call(const ScriptExpr& call_expr, const ScriptValue* target, RunState& state) {
    std::vector<ScriptValue> arguments;
    arguments.reserve(call_expr.children.size());
    for (const auto& argument : call_expr.children) arguments.push_back(evaluate(argument, state));

    if (trace_enabled_) {
        std::ostringstream line;
        line << "line " << call_expr.line << ": ";
        if (target) line << describe(*target) << '.';
        line << call_expr.text << '(';
        for (std::size_t index = 0; index < arguments.size(); ++index) {
            if (index) line << ", ";
            line << describe(arguments[index]);
        }
        line << ')';
        state.result->trace.push_back(line.str());
    }

    const auto value = state.host->call_command(call_expr.text, target, arguments);
    if (value) return *value;
    const auto key = lower(call_expr.text);
    if (state.reported.insert(key).second) state.result->unimplemented.push_back(call_expr.text);
    return ScriptValue::from_number(0.0);
}

ScriptValue ScriptInterpreter::lookup_name(const std::string& name) const {
    const auto it = variables_.find(lower(name));
    if (it != variables_.end()) return it->second;
    // Anything that is not a variable is a name the host resolves (a reference, quest or stage).
    auto value = ScriptValue::from_text(name);
    value.unresolved = true;
    return value;
}

} // namespace oblivion
