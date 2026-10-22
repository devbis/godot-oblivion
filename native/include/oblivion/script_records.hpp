#pragma once

#include <cstdint>
#include <string>
#include <vector>

namespace oblivion {

// One local variable declared by a script (SLSD followed by SCVR in the record).
struct ScriptVariable {
    std::uint32_t index = 0;
    // Raw type code from SLSD. Its meaning is not verified yet; the plan records it as data only.
    std::uint32_t type = 0;
    std::string name;
};

// A SCPT record: the script's source text (SCTX), its variable table and the
// form IDs it references (SCRO). The compiled bytecode (SCDA) is not kept.
struct ScriptRecord {
    std::uint32_t form_id = 0;
    std::string editor_id;
    // SCHR type: 0 object, 1 quest, 0x100 magic effect.
    std::uint16_t type = 0;
    // SCHR flag: 0x01 enabled.
    std::uint16_t flags = 0;
    std::uint32_t variable_count = 0;
    std::uint32_t compiled_size = 0;
    std::string source;
    std::vector<ScriptVariable> variables;
    std::vector<std::uint32_t> referenced_form_ids;
};

} // namespace oblivion
