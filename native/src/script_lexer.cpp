#include "oblivion/script_lexer.hpp"

#include <cctype>

namespace oblivion {
namespace {

bool is_identifier_start(char c) {
    return std::isalpha(static_cast<unsigned char>(c)) || c == '_';
}

bool is_identifier_part(char c) {
    return std::isalnum(static_cast<unsigned char>(c)) || c == '_';
}

bool is_digit(char c) {
    return std::isdigit(static_cast<unsigned char>(c)) != 0;
}

} // namespace

std::vector<ScriptToken> tokenize_script(std::string_view source) {
    std::vector<ScriptToken> tokens;
    std::size_t line = 1;
    std::size_t line_start = 0;
    std::size_t i = 0;

    auto push = [&](ScriptTokenKind kind, std::string text, std::size_t start) {
        tokens.push_back({kind, std::move(text), line, start - line_start + 1});
    };

    while (i < source.size()) {
        const char c = source[i];
        if (c == '\r') {
            ++i;
            continue;
        }
        if (c == '\n') {
            push(ScriptTokenKind::Newline, "\n", i);
            ++i;
            ++line;
            line_start = i;
            continue;
        }
        if (c == ' ' || c == '\t') {
            ++i;
            continue;
        }
        if (c == ';') {
            while (i < source.size() && source[i] != '\n') ++i;
            continue;
        }
        if (is_identifier_start(c)) {
            const std::size_t start = i;
            while (i < source.size() && is_identifier_part(source[i])) ++i;
            push(ScriptTokenKind::Identifier, std::string(source.substr(start, i - start)), start);
            continue;
        }
        if (is_digit(c) || (c == '.' && i + 1 < source.size() && is_digit(source[i + 1]))) {
            const std::size_t start = i;
            bool seen_dot = false;
            while (i < source.size() && (is_digit(source[i]) || (source[i] == '.' && !seen_dot))) {
                if (source[i] == '.') seen_dot = true;
                ++i;
            }
            push(ScriptTokenKind::Number, std::string(source.substr(start, i - start)), start);
            continue;
        }
        if (c == '"') {
            const std::size_t start = i;
            ++i;
            const std::size_t text_start = i;
            while (i < source.size() && source[i] != '"' && source[i] != '\n') ++i;
            if (i >= source.size() || source[i] != '"') {
                push(ScriptTokenKind::Error, "unterminated string", start);
                continue;
            }
            push(ScriptTokenKind::String, std::string(source.substr(text_start, i - text_start)), start);
            ++i;
            continue;
        }
        // Two-character operators first, then single characters.
        const std::size_t start = i;
        if (i + 1 < source.size()) {
            const std::string_view pair = source.substr(i, 2);
            if (pair == "==" || pair == "!=" || pair == "<=" || pair == ">=" || pair == "&&" || pair == "||") {
                push(ScriptTokenKind::Operator, std::string(pair), start);
                i += 2;
                continue;
            }
        }
        if (std::string_view("+-*/%()<>=,!.").find(c) != std::string_view::npos) {
            push(ScriptTokenKind::Operator, std::string(1, c), start);
            ++i;
            continue;
        }
        push(ScriptTokenKind::Error, std::string("unexpected character '") + c + "'", start);
        ++i;
    }
    tokens.push_back({ScriptTokenKind::EndOfFile, "", line, i - line_start + 1});
    return tokens;
}

} // namespace oblivion
