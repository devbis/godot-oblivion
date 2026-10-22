#pragma once

#include <cstddef>
#include <string>
#include <string_view>
#include <vector>

namespace oblivion {

enum class ScriptTokenKind {
    Identifier,
    Number,
    String,
    Operator,
    Newline,
    EndOfFile,
    Error,
};

struct ScriptToken {
    ScriptTokenKind kind = ScriptTokenKind::EndOfFile;
    std::string text;
    std::size_t line = 1;
    std::size_t column = 1;
};

// Tokenizes classic TES4 script source. Keywords are identifiers; the parser
// decides what they mean. Comments start with ';' and run to the end of line.
// Newlines are tokens because statements end at line breaks. Lexical errors
// are reported as Error tokens carrying the message in `text`, so a script
// with one bad line still yields a complete token stream.
std::vector<ScriptToken> tokenize_script(std::string_view source);

} // namespace oblivion
