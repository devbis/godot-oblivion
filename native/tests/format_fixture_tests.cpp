#include "oblivion/bsa_archive.hpp"
#include "oblivion/esm4_database.hpp"
#include "oblivion/game_data.hpp"
#include "oblivion/nif_mesh.hpp"

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
        test_nif_mesh_decoder();
        std::filesystem::remove_all(directory);
        return 0;
    } catch (const std::exception& error) {
        std::filesystem::remove_all(directory);
        std::cerr << "format_fixture_tests: " << error.what() << '\n';
        return 1;
    }
}
