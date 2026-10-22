#pragma once

#include <string_view>

#include "oblivion/script_ast.hpp"

namespace oblivion {

// Parses classic TES4 script source into an AST. Parsing does not need the
// command table: a name followed by arguments on the same line is a command
// call, and its arguments are the operands that follow it. Problems are
// reported as diagnostics with a line number; the parser then skips to the
// next line and keeps going, so one bad statement does not hide the rest.
ScriptAst parse_script(std::string_view source);

} // namespace oblivion
