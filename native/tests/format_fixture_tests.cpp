#include "oblivion/bsa_archive.hpp"
#include "oblivion/esm4_database.hpp"
#include "oblivion/nif_mesh.hpp"

#include <NifFile.hpp>

#include <array>
#include <cassert>
#include <chrono>
#include <cstdint>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <string>
#include <sstream>
#include <vector>

#include <zlib.h>

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
Bytes cell_record(std::uint32_t form_id, std::string_view editor_id, std::string_view name) {
    Bytes data;
    auto editor = string_subrecord("EDID", editor_id);
    data.insert(data.end(), editor.begin(), editor.end());
    auto display = string_subrecord("FULL", name);
    data.insert(data.end(), display.begin(), display.end());
    Bytes flags;
    u16(flags, 1); // interior
    subrecord(data, "DATA", flags);
    return record("CELL", form_id, data);
}
Bytes reference_record(std::uint32_t form_id, std::uint32_t base_id,
                       std::uint32_t teleport_ref_id) {
    Bytes data;
    auto name = id_subrecord("NAME", base_id);
    data.insert(data.end(), name.begin(), name.end());
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
    std::ofstream output(path, std::ios::binary);
    output.write(reinterpret_cast<const char*>(bytes.data()), static_cast<std::streamsize>(bytes.size()));
    assert(output.good());
}

void test_bsa(const std::filesystem::path& directory) {
    constexpr std::string_view payload = "fixture nif bytes";
    uLongf compressed_size = compressBound(payload.size());
    Bytes compressed(static_cast<std::size_t>(compressed_size));
    const int compression_status = compress2(compressed.data(), &compressed_size,
        reinterpret_cast<const Bytef*>(payload.data()), payload.size(), Z_BEST_COMPRESSION);
    assert(compression_status == Z_OK);
    compressed.resize(static_cast<std::size_t>(compressed_size));
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
    u32(archive, static_cast<std::uint32_t>(payload.size()));
    archive.insert(archive.end(), compressed.begin(), compressed.end());
    assert(archive.size() == data_offset + stored_size);

    const auto path = directory / "fixture.bsa";
    write_bytes(path, archive);
    oblivion::BsaArchive bsa;
    bsa.open(path);
    assert(bsa.file_count() == 1);
    assert(bsa.contains("Meshes/Test.NIF"));
    const auto extracted = bsa.read("meshes\\test.nif");
    assert(std::string(extracted.begin(), extracted.end()) == payload);
}

void test_esm4(const std::filesystem::path& directory) {
    Bytes top_header;
    raw(top_header, "TES4");
    u32(top_header, 0);
    u32(top_header, 0);
    u32(top_header, 0);
    u32(top_header, 0);

    Bytes stat_data;
    auto edid = string_subrecord("EDID", "TestDoor");
    stat_data.insert(stat_data.end(), edid.begin(), edid.end());
    auto model = string_subrecord("MODL", "Doors\\TestDoor.NIF");
    stat_data.insert(stat_data.end(), model.begin(), model.end());
    Bytes records;
    auto stat = record("DOOR", 0x100, stat_data);
    records.insert(records.end(), stat.begin(), stat.end());

    Bytes first_children;
    auto cell_a = cell_record(0x10, "StartCell", "Fixture Start");
    first_children.insert(first_children.end(), cell_a.begin(), cell_a.end());
    Bytes first_cell_refs;
    auto ref_a = reference_record(0x101, 0x100, 0x202);
    first_cell_refs.insert(first_cell_refs.end(), ref_a.begin(), ref_a.end());
    auto first_child_group = group(0x10, 6, first_cell_refs);
    first_children.insert(first_children.end(), first_child_group.begin(), first_child_group.end());
    auto first_cell_group = group(0, 3, first_children);
    records.insert(records.end(), first_cell_group.begin(), first_cell_group.end());

    Bytes second_children;
    auto cell_b = cell_record(0x20, "NextCell", "Fixture Next");
    second_children.insert(second_children.end(), cell_b.begin(), cell_b.end());
    Bytes second_cell_refs;
    auto ref_b = reference_record(0x202, 0x100, 0x101);
    second_cell_refs.insert(second_cell_refs.end(), ref_b.begin(), ref_b.end());
    auto second_child_group = group(0x20, 6, second_cell_refs);
    second_children.insert(second_children.end(), second_child_group.begin(), second_child_group.end());
    auto second_cell_group = group(0, 3, second_children);
    records.insert(records.end(), second_cell_group.begin(), second_cell_group.end());

    auto record_group = group(0x524f4f44, 0, records); // top group
    top_header.insert(top_header.end(), record_group.begin(), record_group.end());
    const auto path = directory / "fixture.esm";
    write_bytes(path, top_header);

    oblivion::Esm4Database database;
    database.open(path);
    const auto* start = database.find_cell("startcell");
    assert(start != nullptr);
    assert(start->display_name == "Fixture Start");
    assert(start->interior);
    assert(start->references.size() == 1);
    const auto& door = start->references.front();
    assert(door.form_id == 0x101);
    assert(door.base_form_id == 0x100);
    assert(door.model_path == "Doors\\TestDoor.NIF");
    assert(door.teleport_ref_id == 0x202);
    assert(door.teleport_cell_id == 0x20);
    assert(door.position[0] == 1.0f && door.position[2] == 3.0f);
}

void test_nif_mesh_decoder() {
    nifly::NifFile file;
    file.Create(nifly::NiVersion::getOB());
    const std::vector<nifly::Vector3> vertices{
        {0.0f, 0.0f, 0.0f}, {1.0f, 0.0f, 0.0f}, {0.0f, 1.0f, 0.0f}
    };
    const std::vector<nifly::Triangle> triangles{{0, 1, 2}};
    const auto* shape = file.CreateShapeFromData("FixtureShape", &vertices, &triangles, nullptr);
    assert(shape != nullptr);
    std::stringstream encoded(std::ios::in | std::ios::out | std::ios::binary);
    assert(file.Save(encoded) == 0);
    const auto payload = encoded.str();
    const Bytes bytes(payload.begin(), payload.end());
    const auto meshes = oblivion::decode_nif_meshes(bytes);
    assert(meshes.size() == 1);
    assert(meshes.front().name == "FixtureShape");
    assert(meshes.front().vertices.size() == 3);
    const std::vector<std::uint32_t> expected_indices{0, 1, 2};
    const std::array<float, 3> expected_vertex_x{1.0f, 0.0f, 0.0f};
    const std::array<float, 3> expected_vertex_y{0.0f, 0.0f, -1.0f};
    assert(meshes.front().indices == expected_indices);
    assert(meshes.front().vertices[1] == expected_vertex_x);
    assert(meshes.front().vertices[2] == expected_vertex_y);
}

} // namespace

int main() {
    const auto directory = temp_dir();
    try {
        test_bsa(directory);
        test_esm4(directory);
        test_nif_mesh_decoder();
        std::filesystem::remove_all(directory);
        return 0;
    } catch (...) {
        std::filesystem::remove_all(directory);
        throw;
    }
}
