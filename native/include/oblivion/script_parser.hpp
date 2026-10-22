#pragma once

#include <cstddef>
#include <functional>
#include <optional>
#include <string_view>

#include "oblivion/script_ast.hpp"

namespace oblivion {

// How many arguments a command takes, from the executable's command table.
struct ScriptCommandSignature {
    std::size_t required_arguments = 0;
    std::size_t max_arguments = 0;
};

// Looks a command up by name (or short name); nullopt when the name is not a command.
using ScriptCommandLookup = std::function<std::optional<ScriptCommandSignature>(std::string_view name)>;

// Parses classic TES4 script source into an AST. With a lookup, only known
// commands take arguments, and never more than the table allows. Without one,
// a name followed by arguments on the same line is treated as a call. Problems
// are reported as diagnostics with a line number; the parser then skips to the
// next line and keeps going, so one bad statement does not hide the rest.
ScriptAst parse_script(std::string_view source, const ScriptCommandLookup& lookup = {});

} // namespace oblivion
