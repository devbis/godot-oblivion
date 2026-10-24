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
    // CTDA type flag 0x04 ("use global"): the compared value is the GLOB record with this
    // form id, not `comparison` (which stays 0). The caller resolves it at evaluation time.
    bool comparison_is_global = false;
    std::uint32_t comparison_global_form_id = 0;
    std::uint16_t function_index = 0;
    std::uint32_t parameter1 = 0;
    std::uint32_t parameter2 = 0;
    std::uint32_t run_on = 0; // TES4 CTDA: 0 subject, 1 target, 2 reference, 3 combat target, 4 linked reference
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

// One INFO record of a dialogue topic: a reply the NPC can give when its conditions hold.
// The result script runs when the reply is given (for example it can set a quest stage).
// One spoken response of an INFO: TRDT's response number and the NAM1 text that follows it.
struct DialogResponseLine {
    std::uint8_t number = 0;
    std::uint32_t emotion_type = 0;              // TRDT: TES4 EmotionType (neutral, anger, fear, ...)
    std::int32_t emotion_value = 0;              // TRDT: expression strength, 0..100
    std::string text;
    bool has_text = false;
};

struct DialogResponse {
    std::uint32_t form_id = 0;
    std::uint8_t flags = 0;                        // DATA byte 2: the response's flags (say once, goodbye, ...)
    std::string text;                              // NAM1 of the first response (see lines for all)
    std::vector<DialogResponseLine> lines;         // TRDT response number + NAM1, in record order
    std::uint32_t quest = 0;                       // QSTI: the quest the reply belongs to
    std::vector<QuestCondition> conditions;        // CTDA
    std::vector<std::uint32_t> topic_links;        // TCLT: topics this reply leads to
    std::string result_source;                     // SCTX
    std::vector<std::uint32_t> result_references;  // SCRO
};

// A DIAL record: a topic the player can ask about, with its replies.
struct DialogTopic {
    std::uint32_t form_id = 0;
    std::string editor_id;
    std::string name;                 // FULL: the topic text in the list
    std::uint8_t topic_type = 0;      // DIAL DATA: Topic=0, Conversation=1, Combat=2, Persuasion=3, Detection=4, Service=5, Miscellaneous=6
    std::vector<std::uint32_t> quests;  // QSTI
    std::vector<DialogResponse> responses;
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
