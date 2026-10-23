#include "oblivion/script_parser.hpp"

#include <cctype>
#include <climits>
#include <utility>
#include <vector>

#include "oblivion/script_lexer.hpp"

namespace oblivion {
namespace {

std::string lower(std::string_view text) {
    std::string result(text);
    for (auto& c : result) c = static_cast<char>(std::tolower(static_cast<unsigned char>(c)));
    return result;
}

// Thrown inside the parser and turned into a diagnostic at the nearest statement.
struct SyntaxError {
    std::size_t line;
    std::string message;
};

ScriptExpr make_binary(std::string op, ScriptExpr lhs, ScriptExpr rhs) {
    ScriptExpr expr;
    expr.kind = ScriptExprKind::Binary;
    expr.text = std::move(op);
    expr.line = lhs.line;
    expr.children.push_back(std::move(lhs));
    expr.children.push_back(std::move(rhs));
    return expr;
}

class Parser {
public:
    Parser(std::vector<ScriptToken> tokens, const ScriptCommandLookup& lookup)
        : tokens_(std::move(tokens)), lookup_(lookup) {}

    ScriptFragment parse_fragment() {
        ScriptFragment fragment;
        fragment.statements = parse_statements(std::vector<std::string_view>{});
        fragment.diagnostics = std::move(diagnostics_);
        return fragment;
    }

    ScriptAst parse() {
        ScriptAst ast;
        while (true) {
            skip_newlines();
            if (peek().kind == ScriptTokenKind::EndOfFile) break;
            const auto& token = peek();
            try {
                if (token.kind != ScriptTokenKind::Identifier) throw SyntaxError{token.line, describe(token)};
                const auto word = lower(token.text);
                if (word == "scn" || word == "scriptname") {
                    advance();
                    ast.name = expect_identifier();
                    end_statement();
                } else if (is_declaration_type(word)) {
                    const auto line = token.line;
                    advance();
                    ScriptDeclaration declaration;
                    declaration.type = word;
                    declaration.line = line;
                    declaration.name = expect_identifier();
                    end_statement();
                    ast.declarations.push_back(std::move(declaration));
                } else if (word == "begin") {
                    ast.blocks.push_back(parse_block());
                } else {
                    throw SyntaxError{token.line, "unexpected '" + token.text + "' outside a block"};
                }
            } catch (const SyntaxError& error) {
                diagnostics_.push_back({error.line, error.message});
                skip_line();
            }
        }
        ast.diagnostics = std::move(diagnostics_);
        return ast;
    }

private:
    std::vector<ScriptToken> tokens_;
    const ScriptCommandLookup& lookup_;
    std::size_t position_ = 0;
    std::vector<ScriptDiagnostic> diagnostics_;

    static bool is_declaration_type(const std::string& word) {
        return word == "short" || word == "long" || word == "int" || word == "float" || word == "ref";
    }

    const ScriptToken& peek(std::size_t ahead = 0) const {
        const auto index = position_ + ahead;
        return index < tokens_.size() ? tokens_[index] : tokens_.back();
    }

    void advance() {
        if (position_ < tokens_.size() - 1) ++position_;
    }

    static bool is_keyword(const ScriptToken& token, std::string_view word) {
        return token.kind == ScriptTokenKind::Identifier && lower(token.text) == word;
    }

    static bool is_operator(const ScriptToken& token, std::string_view op) {
        return token.kind == ScriptTokenKind::Operator && token.text == op;
    }

    static std::string describe(const ScriptToken& token) {
        if (token.kind == ScriptTokenKind::Error) return token.text;
        if (token.kind == ScriptTokenKind::EndOfFile) return "unexpected end of script";
        if (token.kind == ScriptTokenKind::Newline) return "unexpected end of line";
        return "unexpected '" + token.text + "'";
    }

    void skip_newlines() {
        while (peek().kind == ScriptTokenKind::Newline) advance();
    }

    void skip_line() {
        while (peek().kind != ScriptTokenKind::EndOfFile && peek().kind != ScriptTokenKind::Newline) advance();
        if (peek().kind == ScriptTokenKind::Newline) advance();
    }

    std::string expect_identifier() {
        const auto& token = peek();
        if (token.kind != ScriptTokenKind::Identifier) throw SyntaxError{token.line, "expected a name, " + describe(token)};
        advance();
        return token.text;
    }

    void expect_keyword(std::string_view word) {
        const auto& token = peek();
        if (!is_keyword(token, word)) throw SyntaxError{token.line, "expected '" + std::string(word) + "', " + describe(token)};
        advance();
    }

    void end_statement() {
        const auto& token = peek();
        if (token.kind == ScriptTokenKind::Newline) {
            advance();
            return;
        }
        if (token.kind == ScriptTokenKind::EndOfFile) return;
        throw SyntaxError{token.line, describe(token) + " at the end of a statement"};
    }

    ScriptBlock parse_block() {
        const auto line = peek().line;
        advance();  // begin
        ScriptBlock block;
        block.line = line;
        block.name = expect_identifier();
        // The header may carry arguments such as `OnAlarm 1, Player`; the last name is the target.
        while (peek().kind != ScriptTokenKind::Newline && peek().kind != ScriptTokenKind::EndOfFile) {
            if (peek().kind == ScriptTokenKind::Identifier) block.target = peek().text;
            advance();
        }
        end_statement();
        block.body = parse_statements({"end"});
        if (is_keyword(peek(), "end")) {
            advance();
            end_statement();
        } else {
            diagnostics_.push_back({line, "block '" + block.name + "' has no 'end'"});
        }
        return block;
    }

    // Parses statements until one of the terminator keywords or the end of the script.
    std::vector<ScriptStmt> parse_statements(const std::vector<std::string_view>& terminators) {
        std::vector<ScriptStmt> statements;
        while (true) {
            skip_newlines();
            const auto& token = peek();
            if (token.kind == ScriptTokenKind::EndOfFile) return statements;
            bool terminator = false;
            for (const auto word : terminators)
                if (is_keyword(token, word)) terminator = true;
            if (terminator) return statements;
            try {
                statements.push_back(parse_statement());
            } catch (const SyntaxError& error) {
                diagnostics_.push_back({error.line, error.message});
                skip_line();
            }
        }
    }

    ScriptStmt parse_statement() {
        const auto& token = peek();
        if (token.kind != ScriptTokenKind::Identifier) throw SyntaxError{token.line, describe(token)};
        const auto word = lower(token.text);
        ScriptStmt statement;
        statement.line = token.line;

        if (word == "set" || word == "let") {
            advance();
            statement.kind = ScriptStmtKind::Set;
            statement.name = expect_identifier();
            if (is_operator(peek(), ".")) {
                advance();
                statement.name += "." + expect_identifier();
            }
            expect_keyword("to");
            statement.children.push_back(parse_expression());
            end_statement();
            return statement;
        }
        if (word == "return") {
            advance();
            statement.kind = ScriptStmtKind::Return;
            end_statement();
            return statement;
        }
        if (word == "if") {
            advance();
            statement.kind = ScriptStmtKind::If;
            ScriptBranch arm;
            arm.condition = parse_expression();
            end_statement();
            arm.body = parse_statements({"elseif", "else", "endif"});
            statement.branches.push_back(std::move(arm));
            while (true) {
                // `else if` is written in some scripts instead of `elseif`.
                const bool else_if = is_keyword(peek(), "else") && is_keyword(peek(1), "if") && peek(1).line == peek().line;
                if (else_if || is_keyword(peek(), "elseif")) {
                    advance();
                    if (else_if) advance();
                    ScriptBranch next;
                    next.condition = parse_expression();
                    end_statement();
                    next.body = parse_statements({"elseif", "else", "endif"});
                    statement.branches.push_back(std::move(next));
                    continue;
                }
                if (is_keyword(peek(), "else")) {
                    advance();
                    end_statement();
                    statement.else_body = parse_statements({"endif"});
                }
                break;
            }
            expect_keyword("endif");
            end_statement();
            return statement;
        }
        if (word == "end" || word == "endif" || word == "else" || word == "elseif" || word == "begin") {
            throw SyntaxError{token.line, "unexpected '" + token.text + "'"};
        }

        statement.kind = ScriptStmtKind::Expression;
        statement.children.push_back(parse_expression());
        end_statement();
        return statement;
    }

    ScriptExpr parse_expression() { return parse_or(); }

    ScriptExpr parse_or() {
        auto lhs = parse_and();
        while (is_operator(peek(), "||")) {
            advance();
            lhs = make_binary("||", std::move(lhs), parse_and());
        }
        return lhs;
    }

    ScriptExpr parse_and() {
        auto lhs = parse_comparison();
        while (is_operator(peek(), "&&")) {
            advance();
            lhs = make_binary("&&", std::move(lhs), parse_comparison());
        }
        return lhs;
    }

    ScriptExpr parse_comparison() {
        auto lhs = parse_additive();
        while (true) {
            const auto& token = peek();
            if (token.kind != ScriptTokenKind::Operator) break;
            if (token.text != "==" && token.text != "!=" && token.text != "<" && token.text != ">" &&
                token.text != "<=" && token.text != ">=") break;
            const auto op = token.text;
            advance();
            lhs = make_binary(op, std::move(lhs), parse_additive());
        }
        return lhs;
    }

    ScriptExpr parse_additive() {
        auto lhs = parse_multiplicative();
        while (is_operator(peek(), "+") || is_operator(peek(), "-")) {
            const auto op = peek().text;
            advance();
            lhs = make_binary(op, std::move(lhs), parse_multiplicative());
        }
        return lhs;
    }

    ScriptExpr parse_multiplicative() {
        auto lhs = parse_unary();
        while (is_operator(peek(), "*") || is_operator(peek(), "/") || is_operator(peek(), "%")) {
            const auto op = peek().text;
            advance();
            lhs = make_binary(op, std::move(lhs), parse_unary());
        }
        return lhs;
    }

    ScriptExpr parse_unary() {
        if (is_operator(peek(), "-") || is_operator(peek(), "!")) {
            ScriptExpr expr;
            expr.kind = ScriptExprKind::Unary;
            expr.text = peek().text;
            expr.line = peek().line;
            advance();
            expr.children.push_back(parse_unary());
            return expr;
        }
        return parse_postfix();
    }

    // `ref.name` is a command call when the name is a command, and a variable of
    // another reference otherwise. An unknown name followed by arguments is an error.
    ScriptExpr parse_postfix() {
        auto target = parse_primary(true);
        if (!is_operator(peek(), ".") || peek(1).kind != ScriptTokenKind::Identifier) return target;
        const auto line = peek().line;
        advance();
        const auto name = peek().text;
        advance();
        if (const auto signature = command_signature(name)) {
            ScriptExpr call;
            call.kind = ScriptExprKind::Call;
            call.line = line;
            call.text = name;
            call.children = parse_arguments(line, signature->max_arguments);
            ScriptExpr member;
            member.kind = ScriptExprKind::Member;
            member.line = target.line;
            member.children.push_back(std::move(target));
            member.children.push_back(std::move(call));
            return member;
        }
        // After `Ref.variable`, a `-` is subtraction, even before a literal such as `.4`.
        if (target.kind != ScriptExprKind::Name || starts_plain_argument(line))
            throw SyntaxError{line, "'" + name + "' is not a command"};
        target.text += "." + name;
        return target;
    }

    // A name followed by arguments on the same line is a command call.
    ScriptExpr parse_primary(bool allow_arguments) {
        const auto token = peek();
        switch (token.kind) {
        case ScriptTokenKind::Number: {
            advance();
            ScriptExpr expr;
            expr.kind = ScriptExprKind::Number;
            expr.text = token.text;
            expr.line = token.line;
            return expr;
        }
        case ScriptTokenKind::String: {
            advance();
            ScriptExpr expr;
            expr.kind = ScriptExprKind::String;
            expr.text = token.text;
            expr.line = token.line;
            return expr;
        }
        case ScriptTokenKind::Operator:
            if (token.text == "(") {
                advance();
                auto inner = parse_expression();
                if (!is_operator(peek(), ")")) throw SyntaxError{peek().line, "expected ')', " + describe(peek())};
                advance();
                return inner;
            }
            break;
        case ScriptTokenKind::Identifier: {
            advance();
            ScriptExpr expr;
            expr.line = token.line;
            const auto signature = allow_arguments ? command_signature(token.text) : std::nullopt;
            // With a lookup, a known command is a call even without arguments (`getsecondspassed`);
            // without one, a name is a call only when arguments follow it.
            const bool is_call = signature && (lookup_ ? true : starts_argument(token.line));
            if (is_call) {
                expr.kind = ScriptExprKind::Call;
                expr.text = token.text;
                expr.children = parse_arguments(token.line, signature->max_arguments);
            } else {
                expr.kind = ScriptExprKind::Name;
                expr.text = token.text;
                // In argument position `ref.variable` names another reference's variable.
                if (!allow_arguments && is_operator(peek(), ".") && peek(1).kind == ScriptTokenKind::Identifier) {
                    advance();
                    expr.text += "." + peek().text;
                    advance();
                }
            }
            return expr;
        }
        default:
            break;
        }
        throw SyntaxError{token.line, describe(token)};
    }

    // A command takes arguments only when the lookup knows it; without a lookup,
    // any name takes the arguments that follow it on the same line.
    std::optional<ScriptCommandSignature> command_signature(std::string_view name) const {
        if (!lookup_) return ScriptCommandSignature{0, SIZE_MAX};
        return lookup_(name);
    }

    bool starts_plain_argument(std::size_t line) const {
        const auto& token = peek();
        if (token.line != line) return false;
        if (token.kind == ScriptTokenKind::Identifier || token.kind == ScriptTokenKind::Number ||
            token.kind == ScriptTokenKind::String)
            return true;
        return token.kind == ScriptTokenKind::Operator && token.text == "(";
    }

    bool starts_argument(std::size_t line) const {
        const auto& token = peek();
        if (token.line != line) return false;
        if (token.kind == ScriptTokenKind::Identifier || token.kind == ScriptTokenKind::Number ||
            token.kind == ScriptTokenKind::String)
            return true;
        if (token.kind == ScriptTokenKind::Operator && token.text == "(") return true;
        // A negative literal such as `SetFactionRank Faction -1`.
        return token.kind == ScriptTokenKind::Operator && token.text == "-" && peek(1).kind == ScriptTokenKind::Number
            && peek(1).line == line;
    }

    // Arguments are primaries without nested command calls; parentheses group
    // anything more complex. A comma between arguments is optional. At most
    // `limit` arguments are taken, so the rest of the line stays for the caller.
    std::vector<ScriptExpr> parse_arguments(std::size_t line, std::size_t limit) {
        std::vector<ScriptExpr> arguments;
        while (arguments.size() < limit && starts_argument(line)) {
            if (is_operator(peek(), "-")) {
                advance();
                auto number = parse_primary(false);
                number.text = "-" + number.text;
                arguments.push_back(std::move(number));
            } else {
                arguments.push_back(parse_primary(false));
            }
            if (is_operator(peek(), ",")) advance();
        }
        return arguments;
    }
};

} // namespace

ScriptAst parse_script(std::string_view source, const ScriptCommandLookup& lookup) {
    return Parser(tokenize_script(source), lookup).parse();
}

ScriptFragment parse_fragment(std::string_view source, const ScriptCommandLookup& lookup) {
    return Parser(tokenize_script(source), lookup).parse_fragment();
}

} // namespace oblivion
