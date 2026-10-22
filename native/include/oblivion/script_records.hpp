#pragma once

#include <cstdint>
#include <string>
#include <vector>

namespace oblivion {

// A CTDA condition. `function_index` is the command opcode minus 0x1000, so
// function 58 is GetStage (checked against the command table); `parameter1` is
// the form ID the condition is about, for GetStage the quest.
struct QuestCondition {
    std::uint8_t operator_code = 0;
    float comparison = 0.0f;
    std::uint16_t function_index = 0;
    std::uint32_t parameter1 = 0;
    std::uint32_t parameter2 = 0;
};

// One log entry of a stage (the QSDT group): its conditions, optional journal
// text (CNAM), and the result script (SCTX source, SCRO references).
struct QuestStageEntry {
    bool completes = false;  // QSDT: the quest is complete after this entry
    std::vector<QuestCondition> conditions;
    std::string log_text;
    std::string result_source;
    std::vector<std::uint32_t> result_references;
};

struct QuestStage {
    std::uint16_t index = 0;  // INDX
    std::vector<QuestStageEntry> entries;
};

struct QuestRecord {
    std::uint32_t form_id = 0;
    std::string editor_id;
    std::string name;
    std::uint32_t script_form_id = 0;  // SCRI
    std::uint8_t flags = 0;            // DATA, first byte
    std::uint8_t priority = 0;         // DATA, second byte
    std::vector<QuestStage> stages;
};

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
