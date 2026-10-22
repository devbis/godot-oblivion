#include "oblivion/bsa_archive.hpp"
#include "oblivion/command_table.hpp"
#include "oblivion/esm4_database.hpp"
#include "oblivion/game_data.hpp"
#include "oblivion/nif_mesh.hpp"
#include "oblivion/script_lexer.hpp"
#include "oblivion/script_interpreter.hpp"
#include "oblivion/script_parser.hpp"

#include <NifFile.hpp>

#include <array>
#include <chrono>
#include <cstdint>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <stdexcept>
#include <string>
#include <sstream>
#include <vector>

#include <zlib.h>

// Checks throw instead of calling assert, so they stay active in every build
// type and the temporary directory is still removed when one fails.
#define CHECK(condition)                                                                              \
    do {                                                                                              \
        if (!(condition))                                                                             \
            throw std::runtime_error(std::string(__FILE__) + ":" + std::to_string(__LINE__)           \
                                     + ": check failed: " #condition);                                \
    } while (false)

namespace {

using Bytes = std::vector<std::uint8_t>;

void u8(Bytes& out, std::uint8_t value) { out.push_back(value); }
void u16(Bytes& out, std::uint16_t value) {
    u8(out, static_cast<std::uint8_t>(value));
    u8(out, static_cast<std::uint8_t>(value >> 8));
}
void u32(Bytes& out, std::uint32_t value) {
    for (int shift = 0; shift < 32; shift += 8) u8(out, static_cast<std::uint8_t>(value >> shift));
}
void u64(Bytes& out, std::uint64_t value) {
    u32(out, static_cast<std::uint32_t>(value));
    u32(out, static_cast<std::uint32_t>(value >> 32));
}
void f32(Bytes& out, float value) {
    std::uint32_t bits = 0;
    std::memcpy(&bits, &value, sizeof(bits));
    u32(out, bits);
}
void raw(Bytes& out, std::string_view value) {
    out.insert(out.end(), value.begin(), value.end());
}
void zstring(Bytes& out, std::string_view value) {
    raw(out, value);
    u8(out, 0);
}
void subrecord(Bytes& out, std::string_view tag, const Bytes& value) {
    raw(out, tag);
    u16(out, static_cast<std::uint16_t>(value.size()));
    out.insert(out.end(), value.begin(), value.end());
}
Bytes string_subrecord(std::string_view tag, std::string_view value) {
    Bytes data;
    zstring(data, value);
    Bytes result;
    subrecord(result, tag, data);
    return result;
}
Bytes id_subrecord(std::string_view tag, std::uint32_t value) {
    Bytes data;
    u32(data, value);
    Bytes result;
    subrecord(result, tag, data);
    return result;
}
Bytes float_subrecord(std::string_view tag, const std::vector<float>& values) {
    Bytes data;
    for (const float value : values) f32(data, value);
    Bytes result;
    subrecord(result, tag, data);
    return result;
}
Bytes record(std::string_view tag, std::uint32_t form_id, const Bytes& data) {
    Bytes result;
    raw(result, tag);
    u32(result, static_cast<std::uint32_t>(data.size()));
    u32(result, 0); // flags
    u32(result, form_id);
    u32(result, 0); // revision
    result.insert(result.end(), data.begin(), data.end());
    return result;
}
Bytes group(std::uint32_t label, std::uint32_t type, const Bytes& children) {
    Bytes result;
    raw(result, "GRUP");
    u32(result, static_cast<std::uint32_t>(20 + children.size()));
    u32(result, label);
    u32(result, type);
    u16(result, 0);
    u16(result, 0);
    result.insert(result.end(), children.begin(), children.end());
    return result;
}
void append(Bytes& target, const Bytes& source) {
    target.insert(target.end(), source.begin(), source.end());
}
Bytes cell_record(std::uint32_t form_id, std::string_view editor_id, std::string_view name) {
    Bytes data;
    append(data, string_subrecord("EDID", editor_id));
    append(data, string_subrecord("FULL", name));
    Bytes flags;
    u16(flags, 1); // interior
    subrecord(data, "DATA", flags);
    return record("CELL", form_id, data);
}
Bytes reference_record(std::uint32_t form_id, std::uint32_t base_id,
                       std::uint32_t teleport_ref_id) {
    Bytes data;
    append(data, id_subrecord("NAME", base_id));
    Bytes transform;
    f32(transform, 1.0f); f32(transform, 2.0f); f32(transform, 3.0f);
    f32(transform, 0.1f); f32(transform, 0.2f); f32(transform, 0.3f);
    subrecord(data, "DATA", transform);
    Bytes teleport;
    u32(teleport, teleport_ref_id);
    for (float value : {4.0f, 5.0f, 6.0f, 0.4f, 0.5f, 0.6f}) f32(teleport, value);
    subrecord(data, "XTEL", teleport);
    return record("REFR", form_id, data);
}

std::filesystem::path temp_dir() {
    const auto stamp = std::chrono::steady_clock::now().time_since_epoch().count();
    auto path = std::filesystem::temp_directory_path() / ("openob-fixtures-" + std::to_string(stamp));
    std::filesystem::create_directories(path);
    return path;
}

void write_bytes(const std::filesystem::path& path, const Bytes& bytes) {
    std::filesystem::create_directories(path.parent_path());
    std::ofstream output(path, std::ios::binary);
    output.write(reinterpret_cast<const char*>(bytes.data()), static_cast<std::streamsize>(bytes.size()));
    CHECK(output.good());
}

// A BSA 103 archive holding one archive-compressed entry, meshes\test.nif.
// declared_output_size is written verbatim so tests can describe corrupt entries.
Bytes single_entry_bsa(std::uint32_t declared_output_size, const Bytes& compressed) {
    const std::string filename = "test.nif";
    const std::string folder = "meshes";
    const std::uint32_t folder_offset = 36;
    const std::uint32_t data_offset = folder_offset + 16 + 1 + folder.size() + 1 + 16
        + filename.size() + 1;
    const std::uint32_t stored_size = 4 + static_cast<std::uint32_t>(compressed.size());

    Bytes archive;
    u32(archive, 0x00415342); // magic
    u32(archive, 0x67);       // Oblivion BSA 103
    u32(archive, folder_offset);
    u32(archive, 0x0107); // names, archive compression, and legacy embedded-name flag
    u32(archive, 1); // folder count
    u32(archive, 1); // file count
    u32(archive, static_cast<std::uint32_t>(folder.size() + 1));
    u32(archive, static_cast<std::uint32_t>(filename.size() + 1));
    u32(archive, 0); // file flags
    u64(archive, 0); // folder hash
    u32(archive, 1); // folder file count
    u32(archive, 52); // folder block offset
    u8(archive, static_cast<std::uint8_t>(folder.size() + 1));
    zstring(archive, folder);
    u64(archive, 0); // file hash
    u32(archive, stored_size);
    u32(archive, data_offset);
    zstring(archive, filename);
    u32(archive, declared_output_size);
    archive.insert(archive.end(), compressed.begin(), compressed.end());
    CHECK(archive.size() == data_offset + stored_size);
    return archive;
}

Bytes compress_text(std::string_view payload) {
    uLongf compressed_size = compressBound(payload.size());
    Bytes compressed(static_cast<std::size_t>(compressed_size));
    const int compression_status = compress2(compressed.data(), &compressed_size,
        reinterpret_cast<const Bytef*>(payload.data()), payload.size(), Z_BEST_COMPRESSION);
    CHECK(compression_status == Z_OK);
    compressed.resize(static_cast<std::size_t>(compressed_size));
    return compressed;
}

void test_bsa(const std::filesystem::path& directory) {
    constexpr std::string_view payload = "fixture nif bytes";
    const auto path = directory / "fixture.bsa";
    write_bytes(path, single_entry_bsa(static_cast<std::uint32_t>(payload.size()), compress_text(payload)));
    oblivion::BsaArchive bsa;
    bsa.open(path);
    CHECK(bsa.file_count() == 1);
    CHECK(bsa.contains("Meshes/Test.NIF"));
    const auto extracted = bsa.read("meshes\\test.nif");
    CHECK(std::string(extracted.begin(), extracted.end()) == payload);
}

void test_bsa_rejects_implausible_output_size(const std::filesystem::path& directory) {
    // The declared size is far beyond both the absolute limit and what deflate can produce.
    const auto path = directory / "corrupt.bsa";
    write_bytes(path, single_entry_bsa(0x7FFFFFF0u, compress_text("tiny")));
    oblivion::BsaArchive bsa;
    bsa.open(path);
    bool rejected = false;
    try {
        (void)bsa.read("meshes\\test.nif");
    } catch (const std::runtime_error&) {
        rejected = true;
    }
    CHECK(rejected);
}

// Minimal Oblivion.esm: a STAT, an RACE with face data, two NPCs, a GMST and two cells.
Bytes esm_fixture() {
    Bytes top_header;
    raw(top_header, "TES4");
    u32(top_header, 0);
    u32(top_header, 0);
    u32(top_header, 0);
    u32(top_header, 0);

    Bytes stat_data;
    append(stat_data, string_subrecord("EDID", "TestDoor"));
    append(stat_data, string_subrecord("MODL", "Doors\\TestDoor.NIF"));
    Bytes records;
    append(records, record("DOOR", 0x100, stat_data));

    Bytes race_data;
    append(race_data, string_subrecord("EDID", "FixtureRace"));
    subrecord(race_data, "FNAM", {});
    append(race_data, float_subrecord("FGGS", {0.25f, -0.5f}));
    append(race_data, float_subrecord("FGGA", {0.75f}));
    append(records, record("RACE", 0x300, race_data));

    auto make_npc_record = [](std::uint32_t id, std::uint32_t flags, std::string_view editor_id) {
        Bytes data;
        append(data, string_subrecord("EDID", editor_id));
        Bytes acbs;
        u32(acbs, flags);
        subrecord(data, "ACBS", acbs);
        append(data, id_subrecord("RNAM", 0x300));
        append(data, float_subrecord("FGGS", {1.0f, 2.0f}));
        append(data, float_subrecord("FGGA", {3.0f}));
        return record("NPC_", id, data);
    };
    append(records, make_npc_record(0x301, 0, "FixtureMale"));
    append(records, make_npc_record(0x302, 1, "FixtureFemale"));

    // GMST DATA deliberately precedes EDID, the order the parser must tolerate.
    Bytes gmst_data;
    append(gmst_data, float_subrecord("DATA", {1.5f}));
    append(gmst_data, string_subrecord("EDID", "fFixtureSetting"));
    append(records, record("GMST", 0x400, gmst_data));

    // A quest-style script with a 2-entry variable table, one reference and a source text.
    Bytes script_header;
    u32(script_header, 0);  // unused
    u32(script_header, 1);  // reference count
    u32(script_header, 40); // compiled size
    u32(script_header, 2);  // variable count
    u16(script_header, 1);  // quest
    u16(script_header, 1);  // enabled
    Bytes script_data;
    append(script_data, string_subrecord("EDID", "FixtureScript"));
    subrecord(script_data, "SCHR", script_header);
    Bytes first_variable;
    u32(first_variable, 1);
    u32(first_variable, 0); u32(first_variable, 0); u32(first_variable, 0);
    u32(first_variable, 2); // float
    u32(first_variable, 0);
    subrecord(script_data, "SLSD", first_variable);
    append(script_data, string_subrecord("SCVR", "fixtureFloat"));
    Bytes second_variable;
    u32(second_variable, 2);
    u32(second_variable, 0); u32(second_variable, 0); u32(second_variable, 0);
    u32(second_variable, 3); // reference
    u32(second_variable, 0);
    subrecord(script_data, "SLSD", second_variable);
    append(script_data, string_subrecord("SCVR", "fixtureRef"));
    append(script_data, id_subrecord("SCRO", 0x100));
    append(script_data, string_subrecord("SCTX", "scn FixtureScript\nshort fixtureFloat\nBegin GameMode\n  set fixtureFloat to 1\nEnd\n"));
    append(records, record("SCPT", 0x500, script_data));

    // A quest with two stages: stage 10 has one entry with a GetStage condition, a journal
    // line and a result script; stage 20 is completed without conditions.
    Bytes quest_data;
    append(quest_data, string_subrecord("EDID", "FixtureQuest"));
    Bytes quest_flags;
    u8(quest_flags, 1);
    u8(quest_flags, 50);
    subrecord(quest_data, "DATA", quest_flags);
    Bytes condition(24, 0);
    condition[0] = 0;
    condition[8] = 58;  // function 58 = GetStage (opcode 0x103A)
    for (int shift = 0; shift < 32; shift += 8) condition[12 + shift / 8] = static_cast<std::uint8_t>(0x100 >> shift);
    Bytes comparison;
    f32(comparison, 20.0f);
    for (std::size_t i = 0; i < 4; ++i) condition[4 + i] = comparison[i];
    subrecord(quest_data, "INDX", Bytes{10, 0});
    subrecord(quest_data, "QSDT", Bytes{0});
    subrecord(quest_data, "CTDA", condition);
    append(quest_data, string_subrecord("CNAM", "Start the quest"));
    append(quest_data, string_subrecord("SCTX", "setstage FixtureQuest 20\n"));
    append(quest_data, id_subrecord("SCRO", 0x101));
    subrecord(quest_data, "INDX", Bytes{20, 0});
    subrecord(quest_data, "QSDT", Bytes{1});
    append(records, record("QUST", 0x600, quest_data));

    // Cell 0x20's references precede its CELL record, so they must still attach.
    Bytes first_children;
    append(first_children, cell_record(0x10, "StartCell", "Fixture Start"));
    Bytes first_cell_refs;
    append(first_cell_refs, reference_record(0x101, 0x100, 0x202));
    append(first_children, group(0x10, 6, first_cell_refs));
    append(records, group(0, 3, first_children));

    Bytes second_children;
    Bytes second_cell_refs;
    append(second_cell_refs, reference_record(0x202, 0x100, 0x101));
    append(second_cell_refs, reference_record(0x203, 0x100, 0));
    append(second_children, group(0x20, 6, second_cell_refs));
    append(second_children, cell_record(0x20, "NextCell", "Fixture Next"));
    append(records, group(0, 3, second_children));

    // References whose owning cell (0x999) never appears are counted, not placed.
    Bytes orphan_refs;
    append(orphan_refs, reference_record(0x204, 0x100, 0));
    append(records, group(0x999, 6, orphan_refs));

    append(top_header, group(0x524f4f44, 0, records)); // top group
    return top_header;
}

void test_esm4(const std::filesystem::path& directory) {
    const auto path = directory / "fixture.esm";
    write_bytes(path, esm_fixture());

    oblivion::Esm4Database database;
    database.open(path);
    const auto* start = database.find_cell("startcell");
    CHECK(start != nullptr);
    CHECK(start->display_name == "Fixture Start");
    CHECK(start->interior);
    CHECK(start->references.size() == 1);
    const auto& door = start->references.front();
    CHECK(door.form_id == 0x101);
    CHECK(door.base_form_id == 0x100);
    CHECK(door.model_path == "Doors\\TestDoor.NIF");
    CHECK(door.teleport_ref_id == 0x202);
    CHECK(door.teleport_cell_id == 0x20);
    CHECK(door.position[0] == 1.0f && door.position[2] == 3.0f);

    const auto* next = database.find_cell("NEXTCELL");
    CHECK(next != nullptr);
    CHECK(next->references.size() == 2);
    CHECK(database.find_cell(0x20) == next);
    CHECK(database.unplaced_reference_count() == 1);

    const auto* script = database.find_script("fixturescript");
    CHECK(script != nullptr && script == database.find_script(0x500));
    CHECK(script->editor_id == "FixtureScript" && script->type == 1 && script->flags == 1);
    CHECK(script->compiled_size == 40 && script->variable_count == 2);
    CHECK(script->variables.size() == 2);
    CHECK(script->variables[0].index == 1 && script->variables[0].type == 2);
    CHECK(script->variables[0].name == "fixtureFloat");
    CHECK(script->variables[1].index == 2 && script->variables[1].name == "fixtureRef");
    CHECK(script->referenced_form_ids == std::vector<std::uint32_t>({0x100}));
    CHECK(script->source == "scn FixtureScript\nshort fixtureFloat\nBegin GameMode\n  set fixtureFloat to 1\nEnd\n");
    CHECK(database.find_script("missing") == nullptr);

    const auto* quest = database.find_quest("fixturequest");
    CHECK(quest != nullptr && quest == database.find_quest(0x600));
    CHECK(quest->flags == 1 && quest->priority == 50);
    CHECK(quest->stages.size() == 2 && quest->stages[0].index == 10 && quest->stages[1].index == 20);
    const auto& entry = quest->stages[0].entries.at(0);
    CHECK(!entry.completes && entry.log_text == "Start the quest");
    CHECK(entry.conditions.size() == 1 && entry.conditions[0].function_index == 58);
    CHECK(entry.conditions[0].comparison == 20.0f && entry.conditions[0].parameter1 == 0x100);
    CHECK(entry.result_source == "setstage FixtureQuest 20\n" && entry.result_references == std::vector<std::uint32_t>({0x101}));
    CHECK(quest->stages[1].entries.size() == 1 && quest->stages[1].entries[0].completes);
    CHECK(quest->stages[1].entries[0].conditions.empty());
    CHECK(database.find_quest("missing-quest") == nullptr);

    CHECK(database.find_record_type(0x400) != nullptr && *database.find_record_type(0x400) == "GMST");
    CHECK(database.float_game_settings().count("fFixtureSetting") == 1);
    CHECK(database.float_game_settings().at("fFixtureSetting") == 1.5f);

    const auto* fixture_race = database.find_race_face_gen(0x300);
    CHECK(fixture_race != nullptr);
    CHECK(fixture_race->face_symmetric == std::vector<float>({0.25f, -0.5f}));
    CHECK(fixture_race->face_asymmetric == std::vector<float>({0.75f}));
    const auto* fixture_male = database.find_npc_base(0x301);
    const auto* fixture_female = database.find_npc_base(0x302);
    CHECK(fixture_male != nullptr && fixture_female != nullptr);
    CHECK(fixture_male->race_form_id == 0x300 && fixture_male->face_symmetric == std::vector<float>({1.0f, 2.0f}));
    CHECK(fixture_female->race_form_id == 0x300 && fixture_female->face_asymmetric == std::vector<float>({3.0f}));
}

void test_loose_assets(const std::filesystem::path& directory) {
    const auto data = directory / "data";
    const Bytes payload{'l', 'o', 'o', 's', 'e'};
    write_bytes(data / "Oblivion.esm", esm_fixture());
    write_bytes(data / "Meshes" / "Case" / "Loose.KF", payload);

    oblivion::GameData game;
    game.open(data);
    CHECK(game.read_asset("meshes\\case\\loose.kf") == payload);
    CHECK(game.read_asset("MESHES\\CASE\\LOOSE.KF") == payload);

    bool rejected = false;
    try {
        (void)game.read_asset("..\\Oblivion.esm");
    } catch (const std::runtime_error&) {
        rejected = true;
    }
    CHECK(rejected);
}

void test_script_lexer() {
    const auto tokens = oblivion::tokenize_script("scn Test ; comment\nshort x\nset x to 1.5\nif x >= 1\n\"msg\"\n");
    using Kind = oblivion::ScriptTokenKind;
    const std::vector<Kind> expected_kinds{
        Kind::Identifier, Kind::Identifier, Kind::Newline,
        Kind::Identifier, Kind::Identifier, Kind::Newline,
        Kind::Identifier, Kind::Identifier, Kind::Identifier, Kind::Number, Kind::Newline,
        Kind::Identifier, Kind::Identifier, Kind::Operator, Kind::Number, Kind::Newline,
        Kind::String, Kind::Newline,
        Kind::EndOfFile,
    };
    CHECK(tokens.size() == expected_kinds.size());
    for (std::size_t index = 0; index < tokens.size() && index < expected_kinds.size(); ++index)
        CHECK(tokens[index].kind == expected_kinds[index]);
    CHECK(tokens[1].text == "Test" && tokens[1].line == 1 && tokens[1].column == 5);
    CHECK(tokens[3].line == 2 && tokens[3].text == "short");
    CHECK(tokens[9].text == "1.5" && tokens[9].line == 3);
    CHECK(tokens[13].text == ">=");
    const auto logic = oblivion::tokenize_script("if a && b || !c\n");
    CHECK(logic[2].text == "&&" && logic[4].text == "||" && logic[5].text == "!");
    const auto member = oblivion::tokenize_script("myParent.activate mySelf 1\n");
    CHECK(member[1].text == "." && member[2].text == "activate" && member[3].text == "mySelf");
    CHECK(tokens[16].kind == Kind::String && tokens[16].text == "msg" && tokens[16].line == 5);
    CHECK(tokens.back().line == 6);

    // Errors become tokens with a line, and the rest of the script still tokenizes.
    const auto broken = oblivion::tokenize_script("set x to @\nset y to \"open\nset z to 2\n");
    std::size_t errors = 0;
    for (const auto& token : broken)
        if (token.kind == Kind::Error) ++errors;
    CHECK(errors == 2);
    CHECK(broken.back().kind == Kind::EndOfFile && broken.back().line == 4);
    bool saw_z = false;
    for (const auto& token : broken)
        if (token.kind == Kind::Identifier && token.text == "z" && token.line == 3) saw_z = true;
    CHECK(saw_z);
}

void test_script_parser() {
    const auto ast = oblivion::parse_script(
        "scn Test\n"
        "short x\n"
        "begin GameMode\n"
        "  set x to 1 + 2 * 3\n"
        "  if x >= 1\n"
        "    Activate mySelf 1\n"
        "  elseif x == 0\n"
        "    return\n"
        "  else\n"
        "    set x to 0\n"
        "  endif\n"
        "  myParent.activate mySelf\n"
        "end\n");
    CHECK(ast.diagnostics.empty());
    CHECK(ast.name == "Test");
    CHECK(ast.declarations.size() == 1 && ast.declarations[0].type == "short" && ast.declarations[0].name == "x");
    CHECK(ast.blocks.size() == 1 && ast.blocks[0].name == "GameMode" && ast.blocks[0].body.size() == 3);
    const auto& body = ast.blocks[0].body;

    const auto& assignment = body[0];
    CHECK(assignment.kind == oblivion::ScriptStmtKind::Set && assignment.name == "x");
    const auto& sum = assignment.children[0];
    CHECK(sum.kind == oblivion::ScriptExprKind::Binary && sum.text == "+");
    CHECK(sum.children[1].kind == oblivion::ScriptExprKind::Binary && sum.children[1].text == "*");

    const auto& branch_statement = body[1];
    CHECK(branch_statement.kind == oblivion::ScriptStmtKind::If);
    CHECK(branch_statement.branches.size() == 2);
    const auto& call = branch_statement.branches[0].body[0].children[0];
    CHECK(call.kind == oblivion::ScriptExprKind::Call && call.text == "Activate" && call.children.size() == 2);
    CHECK(branch_statement.branches[1].body[0].kind == oblivion::ScriptStmtKind::Return);
    CHECK(branch_statement.else_body.size() == 1);

    const auto& member = body[2].children[0];
    CHECK(member.kind == oblivion::ScriptExprKind::Member);
    CHECK(member.children[0].text == "myParent" && member.children[1].text == "activate");
    CHECK(member.children[1].children.size() == 1);

    // A bad statement is reported with its line; the statements after it still parse.
    const auto broken = oblivion::parse_script("begin onActivate\n  set x to @\n  set y to 2\nend\n");
    CHECK(broken.diagnostics.size() == 1 && broken.diagnostics[0].line == 2);
    CHECK(broken.blocks.size() == 1 && broken.blocks[0].body.size() == 1);
    CHECK(broken.blocks[0].body[0].name == "y");

    // Forms seen in the master: block arguments, `else if`, dotted names in arguments and assignments.
    const auto forms = oblivion::parse_script(
        "scriptName Forms\n"
        "begin OnAlarm 1, Player\n"
        "  set ms38.contact to ms38.contact + 1\n"
        "  if GetStage Q == 1\n"
        "    Player.ModCrimeGold Q.Gold\n"
        "  else if GetStage Q == 2\n"
        "  else\n"
        "  endif\n"
        "end\n");
    CHECK(forms.diagnostics.empty());
    CHECK(forms.blocks.size() == 1 && forms.blocks[0].target == "Player");
    CHECK(forms.blocks[0].body[0].name == "ms38.contact");
    CHECK(forms.blocks[0].body[1].branches.size() == 2 && forms.blocks[0].body[1].else_body.size() == 0);
    CHECK(forms.blocks[0].body[1].branches[0].body[0].children[0].children[1].children[0].text == "Q.Gold");

    const auto unclosed = oblivion::parse_script("begin onLoad\nset x to 1\n");
    CHECK(unclosed.diagnostics.size() == 1 && unclosed.diagnostics[0].line == 1);
}

// A PE32 image with three sections and a three-record command table: SetStage
// (String, optional Integer), GetStage (no parameters) and MessageBox (one String).
// The records are laid out the way the real executable stores them.
Bytes command_table_executable() {
    Bytes file(0x1000, 0);
    const auto put32 = [&](std::size_t offset, std::uint32_t value) {
        for (int shift = 0; shift < 32; shift += 8) file[offset + shift / 8] = static_cast<std::uint8_t>(value >> shift);
    };
    const auto put16 = [&](std::size_t offset, std::uint16_t value) {
        file[offset] = static_cast<std::uint8_t>(value);
        file[offset + 1] = static_cast<std::uint8_t>(value >> 8);
    };
    constexpr std::uint32_t image_base = 0x400000;
    file[0] = 'M';
    file[1] = 'Z';
    put32(0x3C, 0x80);
    file[0x80] = 'P';
    file[0x81] = 'E';
    put16(0x80 + 4 + 2, 3);     // NumberOfSections
    put16(0x80 + 4 + 16, 0xE0); // SizeOfOptionalHeader
    const std::size_t optional = 0x80 + 24;
    put16(optional, 0x10B);     // PE32
    put32(optional + 28, image_base);
    const std::size_t sections = optional + 0xE0;
    const std::array<std::array<std::uint32_t, 4>, 3> layout{{
        {0x1000, 0x400, 0x400, 0},  // .text (unused)
        {0x2000, 0x400, 0x800, 0},  // .rdata: strings
        {0x3000, 0x400, 0xC00, 0},  // .data: command records and parameter tables
    }};
    for (std::size_t index = 0; index < layout.size(); ++index) {
        const auto header = sections + 40 * index;
        put32(header + 8, layout[index][1]);   // VirtualSize
        put32(header + 12, layout[index][0]);  // VirtualAddress
        put32(header + 16, layout[index][1]);  // SizeOfRawData
        put32(header + 20, layout[index][2]);  // PointerToRawData
    }
    const auto text_at = [&](std::size_t offset, std::string_view text) {
        for (std::size_t i = 0; i < text.size(); ++i) file[0x800 + offset + i] = static_cast<std::uint8_t>(text[i]);
    };
    const std::uint32_t rdata = image_base + 0x2000;
    text_at(0x00, std::string("SetStage\0"));
    text_at(0x20, std::string("GetStage\0"));
    text_at(0x40, std::string("MessageBox\0"));
    text_at(0x60, std::string("String\0"));
    text_at(0x80, std::string("Integer\0"));
    const std::uint32_t data = image_base + 0x3000;
    const std::size_t records = 0xC00;
    const std::size_t set_stage_params = 0x200;
    const std::size_t message_params = 0x280;
    const auto record = [&](std::size_t index, std::uint32_t name, std::uint32_t opcode, std::uint16_t count, std::uint32_t params) {
        const auto at = records + 40 * index;
        put32(at + 0, name);
        put32(at + 8, opcode);
        put16(at + 18, count);
        put32(at + 20, params);
    };
    record(0, rdata + 0x00, 0x1171, 2, data + set_stage_params);
    record(1, rdata + 0x20, 0x1172, 0, 0);
    record(2, rdata + 0x40, 0x1000, 1, data + message_params);
    // Parameter records: type name address, type id, optional flag.
    put32(records + set_stage_params + 0, rdata + 0x60);
    put32(records + set_stage_params + 4, 0);
    put32(records + set_stage_params + 8, 0);
    put32(records + set_stage_params + 12, rdata + 0x80);
    put32(records + set_stage_params + 16, 1);
    put32(records + set_stage_params + 20, 1);
    put32(records + message_params + 0, rdata + 0x60);
    put32(records + message_params + 4, 0);
    put32(records + message_params + 8, 0);
    // The bytes after the last record are zero, which ends the run.
    return file;
}

void test_command_table(const std::filesystem::path& directory) {
    const auto executable = command_table_executable();
    const auto commands = oblivion::read_command_table(executable);
    CHECK(commands.size() == 3);
    CHECK(commands[0].name == "SetStage" && commands[0].opcode == 0x1171);
    CHECK(commands[0].parameters.size() == 2);
    CHECK(commands[0].parameters[0].type_name == "String" && !commands[0].parameters[0].optional);
    CHECK(commands[0].parameters[1].type_name == "Integer" && commands[0].parameters[1].optional);
    CHECK(commands[1].name == "GetStage" && commands[1].parameters.empty());
    CHECK(commands[2].name == "MessageBox" && commands[2].parameters.size() == 1);

    const auto lookup = oblivion::make_command_lookup(commands);
    const auto set_stage = lookup("setstage");
    CHECK(set_stage && set_stage->required_arguments == 1 && set_stage->max_arguments == 2);
    CHECK(lookup("GetStage") && lookup("GetStage")->max_arguments == 0);
    CHECK(!lookup("NoSuchCommand"));
    // MessageBox takes button labels after the message, so its arguments are not capped.
    CHECK(lookup("MessageBox") && lookup("MessageBox")->max_arguments > 1000);

    // The first load reads the executable and writes the cache; the second uses it.
    const auto exe_path = directory / "fixture.exe";
    write_bytes(exe_path, executable);
    const auto cache_dir = directory / "cache";
    const auto first = oblivion::load_command_table(exe_path, cache_dir);
    const auto cache_file = oblivion::command_table_cache_path(cache_dir, executable);
    CHECK(std::filesystem::exists(cache_file));
    const auto second = oblivion::load_command_table(exe_path, cache_dir);
    CHECK(first.size() == second.size() && second[0].name == "SetStage" && second[0].parameters[1].optional);

    // A damaged cache is rebuilt rather than trusted.
    write_bytes(cache_file, Bytes{'b', 'a', 'd'});
    const auto rebuilt = oblivion::load_command_table(exe_path, cache_dir);
    CHECK(rebuilt.size() == 3 && rebuilt[2].name == "MessageBox");
}

// Records every command call and answers GetStage with 5; everything else is unimplemented.
class RecordingHost final : public oblivion::ScriptHost {
public:
    std::vector<std::string> calls;
    std::string last_target;

    std::optional<oblivion::ScriptValue> call_command(std::string_view name, const oblivion::ScriptValue* target,
                                                      const std::vector<oblivion::ScriptValue>& arguments) override {
        calls.push_back(std::string(name) + "/" + std::to_string(arguments.size()));
        if (target) last_target = target->text;
        if (name == "GetStage") return oblivion::ScriptValue::from_number(5.0);
        return std::nullopt;
    }
};

void test_script_interpreter() {
    const auto ast = oblivion::parse_script(
        "scn Interp\n"
        "short x\n"
        "float y\n"
        "begin GameMode\n"
        "  set x to 2 + 3 * 2\n"
        "  if x == 8\n"
        "    GetStage QuestA\n"
        "    set y to GetStage QuestA + 1\n"
        "  else\n"
        "    set y to 99\n"
        "  endif\n"
        "  Player.GetStage QuestB\n"
        "  Activate mySelf\n"
        "  Activate mySelf\n"
        "  return\n"
        "  set x to 0\n"
        "end\n"
        "begin OnActivate\n"
        "  set y to 1\n"
        "end\n");
    CHECK(ast.diagnostics.empty());

    oblivion::ScriptInterpreter interpreter(ast);
    RecordingHost host;
    const auto result = interpreter.run("gamemode", host);
    CHECK(result.found_block && result.returned && !result.step_limit_hit);
    CHECK(interpreter.variables().at("x").number == 8.0);
    CHECK(interpreter.variables().at("y").number == 6.0);
    CHECK(host.last_target == "Player");
    // Activate is not implemented: it is reported once, not per call.
    CHECK(result.unimplemented == std::vector<std::string>({"Activate"}));
    CHECK(!result.trace.empty() && result.trace.back().find("return") != std::string::npos);

    // Another block runs on its own event, and a missing event is reported as such.
    RecordingHost other_host;
    const auto activated = interpreter.run("OnActivate", other_host);
    CHECK(activated.found_block && !activated.returned && interpreter.variables().at("y").number == 1.0);
    CHECK(!interpreter.run("OnDeath", other_host).found_block);

    // The step limit stops a run that would go on too long.
    oblivion::ScriptInterpreter limited(ast);
    limited.set_step_limit(3);
    RecordingHost limited_host;
    CHECK(limited.run("GameMode", limited_host).step_limit_hit);
}

void test_nif_mesh_decoder() {
    nifly::NifFile file;
    file.Create(nifly::NiVersion::getOB());
    const std::vector<nifly::Vector3> vertices{
        {0.0f, 0.0f, 0.0f}, {1.0f, 0.0f, 0.0f}, {0.0f, 1.0f, 0.0f}
    };
    const std::vector<nifly::Triangle> triangles{{0, 1, 2}};
    const auto* shape = file.CreateShapeFromData("FixtureShape", &vertices, &triangles, nullptr);
    CHECK(shape != nullptr);
    std::stringstream encoded(std::ios::in | std::ios::out | std::ios::binary);
    CHECK(file.Save(encoded) == 0);
    const auto payload = encoded.str();
    const Bytes bytes(payload.begin(), payload.end());
    const auto meshes = oblivion::decode_nif_meshes(bytes);
    CHECK(meshes.size() == 1);
    CHECK(meshes.front().name == "FixtureShape");
    CHECK(meshes.front().vertices.size() == 3);
    const std::vector<std::uint32_t> expected_indices{0, 1, 2};
    const std::array<float, 3> expected_vertex_x{1.0f, 0.0f, 0.0f};
    const std::array<float, 3> expected_vertex_y{0.0f, 0.0f, -1.0f};
    CHECK(meshes.front().indices == expected_indices);
    CHECK(meshes.front().vertices[1] == expected_vertex_x);
    CHECK(meshes.front().vertices[2] == expected_vertex_y);

    const auto asset = oblivion::decode_nif_asset(bytes);
    CHECK(asset.nodes.size() >= 1);
}

} // namespace

int main() {
    const auto directory = temp_dir();
    try {
        test_bsa(directory);
        test_bsa_rejects_implausible_output_size(directory);
        test_esm4(directory);
        test_loose_assets(directory);
        test_script_lexer();
        test_script_parser();
        test_command_table(directory);
        test_script_interpreter();
        test_nif_mesh_decoder();
        std::filesystem::remove_all(directory);
        return 0;
    } catch (const std::exception& error) {
        std::filesystem::remove_all(directory);
        std::cerr << "format_fixture_tests: " << error.what() << '\n';
        return 1;
    }
}
