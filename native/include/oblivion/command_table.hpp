#pragma once

#include <cstdint>
#include <filesystem>
#include <string>
#include <vector>

#include "oblivion/script_parser.hpp"

namespace oblivion {

struct CommandParameter {
    std::string type_name;
    std::uint32_t type_id = 0;
    bool optional = false;
};

struct ScriptCommand {
    std::string name;
    std::string short_name;
    std::uint32_t opcode = 0;
    bool needs_parent = false;
    std::vector<CommandParameter> parameters;
};

// Reads the script command table from a PE32 Oblivion executable. Each record is
// a 40-byte entry holding the long name, short name, opcode, help text, the
// needs-parent flag, the parameter count and a parameter table. The table is
// located through the address of the SetStage name string. Only names, opcodes
// and parameter types are read; no code is copied. Throws std::runtime_error
// when the executable does not have the expected layout.
std::vector<ScriptCommand> read_command_table(const std::vector<std::uint8_t>& executable);

// Lookup for the script parser: names and short names map to argument counts.
// The lookup copies what it needs, so it does not depend on the table's lifetime.
ScriptCommandLookup make_command_lookup(const std::vector<ScriptCommand>& commands);

// Cache file for a table, named after the executable's content hash.
std::filesystem::path command_table_cache_path(const std::filesystem::path& cache_dir,
                                               const std::vector<std::uint8_t>& executable);

// Returns the table for an executable, reading it once and caching it under
// cache_dir. The cache is keyed by the executable's content, so a different
// build never reuses another build's table.
std::vector<ScriptCommand> load_command_table(const std::filesystem::path& executable,
                                              const std::filesystem::path& cache_dir);

} // namespace oblivion
