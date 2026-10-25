#include "oblivion/bsa_archive.hpp"
#include "oblivion/command_table.hpp"
#include "oblivion/quest_runtime.hpp"
#include "oblivion/quest_driver.hpp"
#include "oblivion/quest_stage.hpp"
#include "oblivion/esm4_database.hpp"
#include "oblivion/game_data.hpp"
#include "oblivion/nif_mesh.hpp"
#include "oblivion/script_lexer.hpp"
#include "oblivion/script_interpreter.hpp"
#include "oblivion/script_parser.hpp"

#include <NifFile.hpp>

#include <array>
#include <cctype>
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

void test_loose_file_index_edge_cases(const std::filesystem::path& directory) {
    namespace fs = std::filesystem;
    const auto data = directory / "loose-edge";
    write_bytes(data / "Oblivion.esm", esm_fixture());
    // Files that differ only by case: possible on case-sensitive volumes only. The smallest on-disk path wins
    // ("Meshes" sorts before "meshes"), whatever order the directory lists them in.
    write_bytes(data / "meshes" / "case" / "dup.kf", Bytes{'l', 'o', 'w'});
    write_bytes(data / "Meshes" / "Case" / "Dup.KF", Bytes{'u', 'p'});
    std::error_code ec;
    const bool collided = fs::exists(data / "Meshes" / "Case" / "Dup.KF", ec) && fs::exists(data / "meshes" / "case" / "dup.kf", ec)
        && !fs::equivalent(data / "Meshes" / "Case" / "Dup.KF", data / "meshes" / "case" / "dup.kf", ec);
    // A directory that cannot be listed loses only its own files; the rest of the tree is still indexed.
    write_bytes(data / "aaa-locked" / "hidden.kf", Bytes{'x'});
    write_bytes(data / "zzz-open" / "visible.kf", Bytes{'v'});
    fs::permissions(data / "aaa-locked", fs::perms::none, ec);

    oblivion::GameData game;
    std::ostringstream log;
    game.open(data, oblivion::GameData::LoadProfile::Full, &log);
    fs::permissions(data / "aaa-locked", fs::perms::owner_all, ec);
    CHECK(game.read_asset("zzz-open\\visible.kf") == Bytes{'v'});
    if (collided) CHECK(game.read_asset("meshes\\case\\dup.kf") == (Bytes{'u', 'p'}));
    else std::cerr << "note: volume is case-insensitive, case collision not exercised\n";
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

void test_event_blocks_by_target() {
    // Three OnPackageDone blocks, one per package: the event with a package name runs only that block.
    const auto ast = oblivion::parse_script(
        "scn Packages\n"
        "short which\n"
        "begin OnPackageDone WalkA\n"
        "  set which to 1\n"
        "end\n"
        "begin OnPackageDone WalkB\n"
        "  set which to 2\n"
        "end\n");
    oblivion::ScriptInterpreter interpreter(ast);
    RecordingHost host;
    CHECK(interpreter.run_event("onpackagedone", "walkb", host).found_block);
    CHECK(interpreter.variables().at("which").number == 2.0);
    CHECK(!interpreter.run_event("OnPackageDone", "WalkC", host).found_block);
    CHECK(interpreter.run_event("OnPackageDone", "WalkA", host).found_block);
    CHECK(interpreter.variables().at("which").number == 1.0);
}

void test_script_fragment() {
    // A stage result has no header: its statements run as they are.
    const auto fragment = oblivion::parse_fragment(
        "set counter to 2\n"
        "if counter == 2\n"
        "  Player.Kill\n"
        "endif\n"
        "end\n"
        "set counter to 5\n");
    CHECK(fragment.diagnostics.size() == 1 && fragment.diagnostics[0].line == 5);
    CHECK(fragment.statements.size() == 3);

    const oblivion::ScriptAst no_script;
    oblivion::ScriptInterpreter interpreter(no_script);
    RecordingHost host;
    const auto result = interpreter.run_body(fragment.statements, host);
    CHECK(interpreter.variables().at("counter").number == 5.0);
    CHECK(result.unimplemented == std::vector<std::string>({"Kill"}));
    CHECK(host.last_target == "Player");
}

// Answers GetStage(quest) with a fixed stage and nothing else.
class StageHost final : public oblivion::ScriptHost {
public:
    double stage = 0;
    std::optional<oblivion::ScriptValue> call_command(std::string_view, const oblivion::ScriptValue*,
                                                      const std::vector<oblivion::ScriptValue>&) override {
        return std::nullopt;
    }
    std::optional<double> call_condition(std::uint16_t function_index, std::uint32_t parameter1, std::uint32_t) override {
        if (function_index == 58 && parameter1 == 0x100) return stage;
        return std::nullopt;
    }
};

void test_quest_conditions() {
    using oblivion::QuestCondition;
    // Operator bytes: 0x00 ==, 0x20 !=, 0x40 >, 0x60 >=, 0x80 <, 0xA0 <=; bit 0x01 joins the next condition with OR.
    CHECK(oblivion::condition_operator(0x61) == oblivion::ConditionOperator::GreaterEqual);
    CHECK(oblivion::condition_operator(0xA1) == oblivion::ConditionOperator::LessEqual);
    CHECK(oblivion::condition_joins_next(0x01) && !oblivion::condition_joins_next(0x60));

    const auto stage_is = [](std::uint8_t op, float value) {
        QuestCondition condition;
        condition.operator_code = op;
        condition.comparison = value;
        condition.function_index = 58;  // GetStage
        condition.parameter1 = 0x100;
        return condition;
    };
    StageHost host;
    host.stage = 20;
    CHECK(oblivion::evaluate_conditions({stage_is(0x00, 20.0f)}, host));
    CHECK(!oblivion::evaluate_conditions({stage_is(0x20, 20.0f)}, host));
    CHECK(oblivion::evaluate_conditions({stage_is(0x60, 15.0f)}, host));
    CHECK(!oblivion::evaluate_conditions({stage_is(0x40, 20.0f)}, host));
    CHECK(oblivion::evaluate_conditions({stage_is(0xA0, 20.0f)}, host));
    // Two OR-joined conditions: one of them holds, so the disjunction holds.
    CHECK(oblivion::evaluate_conditions({stage_is(0x01, 5.0f), stage_is(0x00, 20.0f)}, host));
    // Joined with AND (no OR bit): both must hold.
    CHECK(!oblivion::evaluate_conditions({stage_is(0x00, 20.0f), stage_is(0x00, 5.0f)}, host));
    // An unimplemented function is false and reported once.
    QuestCondition unknown;
    unknown.function_index = 365;
    std::vector<std::string> missing;
    CHECK(!oblivion::evaluate_conditions({unknown, unknown}, host, &missing));
    CHECK(missing == std::vector<std::string>({"condition 365"}));
}

void test_package_selection() {
    // Packages are chosen by the quest stage: the first whose condition holds starts.
    oblivion::AiPackageRecord walk_early;
    walk_early.editor_id = "WalkEarly";
    oblivion::QuestCondition at_fifteen;
    at_fifteen.function_index = 58;
    at_fifteen.parameter1 = 0x100;
    at_fifteen.comparison = 15.0f;
    walk_early.conditions = {at_fifteen};
    oblivion::AiPackageRecord walk_late;
    walk_late.editor_id = "WalkLate";
    oblivion::QuestCondition at_twenty = at_fifteen;
    at_twenty.comparison = 20.0f;
    walk_late.conditions = {at_twenty};
    oblivion::AiPackageRecord always;
    always.editor_id = "Always";
    const std::vector<const oblivion::AiPackageRecord*> packages{&walk_late, &walk_early, &always};

    StageHost host;
    host.stage = 15;
    CHECK(oblivion::select_package(packages, host) == &walk_early);
    host.stage = 20;
    CHECK(oblivion::select_package(packages, host) == &walk_late);
    host.stage = 3;
    CHECK(oblivion::select_package(packages, host) == &always);
    // With only conditional packages and no match, nothing is selected.
    CHECK(oblivion::select_package({&walk_early}, host) == nullptr);
}

void test_actor_package_event() {
    // The package's end runs OnPackageDone on the actor's script, which sets the quest to stage 16.
    oblivion::ScriptRecord actor_script;
    actor_script.editor_id = "ActorScript";
    actor_script.source = "scn Actor\nbegin OnPackageDone WalkB\n  setstage Driver 16\nend\n";
    oblivion::QuestRecord quest;
    quest.form_id = 0x700;
    quest.editor_id = "Driver";
    oblivion::QuestStage stage16;
    stage16.index = 16;
    oblivion::QuestStageEntry entry;
    entry.result_source = "Activate reachedStage16 1\n";
    stage16.entries.push_back(entry);
    quest.stages = {stage16};
    oblivion::ScriptRecord quest_script;
    quest_script.editor_id = "DriverScript";
    quest_script.source = "scn Driver\nbegin GameMode\nend\n";
    const oblivion::ScriptCommandLookup commands = [](std::string_view name) -> std::optional<oblivion::ScriptCommandSignature> {
        if (name == "setstage" || name == "Activate") return oblivion::ScriptCommandSignature{0, 2};
        return std::nullopt;
    };
    oblivion::QuestDriver driver(quest, quest_script, commands);
    driver.start(15);
    const auto event = driver.run_actor_event(actor_script, "OnPackageDone", "WalkB");
    CHECK(event.stage == 16);
    CHECK(event.stage_changes == std::vector<std::string>({"16"}));
    // The SetStage is recorded first, then what the new stage did (the order a stage result gives too).
    CHECK(event.actions.size() == 2 && event.actions[0].command == "setstage" && event.actions[1].command == "Activate");
    // The driver chooses a package by its own stage: stage 16 selects the package that waits for it.
    oblivion::AiPackageRecord at_fifteen;
    at_fifteen.editor_id = "AtFifteen";
    oblivion::QuestCondition fifteen;
    fifteen.function_index = 58;
    fifteen.parameter1 = 0x700;
    fifteen.comparison = 15.0f;
    at_fifteen.conditions = {fifteen};
    oblivion::AiPackageRecord at_sixteen;
    at_sixteen.editor_id = "AtSixteen";
    oblivion::QuestCondition sixteen = fifteen;
    sixteen.comparison = 16.0f;
    at_sixteen.conditions = {sixteen};
    const std::vector<const oblivion::AiPackageRecord*> packages{&at_fifteen, &at_sixteen};
    CHECK(driver.select_package(packages) == &at_sixteen);
    // A block for another package does nothing.
    const auto other = driver.run_actor_event(actor_script, "OnPackageDone", "WalkZ");
    CHECK(other.stage_changes.empty() && other.actions.empty());
}

void test_quest_stage_actions(const std::filesystem::path& directory) {
    // The fixture quest: stage 10 has a GetStage(0x100) == 20 entry that does not hold at 10, and
    // no-condition entries are checked in the ESM test. Here stage 20's completing entry runs.
    (void)directory;
    oblivion::QuestRecord quest;
    quest.form_id = 0x100;
    quest.editor_id = "FixtureQuest";
    oblivion::QuestStage stage;
    stage.index = 20;
    oblivion::QuestStageEntry entry;
    entry.completes = true;
    entry.result_source = "Player.moveto FixtureMarker\nset counter to 1\nActivate mySelf 1\n";
    stage.entries.push_back(entry);
    quest.stages.push_back(stage);
    oblivion::QuestStageEntry gated;
    oblivion::QuestCondition condition;
    condition.function_index = 58;
    condition.parameter1 = 0x100;
    condition.comparison = 99.0f;  // not the stage we run
    gated.conditions.push_back(condition);
    gated.result_source = "Activate ignored\n";
    quest.stages[0].entries.push_back(gated);

    oblivion::QuestState state;
    const auto runs = oblivion::run_quest_stage(quest, 20, {}, nullptr, state);
    CHECK(runs.size() == 2);
    CHECK(runs[0].conditions_hold && runs[0].completes);
    CHECK(runs[0].actions.size() == 2);  // the set statement is not a command call
    CHECK(runs[0].actions[0].command == "moveto" && runs[0].actions[0].target == "Player");
    CHECK(runs[0].actions[0].arguments.size() == 1 && runs[0].actions[0].arguments[0].text == "FixtureMarker");
    CHECK(runs[0].actions[1].command == "Activate" && runs[0].actions[1].arguments.size() == 2);
    CHECK(!runs[1].conditions_hold && runs[1].actions.empty());
    CHECK(oblivion::run_quest_stage(quest, 99, {}, nullptr, state).empty());

    // GetQuestVariable reads the quest variable named by the quest script's SLSD index.
    oblivion::ScriptRecord quest_script;
    quest_script.editor_id = "FixtureQuestScript";
    quest_script.variables.push_back({3, 0, "flag"});
    oblivion::QuestStageEntry guarded;
    oblivion::QuestCondition flag_set;
    flag_set.function_index = 79;  // GetQuestVariable
    flag_set.parameter1 = 0x100;
    flag_set.parameter2 = 3;
    flag_set.comparison = 1.0f;
    guarded.conditions.push_back(flag_set);
    guarded.result_source = "Activate guardedActor\n";
    oblivion::QuestRecord flagged = quest;
    flagged.stages[0].entries = {guarded};
    oblivion::QuestState unset;
    CHECK(!oblivion::run_quest_stage(flagged, 20, {}, &quest_script, unset)[0].conditions_hold);
    oblivion::QuestState set;
    set.variables["fixturequest.flag"] = 1.0;
    CHECK(oblivion::run_quest_stage(flagged, 20, {}, &quest_script, set)[0].conditions_hold);
    // An index the script does not declare reads as 0, so the condition is false.
    flag_set.parameter2 = 9;
    flagged.stages[0].entries[0].conditions = {flag_set};
    CHECK(!oblivion::run_quest_stage(flagged, 20, {}, &quest_script, set)[0].conditions_hold);
}

void test_quest_driver() {
    // GameMode counts ticks and sums GetSecondsPassed; at the second tick it sets stage 5.
    oblivion::ScriptRecord script;
    script.editor_id = "DriverScript";
    script.source =
        "scn Driver\n"
        "short ticks\n"
        "float elapsed\n"
        "begin GameMode\n"
        "  if getstage Driver == 0\n"
        "    set ticks to ticks + 1\n"
        "  endif\n"
        "  set elapsed to elapsed + getsecondspassed\n"
        "  if ticks == 2\n"
        "    setstage Driver 5\n"
        "  endif\n"
        "end\n";
    script.variables = {{1, 1, "ticks"}, {2, 2, "elapsed"}};
    oblivion::QuestRecord quest;
    quest.form_id = 0x700;
    quest.editor_id = "Driver";
    oblivion::QuestStage stage0;
    stage0.index = 0;
    oblivion::QuestStageEntry start_entry;
    start_entry.result_source = "Activate startActor 1\n";
    stage0.entries.push_back(start_entry);
    oblivion::QuestStage stage5;
    stage5.index = 5;
    oblivion::QuestStageEntry finish_entry;
    finish_entry.result_source = "Activate finishActor 1\n";
    stage5.entries.push_back(finish_entry);
    quest.stages = {stage0, stage5};

    // The table would say which names are commands; this lookup knows the ones the script uses.
    const oblivion::ScriptCommandLookup commands = [](std::string_view name) -> std::optional<oblivion::ScriptCommandSignature> {
        if (name == "getstage" || name == "setstage" || name == "getsecondspassed" || name == "Activate")
            return oblivion::ScriptCommandSignature{0, name == "getsecondspassed" ? 0u : 2u};
        return std::nullopt;
    };
    oblivion::QuestDriver driver(quest, script, commands);
    const auto started = driver.start(0);
    CHECK(started.stage == 0 && started.actions.size() == 1 && started.actions[0].command == "Activate");
    CHECK(started.stage_changes == std::vector<std::string>({"0"}));
    const auto first = driver.tick(0.25);
    CHECK(first.stage == 0 && first.stage_changes.size() == 0);
    CHECK(driver.state().variables.at("driver.ticks") == 1.0);
    CHECK(driver.state().variables.at("driver.elapsed") == 0.25);
    const auto second = driver.tick(0.5);
    CHECK(second.stage == 5 && second.stage_changes == std::vector<std::string>({"5"}));
    CHECK(driver.state().variables.at("driver.ticks") == 2.0);
    CHECK(driver.state().variables.at("driver.elapsed") == 0.75);
    // The stage 5 result ran during the tick that set it.
    bool finished = false;
    for (const auto& action : second.actions)
        if (!action.arguments.empty() && action.arguments[0].text == "finishActor") finished = true;
    CHECK(finished);
    // Stage 5 has no getstage(0) branch, so further ticks do not count.
    driver.tick(0.25);
    CHECK(driver.state().variables.at("driver.ticks") == 2.0);
}

void test_quest_world() {
    // Alpha's GameMode moves it to stage 1, whose result sets Beta to 2. Beta's GameMode then sees Alpha
    // through GetStageDone and moves to 4, whose result starts Gamma. Gamma's stage 0 result runs once.
    const auto quest_with = [](std::uint32_t form_id, std::string editor_id, std::vector<std::pair<unsigned, std::string>> results) {
        oblivion::QuestRecord quest;
        quest.form_id = form_id;
        quest.editor_id = std::move(editor_id);
        for (auto& [index, source] : results) {
            oblivion::QuestStage stage;
            stage.index = index;
            oblivion::QuestStageEntry entry;
            entry.result_source = std::move(source);
            stage.entries.push_back(entry);
            quest.stages.push_back(stage);
        }
        return quest;
    };
    const auto alpha = quest_with(0x800, "Alpha", {{1, "setstage Beta 2\n"}});
    const auto beta = quest_with(0x810, "Beta", {{2, "Activate betaReady 1\n"}, {4, "startquest Gamma\n"}});
    const auto gamma = quest_with(0x820, "Gamma", {{0, "Activate gammaStart 1\n"}});
    oblivion::ScriptRecord alpha_script;
    alpha_script.editor_id = "AlphaScript";
    alpha_script.source =
        "scn Alpha\n"
        "begin GameMode\n"
        "  if getstage Alpha == 0\n"
        "    setstage Alpha 1\n"
        "  endif\n"
        "end\n";
    oblivion::ScriptRecord beta_script;
    beta_script.editor_id = "BetaScript";
    beta_script.source =
        "scn Beta\n"
        "begin GameMode\n"
        "  if getstage Beta == 2\n"
        "    if getstagedone Alpha 1 == 1\n"
        "      setstage Beta 4\n"
        "    endif\n"
        "  endif\n"
        "end\n";
    oblivion::ScriptRecord gamma_script;
    gamma_script.editor_id = "GammaScript";
    gamma_script.source = "scn Gamma\n";

    const oblivion::ScriptCommandLookup commands = [](std::string_view name) -> std::optional<oblivion::ScriptCommandSignature> {
        if (name == "getstage" || name == "getstagedone" || name == "setstage") return oblivion::ScriptCommandSignature{2, 2};
        if (name == "startquest" || name == "Activate") return oblivion::ScriptCommandSignature{1, 2};
        if (name == "getsecondspassed") return oblivion::ScriptCommandSignature{0, 0};
        return std::nullopt;
    };
    oblivion::QuestWorld world(commands);
    world.add(alpha, alpha_script);
    world.add(beta, beta_script);
    world.add(gamma, gamma_script);
    CHECK(world.find("alpha") != nullptr && world.find_form(0x820) != nullptr && world.find("Missing") == nullptr);
    CHECK(world.start("Alpha", 0).stage == 0);
    CHECK(world.find("Beta")->stage() == 0 && !world.find("Beta")->has_entered(2));

    const auto first = world.tick(0.1);
    CHECK(world.find("Alpha")->stage() == 1);
    CHECK(world.find("Beta")->stage() == 4);
    CHECK(world.find("Beta")->has_entered(2) && world.find("Beta")->has_entered(4));
    CHECK(world.find("Gamma")->stage() == 0);
    bool saw_ready = false;
    bool saw_start = false;
    for (const auto& action : first.actions) {
        if (!action.arguments.empty() && action.arguments[0].text == "betaReady") saw_ready = true;
        if (!action.arguments.empty() && action.arguments[0].text == "gammaStart") saw_start = true;
    }
    CHECK(saw_ready && saw_start);
    CHECK(first.stage_changes == std::vector<std::string>({"1", "2", "4", "0"}));

    // Nothing is set again on later ticks, so the stage results do not run again.
    const auto later = world.tick(0.1);
    CHECK(later.stage_changes.empty() && later.actions.empty());

    const auto unknown = world.start("Missing", 0);
    CHECK(!unknown.parse_errors.empty());
}

// An IDLE record: MODL file (or folder), ANAM group, DATA parent and previous sibling, and conditions. `old_style`
// writes the 20-byte CTDT form of the conditions that the master also uses.
struct FixtureCondition {
    std::uint8_t op = 0;
    float comparison = 0.0f;
    std::uint32_t function = 0;
    std::uint32_t parameter1 = 0;
    std::uint32_t parameter2 = 0;
};
Bytes idle_record(std::uint32_t form_id, std::string_view editor_id, std::string_view file, std::uint8_t group_flags,
                  std::uint32_t parent, std::uint32_t previous, const std::vector<FixtureCondition>& conditions,
                  bool old_style = false) {
    Bytes data;
    append(data, string_subrecord("EDID", editor_id));
    append(data, string_subrecord("MODL", file));
    Bytes model_bounds;
    u32(model_bounds, 0);
    subrecord(data, "MODB", model_bounds);
    for (const auto& condition : conditions) {
        Bytes ctda;
        u8(ctda, condition.op); u8(ctda, 0); u8(ctda, 0); u8(ctda, 0);
        f32(ctda, condition.comparison);
        u32(ctda, condition.function);
        u32(ctda, condition.parameter1);
        u32(ctda, condition.parameter2);
        if (!old_style) u32(ctda, 0);
        subrecord(data, old_style ? "CTDT" : "CTDA", ctda);
    }
    Bytes flags;
    u8(flags, group_flags);
    subrecord(data, "ANAM", flags);
    Bytes links;
    u32(links, parent);
    u32(links, previous);
    subrecord(data, "DATA", links);
    return record("IDLE", form_id, data);
}

// Roots: Gestures (needs stage 1 of the quest) and Ambient. The records are written out of order: the tree is
// ordered by the previous-sibling links, not by file order.
Bytes idle_fixture() {
    constexpr std::uint32_t kQuest = 0x700;
    Bytes header;
    raw(header, "TES4");
    u32(header, 0); u32(header, 0); u32(header, 0); u32(header, 0);
    Bytes records;
    append(records, idle_record(0x901, "Ambient", "Characters\\_Male\\IdleAnims", 4, 0, 0x900, {}));
    append(records, idle_record(0x921, "Fallback", "Characters\\_Male\\IdleAnims\\Fallback.kf", 5, 0x901, 0x920, {}));
    append(records, idle_record(0x911, "Point", "Characters\\_Male\\IdleAnims\\Point.kf", 4, 0x900, 0x910,
                                {{0, 3.0f, 79, kQuest, 1}}, true));
    append(records, idle_record(0x900, "Gestures", "Characters\\_Male\\IdleAnims", 4, 0, 0, {{0, 1.0f, 58, kQuest, 0}}));
    append(records, idle_record(0x920, "Own", "Characters\\_Male\\IdleAnims\\Own.kf", 4, 0x901, 0x91f,
                                {{0, 1.0f, 72, 0xB0, 0}}));
    append(records, idle_record(0x910, "Wave", "Characters\\_Male\\IdleAnims\\Wave.kf", 4, 0x900, 0,
                                {{0, 1.0f, 79, kQuest, 1}}));
    // Asks about combat, which the scene cannot answer: never chosen, never fatal.
    append(records, idle_record(0x91f, "Combat", "Characters\\_Male\\IdleAnims\\Combat.kf", 4, 0x901, 0,
                                {{0, 1.0f, 289, 0, 0}}));
    append(header, group(0x454c4449, 0, records));  // "IDLE"
    return header;
}

constexpr std::uint32_t kIdleQuest = 0x700;

void test_idle_manager(const std::filesystem::path& directory) {
    const auto path = directory / "idles.esm";
    write_bytes(path, idle_fixture());
    oblivion::Esm4Database database;
    database.open(path);

    const auto ids = [&](std::uint32_t parent) {
        std::vector<std::uint32_t> result;
        for (const auto* idle : database.idle_children(parent)) result.push_back(idle->form_id);
        return result;
    };
    CHECK(ids(0) == std::vector<std::uint32_t>({0x900, 0x901}));
    CHECK(ids(0x900) == std::vector<std::uint32_t>({0x910, 0x911}));
    CHECK(ids(0x901) == std::vector<std::uint32_t>({0x91f, 0x920, 0x921}));
    CHECK(database.idle_children(0x910).empty() && database.idle_children(0xdead).empty());
    const auto* wave = database.find_idle(0x910);
    CHECK(wave != nullptr && wave->editor_id == "Wave" && !wave->is_folder());
    CHECK(wave->animation_file == "Characters\\_Male\\IdleAnims\\Wave.kf" && wave->group_flags == 4);
    CHECK(wave->parent_form_id == 0x900 && wave->previous_sibling_form_id == 0);
    CHECK(wave->conditions.size() == 1 && wave->conditions[0].function_index == 79 && wave->conditions[0].parameter2 == 1);
    const auto* point = database.find_idle(0x911);
    CHECK(point != nullptr && point->previous_sibling_form_id == 0x910);
    CHECK(point->conditions.size() == 1 && point->conditions[0].comparison == 3.0f && point->conditions[0].parameter1 == kIdleQuest);
    CHECK(database.find_idle(0x900)->is_folder() && database.find_idle(0x901)->conditions.empty());
    CHECK(database.find_idle(0x999) == nullptr);

    // The quest: stage 1 picks an idle with uniqueIdle at 3 and again after it was reset, for three actors.
    oblivion::QuestRecord quest;
    quest.form_id = kIdleQuest;
    quest.editor_id = "IdleQuest";
    oblivion::QuestStage stage;
    stage.index = 1;
    oblivion::QuestStageEntry entry;
    entry.result_source =
        "set IdleQuest.uniqueIdle to 3\n"
        "GlenRef.pickidle\n"
        "set IdleQuest.uniqueIdle to 1\n"
        "GlenRef.pickidle\n"
        "set IdleQuest.uniqueIdle to 0\n"
        "GlenRef.pickidle\n"
        "OtherRef.pickidle\n"
        "NobodyRef.pickidle\n";
    stage.entries.push_back(entry);
    quest.stages.push_back(stage);
    oblivion::QuestStage later;
    later.index = 2;
    oblivion::QuestStageEntry later_entry;
    later_entry.result_source = "set IdleQuest.uniqueIdle to 3\nGlenRef.pickidle\n";
    later.entries.push_back(later_entry);
    quest.stages.push_back(later);
    oblivion::ScriptRecord script;
    script.editor_id = "IdleQuestScript";
    script.source = "scn IdleQuest\nshort uniqueIdle\n";
    script.variables = {{1, 1, "uniqueIdle"}};
    const oblivion::ScriptCommandLookup commands = [](std::string_view name) -> std::optional<oblivion::ScriptCommandSignature> {
        if (name == "pickidle") return oblivion::ScriptCommandSignature{0, 0};
        return std::nullopt;
    };
    oblivion::QuestWorld world(commands);
    world.add(quest, script);
    world.set_idle_tree([&database](std::uint32_t parent) -> const std::vector<const oblivion::IdleRecord*>& {
        return database.idle_children(parent);
    });
    world.set_reference_base("GlenRef", 0xB0);
    world.set_reference_base("OtherRef", 0xB1);

    const auto picks = [](const oblivion::QuestTick& tick) {
        std::vector<std::string> result;
        for (const auto& action : tick.actions)
            if (action.command == "pickidle")
                result.push_back(action.target + ":" + action.arguments.at(1).text + ":" + action.arguments.at(0).text);
        return result;
    };
    const auto first = world.start("IdleQuest", 1);
    const std::string base = "Characters\\_Male\\IdleAnims\\";
    // uniqueIdle 3 reaches Point under the Gestures folder; 1 reaches Wave; with 0 the Gestures folder offers nothing, and
    // the Ambient folder gives Glen the idle that asks for his base, and the others its unconditioned last sibling.
    // The Combat idle in front of them asks something unanswered and is skipped.
    CHECK(picks(first) == std::vector<std::string>({
        "GlenRef:Point:" + base + "Point.kf", "GlenRef:Wave:" + base + "Wave.kf", "GlenRef:Own:" + base + "Own.kf",
        "OtherRef:Fallback:" + base + "Fallback.kf", "NobodyRef:Fallback:" + base + "Fallback.kf"}));
    // The group flags and form ID travel in the action.
    CHECK(first.actions.at(0).arguments.at(2).number == 0x911 && first.actions.at(0).arguments.at(3).number == 4);

    // A reply that sets uniqueIdle, calls PickIdle without a reference and resets it: the idle is for the speaker, and the
    // value that was set when the command ran counts, not the reset after it.
    oblivion::DialogTopic topic;
    topic.editor_id = "Greet";
    oblivion::DialogResponse reply;
    reply.form_id = 0xC00;
    reply.quest = kIdleQuest;
    reply.text = "Hello";
    reply.result_source = "set IdleQuest.uniqueIdle to 1\npickidle\nset IdleQuest.uniqueIdle to 0\n";
    topic.responses.push_back(reply);
    world.set_topic_finder([&topic](std::string_view id) { return id == "Greet" ? &topic : nullptr; });
    oblivion::QuestTick said;
    world.say("Greet", 0xB0, 0x14, said, {});
    CHECK(picks(said) == std::vector<std::string>({"glenref:Wave:" + base + "Wave.kf"}));
    CHECK(world.find("IdleQuest")->variable("uniqueIdle") == 0.0);

    // Deterministic: the same state gives the same idle again. In stage 2 the Gestures folder no longer holds (GetStage != 1).
    const auto second = world.start("IdleQuest", 2);
    CHECK(picks(second) == std::vector<std::string>({"GlenRef:Own:" + base + "Own.kf"}));

    // An unqualified PickIdle is for the speaker or the script's actor, found by its base; without an idle tree it is only recorded.
    oblivion::QuestTick direct;
    const auto* chosen = world.pick_idle("", 0xB1, direct);
    CHECK(chosen != nullptr && chosen->editor_id == "Fallback" && direct.actions.size() == 1);
    CHECK(direct.actions[0].target == "otherref");
    oblivion::QuestWorld bare(commands);
    oblivion::QuestTick nothing;
    CHECK(bare.pick_idle("GlenRef", 0, nothing) == nullptr);
    CHECK(nothing.actions.size() == 1 && nothing.actions[0].arguments.at(0).text.empty() && !nothing.unanswered.empty());
}

void test_world_answers() {
    // A low-health check reads GetAV of the player. Unanswered it reads 0, which is low; answered with full health it does not fire.
    oblivion::QuestRecord quest;
    quest.form_id = 0x830;
    quest.editor_id = "Health";
    oblivion::QuestStage stage1;
    stage1.index = 1;
    oblivion::QuestStageEntry entry;
    entry.result_source = "Activate healthLow 1\n";
    stage1.entries.push_back(entry);
    quest.stages = {stage1};
    oblivion::ScriptRecord script;
    script.editor_id = "HealthScript";
    script.source =
        "scn Health\n"
        "begin GameMode\n"
        "  if player.getav health < 40\n"
        "    setstage Health 1\n"
        "  endif\n"
        "end\n";
    const oblivion::ScriptCommandLookup commands = [](std::string_view name) -> std::optional<oblivion::ScriptCommandSignature> {
        if (name == "getav") return oblivion::ScriptCommandSignature{1, 1};
        if (name == "setstage") return oblivion::ScriptCommandSignature{2, 2};
        if (name == "Activate") return oblivion::ScriptCommandSignature{1, 2};
        return std::nullopt;
    };

    oblivion::QuestWorld unanswered(commands);
    unanswered.add(quest, script);
    unanswered.start("Health", 0);
    unanswered.tick(0.1);
    CHECK(unanswered.find("Health")->stage() == 1);

    oblivion::QuestWorld answered(commands);
    answered.set_answer([](std::string_view command, const oblivion::ScriptValue* target, const std::vector<oblivion::ScriptValue>& arguments) -> std::optional<oblivion::ScriptValue> {
        if (command == "getav" && target && target->is_text && target->text == "player" && !arguments.empty() && arguments[0].text == "health")
            return oblivion::ScriptValue::from_number(100.0);
        return std::nullopt;
    });
    answered.add(quest, script);
    answered.start("Health", 0);
    answered.tick(0.1);
    CHECK(answered.find("Health")->stage() == 0);
}

void test_cross_quest_variables() {
    // Setter's stage 0 writes Holder's variable, then reads it back: the write reaches Holder's state and the read sees it.
    oblivion::QuestRecord holder;
    holder.form_id = 0x840;
    holder.editor_id = "Holder";
    oblivion::ScriptRecord holder_script;
    holder_script.editor_id = "HolderScript";
    holder_script.source = "scn Holder\nshort level\n";
    holder_script.variables = {{1, 1, "level"}};

    oblivion::QuestRecord setter;
    setter.form_id = 0x850;
    setter.editor_id = "Setter";
    oblivion::QuestStage stage0;
    stage0.index = 0;
    oblivion::QuestStageEntry entry;
    entry.result_source = "set Holder.level to 4\nif Holder.level == 4\n  Activate sawLevel 1\nendif\n";
    stage0.entries.push_back(entry);
    setter.stages = {stage0};
    oblivion::ScriptRecord setter_script;
    setter_script.editor_id = "SetterScript";
    setter_script.source = "scn Setter\n";

    const oblivion::ScriptCommandLookup commands = [](std::string_view name) -> std::optional<oblivion::ScriptCommandSignature> {
        if (name == "Activate") return oblivion::ScriptCommandSignature{1, 2};
        return std::nullopt;
    };
    oblivion::QuestWorld world(commands);
    world.add(holder, holder_script);
    world.add(setter, setter_script);
    const auto started = world.start("Setter", 0);
    CHECK(world.find("Holder")->state().variables.at("holder.level") == 4.0);
    bool saw = false;
    for (const auto& action : started.actions)
        if (!action.arguments.empty() && action.arguments[0].text == "sawLevel") saw = true;
    CHECK(saw);
}

void test_stage_writes_survive_game_mode() {
    // GameMode sets `next` to 7 and then sets the stage; the stage's result sets it to 9. The value the stage set is the
    // one that stays, so the GameMode's own write does not overwrite it when it ends.
    oblivion::QuestRecord quest;
    quest.form_id = 0x860;
    quest.editor_id = "Chain";
    oblivion::QuestStage stage5;
    stage5.index = 5;
    oblivion::QuestStageEntry entry;
    entry.result_source = "set Chain.next to 9\n";
    stage5.entries.push_back(entry);
    quest.stages = {stage5};
    oblivion::ScriptRecord script;
    script.editor_id = "ChainScript";
    script.source =
        "scn Chain\n"
        "short next\n"
        "begin GameMode\n"
        "  if getstage Chain == 0\n"
        "    set next to 7\n"
        "    setstage Chain 5\n"
        "  endif\n"
        "end\n";
    script.variables = {{1, 1, "next"}};
    const oblivion::ScriptCommandLookup commands = [](std::string_view name) -> std::optional<oblivion::ScriptCommandSignature> {
        if (name == "getstage") return oblivion::ScriptCommandSignature{2, 2};
        if (name == "setstage") return oblivion::ScriptCommandSignature{2, 2};
        return std::nullopt;
    };
    oblivion::QuestWorld world(commands);
    world.add(quest, script);
    world.start("Chain", 0);
    world.tick(0.1);
    CHECK(world.find("Chain")->stage() == 5);
    CHECK(world.find("Chain")->state().variables.at("chain.next") == 9.0);
}

void test_short_circuit() {
    // The right side of && and || is not evaluated when the left side decides: its command is never asked.
    struct CountingHost final : oblivion::ScriptHost {
        std::vector<std::string> asked;
        std::optional<oblivion::ScriptValue> call_command(std::string_view name, const oblivion::ScriptValue*,
                                                          const std::vector<oblivion::ScriptValue>&) override {
            asked.push_back(std::string(name));
            return oblivion::ScriptValue::from_number(1.0);
        }
    };
    const oblivion::ScriptCommandLookup commands = [](std::string_view name) -> std::optional<oblivion::ScriptCommandSignature> {
        if (name == "Probe") return oblivion::ScriptCommandSignature{0, 0};
        return std::nullopt;
    };
    const auto ast = oblivion::parse_script(
        "scn Short\n"
        "begin GameMode\n"
        "  if 0 == 1 && Probe\n"
        "    set asked to 1\n"
        "  endif\n"
        "  if 1 == 1 || Probe\n"
        "    set asked to asked + 1\n"
        "  endif\n"
        "  if 1 == 0 && Probe\n"
        "    set asked to asked + 1\n"
        "  endif\n"
        "end\n", commands);
    oblivion::ScriptInterpreter interpreter(ast);
    CountingHost host;
    interpreter.run("gamemode", host);
    CHECK(host.asked.empty());
}

void test_same_stage_is_ignored() {
    // Setting the stage a quest is already in runs nothing: the stage's result runs once.
    oblivion::QuestRecord quest;
    quest.form_id = 0x870;
    quest.editor_id = "Once";
    oblivion::QuestStage stage3;
    stage3.index = 3;
    oblivion::QuestStageEntry entry;
    entry.result_source = "Activate onceRan 1\n";
    stage3.entries.push_back(entry);
    quest.stages = {stage3};
    oblivion::ScriptRecord script;
    script.editor_id = "OnceScript";
    script.source = "scn Once\n";
    const oblivion::ScriptCommandLookup commands = [](std::string_view name) -> std::optional<oblivion::ScriptCommandSignature> {
        if (name == "Activate") return oblivion::ScriptCommandSignature{1, 2};
        return std::nullopt;
    };
    oblivion::QuestWorld world(commands);
    world.add(quest, script);
    const auto first = world.start("Once", 3);
    CHECK(first.actions.size() == 1);
    oblivion::QuestTick again;
    world.set_stage("Once", 3, again, {}, 0);
    CHECK(again.stage_changes.empty() && again.actions.empty());
}

void test_dotted_condition_parses() {
    // A quest variable in an if condition (Ref.variable <= 0) is a read, not a command: it parses without diagnostics.
    const oblivion::ScriptCommandLookup commands = [](std::string_view name) -> std::optional<oblivion::ScriptCommandSignature> {
        if (name == "SayTo") return oblivion::ScriptCommandSignature{2, 3};
        if (name == "getstage") return oblivion::ScriptCommandSignature{1, 1};
        return std::nullopt;
    };
    const auto ast = oblivion::parse_script(
        "scn Glenroy\n"
        "begin gamemode\n"
        "if getstage charactergen == 13\n"
        "  if charactergen.convTimer <= 0\n"
        "    SayTo player CharGenVoice 1\n"
        "    set charactergen.convTimer to 7\n"
        "  endif\n"
        "endif\n"
        "end\n", commands);
    for (const auto& diagnostic : ast.diagnostics) std::cerr << "DIAG line " << diagnostic.line << ": " << diagnostic.message << "\n";
    CHECK(ast.diagnostics.empty());
}

void test_subtraction_after_variable_parses() {
    // `Ref.variable - .4` is a subtraction, even though `-` is followed by a number.
    const oblivion::ScriptCommandLookup commands = [](std::string_view name) -> std::optional<oblivion::ScriptCommandSignature> {
        if (name == "setstage") return oblivion::ScriptCommandSignature{2, 2};
        return std::nullopt;
    };
    const auto fragment = oblivion::parse_fragment(
        "set characterGen.convTimer to characterGen.convTimer - .4 ; cut him off\nsetstage characterGen 9\n", commands);
    for (const auto& diagnostic : fragment.diagnostics) std::cerr << "DIAG line " << diagnostic.line << ": " << diagnostic.message << "\n";
    CHECK(fragment.diagnostics.empty());
}

void test_subtraction_without_command_table() {
    // With no command table a name followed by `-` and a number is a subtraction, not a call with a negative argument.
    const auto fragment = oblivion::parse_fragment("set fTimer to fTimer - 1\n");
    CHECK(fragment.diagnostics.empty());
    CHECK(fragment.statements.size() == 1);
    const auto& value = fragment.statements[0].children.at(0);
    CHECK(value.kind == oblivion::ScriptExprKind::Binary && value.text == "-");
    CHECK(value.children.size() == 2 && value.children[0].kind == oblivion::ScriptExprKind::Name);
    // Arguments that are plain still make a call.
    const auto call = oblivion::parse_fragment("setstage MyQuest 10\n");
    CHECK(call.diagnostics.empty() && call.statements.at(0).children.at(0).kind == oblivion::ScriptExprKind::Call);
}

std::string operator_chain(int terms) {
    std::string source = "set x to 1";
    for (int i = 1; i < terms; ++i) source += " + 1";
    return source + "\n";
}

void test_operator_chain_depth_is_bounded() {
    // A long chain builds a left-deep tree in a loop; it must be reported, not recursed into until the stack ends.
    CHECK(oblivion::parse_fragment(operator_chain(100)).diagnostics.empty());
    const auto too_long = oblivion::parse_fragment(operator_chain(5000) + "set y to 2\n");
    CHECK(!too_long.diagnostics.empty());
    // The statement after the broken line still parses.
    CHECK(!too_long.statements.empty() && too_long.statements.back().name == "y");
    // The limit is per expression: many short statements are fine.
    std::string many;
    for (int i = 0; i < 50; ++i) many += operator_chain(100);
    CHECK(oblivion::parse_fragment(many).diagnostics.empty());
}

// Folders that contain each other (A -> B, C; B -> A, C; C -> A, B) must end the walk, and each folder is asked once.
void test_idle_folder_cycle_ends() {
    oblivion::IdleRecord a, b, c;
    a.form_id = 0x1;
    b.form_id = 0x2;
    c.form_id = 0x3;  // empty animation_file: all three are folders
    const std::vector<const oblivion::IdleRecord*> roots{&a};
    const std::vector<const oblivion::IdleRecord*> of_a{&b, &c}, of_b{&a, &c}, of_c{&a, &b};
    const std::vector<const oblivion::IdleRecord*> none;
    int lookups = 0;
    const oblivion::IdleChildren children = [&](std::uint32_t parent) -> const std::vector<const oblivion::IdleRecord*>& {
        ++lookups;
        switch (parent) {
        case 0: return roots;
        case 0x1: return of_a;
        case 0x2: return of_b;
        case 0x3: return of_c;
        default: return none;
        }
    };
    StageHost host;
    CHECK(oblivion::select_idle(children, host) == nullptr);
    CHECK(lookups == 4);

    // An animation reachable through a folder reached twice is still found.
    oblivion::IdleRecord clip;
    clip.form_id = 0x4;
    clip.animation_file = "Wave.kf";
    const std::vector<const oblivion::IdleRecord*> of_c_with_clip{&a, &clip};
    const oblivion::IdleChildren with_clip = [&](std::uint32_t parent) -> const std::vector<const oblivion::IdleRecord*>& {
        if (parent == 0x3) return of_c_with_clip;
        return children(parent);
    };
    const auto* found = oblivion::select_idle(with_clip, host);
    CHECK(found != nullptr && found->form_id == 0x4);
}

// An `if` nested past the limit is reported and skipped as a whole, so the `endif`s of the outer ifs still match.
void test_deep_if_nesting_keeps_structure() {
    std::string source = "begin onLoad\n";
    const int depth = 70;
    for (int i = 0; i < depth; ++i) source += "if x == 1\n";
    source += "set deep to 1\n";
    for (int i = 0; i < depth; ++i) source += "endif\n";
    source += "set after to 2\nend\n";
    const auto ast = oblivion::parse_script(source);
    for (const auto& d : ast.diagnostics) std::cerr << "DIAG line " << d.line << ": " << d.message << "\n";
    CHECK(ast.diagnostics.size() == 1);  // only the first too-deep `if`
    CHECK(ast.blocks.size() == 1 && !ast.blocks[0].body.empty());
    // The statement after the outermost `endif` is still at the top level of the block.
    CHECK(ast.blocks[0].body.size() == 2 && ast.blocks[0].body[1].name == "after");
}

// Commands the review tests use, matched without regard to case.
oblivion::ScriptCommandLookup review_commands() {
    return [](std::string_view name) -> std::optional<oblivion::ScriptCommandSignature> {
        std::string lowered(name);
        for (auto& c : lowered) c = static_cast<char>(std::tolower(static_cast<unsigned char>(c)));
        if (lowered == "getstage") return oblivion::ScriptCommandSignature{1, 1};
        if (lowered == "setstage") return oblivion::ScriptCommandSignature{2, 2};
        if (lowered == "sayto") return oblivion::ScriptCommandSignature{2, 3};
        if (lowered == "activate") return oblivion::ScriptCommandSignature{1, 3};
        if (lowered == "getdistance") return oblivion::ScriptCommandSignature{1, 1};
        return std::nullopt;
    };
}

oblivion::QuestRecord review_quest(std::uint32_t form_id, std::string editor_id,
                                   std::vector<std::pair<unsigned, std::string>> results) {
    oblivion::QuestRecord quest;
    quest.form_id = form_id;
    quest.editor_id = std::move(editor_id);
    for (auto& [index, source] : results) {
        oblivion::QuestStage stage;
        stage.index = static_cast<std::uint16_t>(index);
        oblivion::QuestStageEntry entry;
        entry.result_source = std::move(source);
        stage.entries.push_back(std::move(entry));
        quest.stages.push_back(std::move(stage));
    }
    return quest;
}

oblivion::ScriptRecord review_script(std::string editor_id, std::string source, std::vector<std::string> variables = {}) {
    oblivion::ScriptRecord script;
    script.editor_id = std::move(editor_id);
    script.source = std::move(source);
    std::uint32_t index = 1;
    for (auto& name : variables) script.variables.push_back({index++, 1, std::move(name)});
    return script;
}

oblivion::DialogTopic review_topic(std::string editor_id, std::uint32_t quest, std::string result) {
    oblivion::DialogTopic topic;
    topic.editor_id = std::move(editor_id);
    oblivion::DialogResponse reply;
    reply.form_id = 0x9000 + quest;
    reply.quest = quest;
    reply.text = "line";
    reply.result_source = std::move(result);
    topic.responses.push_back(std::move(reply));
    return topic;
}

bool has_error(const oblivion::QuestTick& tick, const std::string& part) {
    for (const auto& error : tick.parse_errors)
        if (error.find(part) != std::string::npos) return true;
    return false;
}

void test_actor_variables_stay_out_of_quest() {
    // The NPC's script and the quest both declare `state`. The actor's events keep their own copy: the quest's value
    // is untouched, and the actor's variables carry over between its events (run by the driver or by the world).
    oblivion::QuestWorld world(review_commands());
    const auto quest = review_quest(0xA00, "Q", {});
    const auto quest_script = review_script("QScript", "scn Q\nshort state\nbegin GameMode\nend\n", {"state"});
    auto& driver = world.add(quest, quest_script);
    driver.state().variables["q.state"] = 3.0;
    const auto actor_script = review_script("ActorScript",
        "scn Actor\nshort state\nshort calls\n"
        "begin OnPackageDone WalkB\n  set state to 7\n  set calls to calls + 1\n  Activate dummy calls\nend\n"
        "begin OnPackageDone WalkC\n  set calls to calls + 10\n  Activate dummy calls\nend\n");
    const auto first = driver.run_actor_event(actor_script, "OnPackageDone", "WalkB");
    CHECK(driver.state().variables.at("q.state") == 3.0);
    CHECK(first.actions.size() == 1 && first.actions[0].arguments[1].number == 1.0);
    const auto object = world.run_object_event(actor_script, "OnPackageDone", "WalkC");
    CHECK(object.actions.size() == 1 && object.actions[0].arguments[1].number == 11.0);
    const auto again = driver.run_actor_event(actor_script, "OnPackageDone", "WalkB");
    CHECK(again.actions[0].arguments[1].number == 12.0);
    CHECK(driver.state().variables.at("q.state") == 3.0);
    CHECK(driver.state().variables.count("q.calls") == 0);
}

void test_say_to_cycles_stop() {
    // A:10 -> SayTo T1 -> SetStage A 20 -> SayTo T2 -> SetStage A 10: the cycle ends instead of recursing without bound.
    oblivion::QuestWorld world(review_commands());
    const auto quest = review_quest(0xB00, "A", {{10, "Spk.SayTo player T1\n"}, {20, "Spk.SayTo player T2\n"}});
    const auto script = review_script("AScript", "scn A\n");
    world.add(quest, script);
    const auto t1 = review_topic("T1", 0xB00, "setstage A 20\n");
    const auto t2 = review_topic("T2", 0xB00, "setstage A 10\n");
    world.set_topic_finder([&](std::string_view id) { return id == "T1" ? &t1 : id == "T2" ? &t2 : nullptr; });
    const auto started = world.start("A", 10);
    CHECK(started.stage == 20);  // not 10: the second entry of stage 10 was refused
    CHECK(has_error(started, "sets itself again"));

    // A chain of distinct stages is bounded by its depth.
    std::vector<std::pair<unsigned, std::string>> results;
    std::vector<oblivion::DialogTopic> topics;
    for (unsigned i = 1; i <= 30; ++i) {
        results.push_back({i, "Spk.SayTo player Chain" + std::to_string(i) + "\n"});
        topics.push_back(review_topic("Chain" + std::to_string(i), 0xB10, "setstage B " + std::to_string(i + 1) + "\n"));
    }
    oblivion::QuestWorld deep(review_commands());
    const auto deep_quest = review_quest(0xB10, "B", results);
    const auto deep_script = review_script("BScript", "scn B\n");
    deep.add(deep_quest, deep_script);
    deep.set_topic_finder([&](std::string_view id) -> const oblivion::DialogTopic* {
        for (const auto& topic : topics)
            if (topic.editor_id == id) return &topic;
        return nullptr;
    });
    const auto run = deep.start("B", 1);
    CHECK(run.stage < 30 && run.stage >= 2);
    CHECK(has_error(run, "deeper than"));
}

void test_stage_oscillation_is_deterministic() {
    // A:10 -> A:20 -> A:10 through stage results alone: the quest stays in 20 and each result ran once.
    oblivion::QuestWorld world(review_commands());
    const auto quest = review_quest(0xC00, "Osc", {{10, "Activate ten\nsetstage Osc 20\n"}, {20, "Activate twenty\nsetstage Osc 10\n"}});
    const auto script = review_script("OscScript", "scn Osc\n");
    world.add(quest, script);
    const auto started = world.start("Osc", 10);
    CHECK(started.stage == 20);
    std::size_t activations = 0;
    for (const auto& action : started.actions)
        if (action.command == "Activate") ++activations;
    CHECK(activations == 2);
}

void test_bare_quest_variables_in_results() {
    // A stage result and a topic result read and write the quest's variable by its bare name.
    oblivion::QuestWorld world(review_commands());
    const auto quest = review_quest(0xD00, "Q", {{5, "if bDone == 0\n  set bDone to 1\n  Activate first\nendif\nif bDone == 1\n  Activate second\nendif\n"}});
    const auto script = review_script("QScript", "scn Q\nshort bDone\nshort bOther\nbegin GameMode\nend\n", {"bDone", "bOther"});
    auto& driver = world.add(quest, script);
    const auto started = world.start("Q", 5);
    CHECK(driver.state().variables.at("q.bdone") == 1.0);
    CHECK(started.actions.size() == 2 && started.actions[0].arguments[0].text == "first" && started.actions[1].arguments[0].text == "second");
    CHECK(driver.variable("bDone") == 1.0);

    const auto topic = review_topic("T", 0xD00, "if bDone == 1\n  set bOther to 5\nendif\nset Q.bDone to 2\n");
    oblivion::DialogueContext context;
    const auto run = driver.run_topic(topic, context);
    CHECK(run.reply != nullptr);
    CHECK(driver.state().variables.at("q.bother") == 5.0);
    CHECK(driver.state().variables.at("q.bdone") == 2.0);
}

void test_stale_foreign_variable() {
    // A's GameMode sets B.x, then B's stage sets B.x to 9. The GameMode's cached copy does not overwrite it afterwards.
    oblivion::QuestWorld world(review_commands());
    const auto a = review_quest(0xE00, "A", {});
    const auto a_script = review_script("AScript", "scn A\nbegin GameMode\n  set B.x to 1\n  setstage B 5\nend\n");
    const auto b = review_quest(0xE10, "B", {{5, "set B.x to 9\n"}});
    const auto b_script = review_script("BScript", "scn B\nshort x\nbegin GameMode\nend\n", {"x"});
    world.add(a, a_script);
    world.add(b, b_script);
    world.start("A", 0);
    world.tick(0.1);
    CHECK(world.find("B")->variable("x") == 9.0);
}

void test_modulo_and_stage_numbers_are_safe() {
    const auto ast = oblivion::parse_script(
        "scn Mod\nshort a\nshort b\nshort c\nfloat d\n"
        "begin GameMode\n"
        "  set a to 7 % 0.5\n"
        "  set b to 7 % 0 - 1\n"
        "  set c to 7 % 3\n"
        "  set d to 5 / 2\n"
        "end\n");
    oblivion::ScriptInterpreter interpreter(ast);
    RecordingHost host;
    interpreter.run("GameMode", host);
    CHECK(interpreter.variables().at("a").number == 0.0);
    CHECK(interpreter.variables().at("c").number == 1.0);
    // A divisor of -1 and one that is not finite are refused rather than trapping.
    const auto edge = oblivion::parse_script(
        "scn Edge\nfloat r\nfloat s\nbegin GameMode\n  set r to 0 - 9000000000000000000 * 2\n  set s to r % 0 - 1\n  set s to s % r\nend\n");
    oblivion::ScriptInterpreter edge_interpreter(edge);
    edge_interpreter.run("GameMode", host);
    CHECK(edge_interpreter.variables().at("s").number == 0.0);

    // SetStage with a negative stage is refused in a stage result and in a GameMode.
    oblivion::QuestWorld world(review_commands());
    const auto quest = review_quest(0xF00, "N", {{1, "setstage N -1\n"}});
    const auto script = review_script("NScript", "scn N\nfloat neg\nbegin GameMode\n  set neg to 0 - 5\n  setstage N neg\nend\n");
    world.add(quest, script);
    const auto started = world.start("N", 1);
    CHECK(started.stage == 1 && has_error(started, "valid number"));
    const auto ticked = world.tick(0.1);
    CHECK(ticked.stage_changes.empty() && world.find("N")->stage() == 1);
}

void test_integer_semantics_and_unresolved_names() {
    const auto ast = oblivion::parse_script(
        "scn Ints\nshort i\nlong l\nfloat f\nshort r\n"
        "begin GameMode\n"
        "  set i to 5 / 2\n"
        "  set l to 0 - 7 / 2\n"
        "  set f to 5 / 2\n"
        "  if typo\n    set r to 1\n  endif\n"
        "  if !typo\n    set r to r + 2\n  endif\n"
        "end\n");
    oblivion::ScriptInterpreter interpreter(ast);
    RecordingHost host;
    interpreter.run("GameMode", host);
    CHECK(interpreter.variables().at("i").number == 2.0);
    CHECK(interpreter.variables().at("l").number == -3.0);
    CHECK(interpreter.variables().at("f").number == 2.5);
    // A name that is no variable is not a truth value: a misspelled variable is false, and `!` of it is true.
    CHECK(interpreter.variables().at("r").number == 2.0);

    // The trace can be turned off.
    oblivion::ScriptInterpreter quiet(ast);
    quiet.set_trace(false);
    CHECK(quiet.run("GameMode", host).trace.empty());
    CHECK(!interpreter.run("GameMode", host).trace.empty());
}

void test_parser_limits() {
    // A missing `endif` is one diagnostic: the block's `end` and the next block are still read.
    const auto missing = oblivion::parse_script(
        "scn Missing\nbegin GameMode\n  if 1\n    set a to 1\nend\nbegin OnX\n  set b to 2\nend\n");
    CHECK(missing.diagnostics.size() == 1);
    CHECK(missing.diagnostics[0].message.find("endif") != std::string::npos);
    CHECK(missing.blocks.size() == 2 && missing.blocks[1].body.size() == 1);

    // Deeply nested parentheses, unary operators and ifs are reported, not recursed into.
    const auto parens = oblivion::parse_script("scn P\nbegin GameMode\n  set a to " + std::string(5000, '(') + "1" +
                                               std::string(5000, ')') + "\n  set b to 1\nend\n");
    CHECK(!parens.diagnostics.empty() && parens.blocks.size() == 1 && parens.blocks[0].body.size() == 1);
    const auto unary = oblivion::parse_script("scn U\nbegin GameMode\n  set a to " + std::string(5000, '-') + "1\nend\n");
    CHECK(!unary.diagnostics.empty());
    std::string nested = "scn D\nbegin GameMode\n";
    for (int i = 0; i < 500; ++i) nested += "if 1\n";
    for (int i = 0; i < 500; ++i) nested += "endif\n";
    nested += "end\n";
    CHECK(!oblivion::parse_script(nested).diagnostics.empty());
}

void test_world_changes_during_tick() {
    // The scene's distance callback unloads the cell in the middle of the tick. The run goes on with the actors it
    // had; the change takes effect when it ends.
    oblivion::QuestWorld world(review_commands());
    const auto actor = review_script("Act", "scn Act\nshort n\nbegin GameMode\n  set n to n + 1\n  if GetDistance player > 5\n    Activate far\n  endif\nend\n");
    world.add_actor(0x100, actor, "RefA");
    world.add_actor(0x101, actor, "RefB");
    int calls = 0;
    const oblivion::DistanceFunction distance = [&](std::string_view, std::string_view) -> std::optional<double> {
        ++calls;
        world.clear_actors();
        world.add_actor(0x102, actor, "RefC");
        return 10.0;
    };
    const auto first = world.tick(0.1, distance);
    CHECK(calls == 2 && first.actions.size() == 2);
    // The actors are the one added during the tick, after the clear.
    world.tick(0.1, distance);
    CHECK(calls == 3);
}

void test_global_comparison() {
    // A condition compared against a global asks the host for it; an unknown global leaves the condition false.
    struct GlobalHost final : oblivion::ScriptHost {
        std::optional<oblivion::ScriptValue> call_command(std::string_view, const oblivion::ScriptValue*,
                                                          const std::vector<oblivion::ScriptValue>&) override { return std::nullopt; }
        std::optional<double> call_condition(std::uint16_t, std::uint32_t, std::uint32_t) override { return 3.0; }
        std::optional<double> global_value(std::uint32_t form_id) override {
            if (form_id == 0x77) return 3.0;
            return std::nullopt;
        }
    } host;
    oblivion::QuestCondition condition;
    condition.function_index = 58;
    condition.comparison_is_global = true;
    condition.comparison_global_form_id = 0x77;
    CHECK(oblivion::evaluate_conditions({condition}, host));
    condition.comparison_global_form_id = 0x78;
    std::vector<std::string> missing;
    CHECK(!oblivion::evaluate_conditions({condition}, host, &missing));
    CHECK(missing.size() == 1);
}

std::vector<std::string> action_commands(const oblivion::QuestTick& tick) {
    std::vector<std::string> result;
    for (const auto& action : tick.actions)
        if (action.command != "speech") result.push_back(action.command);
    return result;
}

void test_set_stage_order_is_the_same_everywhere() {
    // The same commands leave the same actions in the same order whether they run as a stage result (collected,
    // then applied) or in a GameMode / topic / actor script (applied at once): the command, then what it caused.
    const std::vector<std::string> expected{"Activate", "setstage", "Activate", "Activate"};  // a, SetStage, n, b
    oblivion::QuestWorld results_world(review_commands());
    const auto results_quest = review_quest(0x1100, "Q", {{1, "Activate a\nsetstage Q 2\nActivate b\n"}, {2, "Activate n\n"}});
    const auto plain_script = review_script("QScript", "scn Q\n");
    results_world.add(results_quest, plain_script);
    const auto from_results = results_world.start("Q", 1);
    CHECK(action_commands(from_results) == expected);
    CHECK(from_results.actions[2].arguments[0].text == "n" && from_results.actions[3].arguments[0].text == "b");

    oblivion::QuestWorld mode_world(review_commands());
    const auto mode_quest = review_quest(0x1101, "Q", {{0, ""}, {2, "Activate n\n"}});
    const auto mode_script = review_script("QScript", "scn Q\nbegin GameMode\n  Activate a\n  setstage Q 2\n  Activate b\nend\n");
    mode_world.add(mode_quest, mode_script);
    mode_world.start("Q", 0);
    const auto from_game_mode = mode_world.tick(0.1);
    CHECK(action_commands(from_game_mode) == expected);
    CHECK(from_game_mode.actions[2].arguments[0].text == "n" && from_game_mode.actions[3].arguments[0].text == "b");

    // Through another quest, from a topic and from an actor's script.
    const auto owner = review_quest(0x1102, "Owner", {{0, ""}});
    const auto target = review_quest(0x1103, "Target", {{0, ""}, {2, "Activate n\n"}});
    const auto owner_script = review_script("OwnerScript", "scn Owner\n");
    const auto target_script = review_script("TargetScript", "scn Target\n");
    oblivion::QuestWorld topic_world(review_commands());
    topic_world.add(owner, owner_script);
    topic_world.add(target, target_script);
    topic_world.start("Owner", 0);
    topic_world.start("Target", 0);
    const auto topic = review_topic("T", 0x1102, "Activate a\nsetstage Target 2\nActivate b\n");
    topic_world.set_topic_finder([&](std::string_view id) { return id == "T" ? &topic : nullptr; });
    oblivion::QuestTick said;
    topic_world.say("T", 0, 0, said, {});
    CHECK(action_commands(said) == expected);

    oblivion::QuestWorld actor_world(review_commands());
    actor_world.add(target, target_script);
    actor_world.start("Target", 0);
    const auto actor_script = review_script("Act", "scn Act\nbegin GameMode\n  Activate a\n  setstage Target 2\n  Activate b\nend\n");
    actor_world.add_actor(0x100, actor_script, "RefA");
    CHECK(action_commands(actor_world.tick(0.1)) == expected);
}

void test_lower_entered_stage_is_not_rerun() {
    // OnHit sets stage 24, whose results set 23 again ("make sure"): after the first blow, later blows run nothing.
    oblivion::QuestWorld world(review_commands());
    const auto quest = review_quest(0xB10, "Ping", {{23, "Activate ranTwentyThree 1\n"}, {24, "setstage Ping 23\n"}});
    const auto script = review_script("PingScript", "scn Ping\n");
    world.add(quest, script);
    world.start("Ping", 23);
    oblivion::QuestTick first;
    world.set_stage("Ping", 24, first, {}, 0);
    CHECK(first.stage_changes.size() == 1);  // 24 entered; its request for the entered stage 23 below it did nothing
    oblivion::QuestTick second;
    world.set_stage("Ping", 24, second, {}, 0);
    CHECK(second.stage_changes.empty() && second.actions.empty());
    oblivion::QuestTick back;
    world.set_stage("Ping", 23, back, {}, 0);
    CHECK(back.stage_changes.empty() && back.actions.empty());
}

void test_stage_chain_work_budget() {
    // Every stage n sets stages 2n and 2n+1: eight levels of branching would enter 511 stages. One tick enters at
    // most kMaxStageEntriesPerTick of them, and says so.
    std::vector<std::pair<unsigned, std::string>> results;
    for (unsigned n = 1; n < 256; ++n)
        results.push_back({n, "setstage W " + std::to_string(2 * n) + "\nsetstage W " + std::to_string(2 * n + 1) + "\n"});
    oblivion::QuestWorld world(review_commands());
    const auto quest = review_quest(0x1200, "W", results);
    const auto script = review_script("WScript", "scn W\n");
    world.add(quest, script);
    const auto run = world.start("W", 1);
    CHECK(run.stage_changes.size() == oblivion::kMaxStageEntriesPerTick);
    CHECK(has_error(run, "stages entered in one tick"));
    // The budget is per tick: the next one starts afresh.
    CHECK(world.start("W", 600).stage_changes.size() == 1);
}

void test_global_condition_in_world() {
    // A package condition compared against a GLOB reads the world's global source (CTDA "use global").
    oblivion::QuestWorld world(review_commands());
    const auto quest = review_quest(0x1300, "G", {{3, ""}});
    const auto script = review_script("GScript", "scn G\n");
    auto& driver = world.add(quest, script);
    double global = 3.0;
    world.set_global_value([&](std::uint32_t form_id) -> std::optional<double> {
        if (form_id == 0x77) return global;
        return std::nullopt;
    });
    world.start("G", 3);
    oblivion::AiPackageRecord package;
    oblivion::QuestCondition condition;
    condition.function_index = 58;  // GetStage
    condition.parameter1 = 0x1300;
    condition.comparison_is_global = true;
    condition.comparison_global_form_id = 0x77;
    package.conditions.push_back(condition);
    const std::vector<const oblivion::AiPackageRecord*> packages{&package};
    CHECK(driver.select_package(packages) == &package);
    global = 4.0;
    CHECK(driver.select_package(packages) == nullptr);
    package.conditions[0].comparison_global_form_id = 0x78;  // unknown global: false
    global = 3.0;
    CHECK(driver.select_package(packages) == nullptr);
}

void test_modulo_of_the_smallest_integer() {
    // LLONG_MIN % -1 traps in hardware; the interpreter refuses it (and anything at the edge) with 0.
    const auto ast = oblivion::parse_script(
        "scn Min\nfloat r\nfloat s\nfloat t\nbegin GameMode\n"
        "  set r to 0 - 9223372036854775807 - 1\n"
        "  set s to r % (0 - 1)\n"
        "  set t to r % 7\n"
        "end\n");
    oblivion::ScriptInterpreter interpreter(ast);
    RecordingHost host;
    interpreter.run("GameMode", host);
    CHECK(interpreter.variables().at("s").number == 0.0);
    CHECK(interpreter.variables().at("t").number == 0.0);
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
        test_idle_manager(directory);
        test_loose_assets(directory);
        test_loose_file_index_edge_cases(directory);
        test_script_lexer();
        test_script_parser();
        test_command_table(directory);
        test_script_interpreter();
        test_event_blocks_by_target();
        test_script_fragment();
        test_quest_conditions();
        test_package_selection();
        test_actor_package_event();
        test_quest_stage_actions(directory);
        test_quest_driver();
        test_quest_world();
        test_world_answers();
        test_cross_quest_variables();
        test_stage_writes_survive_game_mode();
        test_short_circuit();
        test_same_stage_is_ignored();
        test_dotted_condition_parses();
        test_subtraction_after_variable_parses();
        test_subtraction_without_command_table();
        test_operator_chain_depth_is_bounded();
        test_idle_folder_cycle_ends();
        test_deep_if_nesting_keeps_structure();
        test_actor_variables_stay_out_of_quest();
        test_say_to_cycles_stop();
        test_stage_oscillation_is_deterministic();
        test_bare_quest_variables_in_results();
        test_stale_foreign_variable();
        test_modulo_and_stage_numbers_are_safe();
        test_integer_semantics_and_unresolved_names();
        test_parser_limits();
        test_world_changes_during_tick();
        test_global_comparison();
        test_set_stage_order_is_the_same_everywhere();
        test_stage_chain_work_budget();
        test_lower_entered_stage_is_not_rerun();
        test_global_condition_in_world();
        test_modulo_of_the_smallest_integer();
        test_nif_mesh_decoder();
        std::filesystem::remove_all(directory);
        return 0;
    } catch (const std::exception& error) {
        std::filesystem::remove_all(directory);
        std::cerr << "format_fixture_tests: " << error.what() << '\n';
        return 1;
    }
}
