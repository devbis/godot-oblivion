#include "oblivion/command_table.hpp"
#include "oblivion/esm4_database.hpp"
#include "oblivion/nif_mesh.hpp"

#include <NifFile.hpp>

#include <array>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <optional>
#include <sstream>
#include <stdexcept>
#include <string>
#include <vector>

#define CHECK(condition)                                                                    \
    do {                                                                                    \
        if (!(condition))                                                                   \
            throw std::runtime_error(std::string(__FILE__) + ":" + std::to_string(__LINE__) \
                                     + ": check failed: " #condition);                      \
    } while (false)

namespace {

using Bytes = std::vector<std::uint8_t>;

void u8(Bytes& out, std::uint8_t v) { out.push_back(v); }
void u16(Bytes& out, std::uint16_t v) { u8(out, static_cast<std::uint8_t>(v)); u8(out, static_cast<std::uint8_t>(v >> 8)); }
void u32(Bytes& out, std::uint32_t v) { for (int s = 0; s < 32; s += 8) u8(out, static_cast<std::uint8_t>(v >> s)); }
void raw(Bytes& out, std::string_view v) { out.insert(out.end(), v.begin(), v.end()); }
void append(Bytes& t, const Bytes& s) { t.insert(t.end(), s.begin(), s.end()); }
void subrecord(Bytes& out, std::string_view tag, const Bytes& value) {
    raw(out, tag);
    u16(out, static_cast<std::uint16_t>(value.size()));
    append(out, value);
}
Bytes zsub(std::string_view tag, std::string_view value) {
    Bytes data;
    raw(data, value);
    u8(data, 0);
    Bytes r;
    subrecord(r, tag, data);
    return r;
}
Bytes record(std::string_view tag, std::uint32_t form_id, const Bytes& data) {
    Bytes r;
    raw(r, tag);
    u32(r, static_cast<std::uint32_t>(data.size()));
    u32(r, 0);
    u32(r, form_id);
    u32(r, 0);
    append(r, data);
    return r;
}
Bytes group(std::uint32_t label, std::uint32_t type, const Bytes& children) {
    Bytes r;
    raw(r, "GRUP");
    u32(r, static_cast<std::uint32_t>(20 + children.size()));
    u32(r, label);
    u32(r, type);
    u16(r, 0);
    u16(r, 0);
    append(r, children);
    return r;
}
void write_bytes(const std::filesystem::path& path, const Bytes& bytes) {
    std::filesystem::create_directories(path.parent_path());
    std::ofstream output(path, std::ios::binary);
    output.write(reinterpret_cast<const char*>(bytes.data()), static_cast<std::streamsize>(bytes.size()));
    CHECK(output.good());
}

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


void test_command_table_cache(const std::filesystem::path& directory) {
    const auto executable = command_table_executable();
    const auto exe_path = directory / "hard.exe";
    write_bytes(exe_path, executable);

    // A cache cut at a line boundary is incomplete and must be rebuilt, not trusted.
    const auto cache_dir = directory / "hard-cache";
    const auto full = oblivion::load_command_table(exe_path, cache_dir);
    const auto cache_file = oblivion::command_table_cache_path(cache_dir, executable);
    std::string text;
    {
        std::ifstream in(cache_file, std::ios::binary);
        std::ostringstream s;
        s << in.rdbuf();
        text = s.str();
    }
    const auto last_line = text.rfind('\n', text.size() - 2);
    {
        std::ofstream out(cache_file, std::ios::binary | std::ios::trunc);
        out << text.substr(0, last_line + 1);
        // Drop the trailer and one more record's worth by cutting at an earlier line break.
    }
    const auto rebuilt = oblivion::load_command_table(exe_path, cache_dir);
    CHECK(rebuilt.size() == full.size());
    {
        std::ifstream in(cache_file, std::ios::binary);
        std::ostringstream s;
        s << in.rdbuf();
        CHECK(s.str() == text);  // rewritten whole
    }

    // An uncreatable cache directory (a file is in the way) does not lose the parsed table.
    const auto blocked = directory / "blocked";
    write_bytes(blocked, Bytes{1});
    const auto loaded = oblivion::load_command_table(exe_path, blocked / "sub");
    CHECK(loaded.size() == full.size());
}

Bytes info_record(std::uint32_t id) {
    Bytes data;
    const auto trdt = [&](std::uint8_t number) {
        Bytes t(16, 0);
        t[12] = number;
        subrecord(data, "TRDT", t);
    };
    trdt(1);
    append(data, zsub("NAM1", "first line"));
    trdt(2);
    append(data, zsub("NAM1", "second line"));
    Bytes ctda(24, 0);
    ctda[0] = 0x04;  // use global
    ctda[8] = 58;
    ctda[4] = 0x34; ctda[5] = 0x12;  // global form id 0x1234
    subrecord(data, "CTDA", ctda);
    return record("INFO", id, data);
}

void test_esm_details(const std::filesystem::path& directory) {
    Bytes file;
    raw(file, "TES4");
    u32(file, 0); u32(file, 0); u32(file, 0); u32(file, 0);
    Bytes records;
    Bytes dial;
    append(dial, zsub("EDID", "HardTopic"));
    append(records, record("DIAL", 0x700, dial));
    append(records, group(0x700, 7, info_record(0x701)));

    Bytes glob;
    append(glob, zsub("EDID", "HardGlobal"));
    subrecord(glob, "FNAM", Bytes{'f'});
    Bytes fltv;
    u32(fltv, 0x40200000);  // 2.5f
    subrecord(glob, "FLTV", fltv);
    append(records, record("GLOB", 0x1234, glob));

    Bytes script;
    append(script, zsub("EDID", "HardScript"));
    Bytes slsd(24, 0);
    slsd[0] = 1;
    slsd[16] = 3;
    slsd[17] = 0xFF; slsd[18] = 0xFF; slsd[19] = 0xFF;  // padding must not change the type
    subrecord(script, "SLSD", slsd);
    append(script, zsub("SCVR", "v"));
    append(records, record("SCPT", 0x710, script));

    Bytes cell;  // no EDID, like an exterior cell
    Bytes flags;
    u16(flags, 0);
    subrecord(cell, "DATA", flags);
    append(records, group(0, 3, record("CELL", 0x720, cell)));
    append(file, group(0x524f4f44, 0, records));

    const auto path = directory / "hardening.esm";
    write_bytes(path, file);
    oblivion::Esm4Database db;
    db.open(path);
    const auto topic = db.topics().find(0x700);
    CHECK(topic != db.topics().end() && topic->second.responses.size() == 1);
    const auto& response = topic->second.responses[0];
    CHECK(response.lines.size() == 2);
    CHECK(response.lines[0].number == 1 && response.lines[0].text == "first line");
    CHECK(response.lines[1].number == 2 && response.lines[1].text == "second line");
    CHECK(response.text == "first line");
    CHECK(response.conditions.size() == 1);
    CHECK(response.conditions[0].comparison_is_global && response.conditions[0].comparison_global_form_id == 0x1234);
    const auto* script_record = db.find_script("hardscript");
    CHECK(script_record && script_record->variables.size() == 1 && script_record->variables[0].type == 3);
    CHECK(db.find_cell(0x720) != nullptr);
    CHECK(db.find_cell("") == nullptr);
    // The global the CTDA above points at has an initial value, and an unknown one has none.
    CHECK(db.find_global_value(0x1234) == std::optional<float>(2.5f));
    CHECK(!db.find_global_value(0x1235).has_value());
    db.open(path, true);  // the visuals-only profile keeps globals too: quest conditions need them
    CHECK(db.find_global_value(0x1234) == std::optional<float>(2.5f));
    db.open(path);  // reopening resets state
    CHECK(db.unplaced_references().empty());
}

Bytes nif_with_euler_and_bad_triangle(bool all_axes = false) {
    nifly::NifFile file;
    file.Create(nifly::NiVersion::getOB());
    const std::vector<nifly::Vector3> vertices{{0, 0, 0}, {1, 0, 0}, {0, 1, 0}};
    const std::vector<nifly::Triangle> triangles{{0, 1, 2}, {0, 1, 9}};
    CHECK(file.CreateShapeFromData("S", &vertices, &triangles, nullptr) != nullptr);

    auto& header = file.GetHeader();
    auto data = std::make_unique<nifly::NiTransformData>();
    data->rotationType = nifly::XYZ_ROTATION_KEY;
    for (const auto& [time, angle] : {std::pair{0.0f, 0.0f}, std::pair{1.0f, 1.5707964f}}) {
        nifly::NiAnimationKey<float> key;
        key.time = time;
        key.value = angle;
        key.type = nifly::LINEAR_KEY;
        data->zRotations.SetInterpolationType(nifly::LINEAR_KEY);
        data->zRotations.AddKey(key);
        if (all_axes) {
            data->xRotations.SetInterpolationType(nifly::LINEAR_KEY);
            data->xRotations.AddKey(key);
            data->yRotations.SetInterpolationType(nifly::LINEAR_KEY);
            data->yRotations.AddKey(key);
        }
    }
    const auto data_id = header.AddBlock(std::move(data));
    auto interpolator = std::make_unique<nifly::NiTransformInterpolator>();
    interpolator->dataRef.index = data_id;
    const auto interpolator_id = header.AddBlock(std::move(interpolator));
    auto palette = std::make_unique<nifly::NiStringPalette>();
    palette->palette.get() = std::string("Door\0", 5);
    const auto palette_id = header.AddBlock(std::move(palette));
    auto sequence = std::make_unique<nifly::NiControllerSequence>();
    sequence->name.get() = "Open";
    sequence->startTime = 0.0f;
    sequence->stopTime = 1.0f;
    nifly::ControllerLink link;
    link.interpolatorRef.index = interpolator_id;
    link.stringPaletteRef.index = palette_id;
    link.nodeNameOffset = 0;
    sequence->controlledBlocks.push_back(link);
    const auto sequence_id = header.AddBlock(std::move(sequence));
    auto manager = std::make_unique<nifly::NiControllerManager>();
    manager->controllerSequenceRefs.AddBlockRef(sequence_id);
    const auto manager_id = header.AddBlock(std::move(manager));
    file.GetRootNode()->controllerRef.index = manager_id;

    std::stringstream encoded(std::ios::in | std::ios::out | std::ios::binary);
    CHECK(file.Save(encoded) == 0);
    const auto payload = encoded.str();
    return Bytes(payload.begin(), payload.end());
}

void test_nif_hardening() {
    const auto bytes = nif_with_euler_and_bad_triangle();
    const auto meshes = oblivion::decode_nif_meshes(bytes);
    CHECK(meshes.size() == 1);
    CHECK(meshes[0].indices == std::vector<std::uint32_t>({0, 1, 2}));  // out-of-range triangle dropped

    const auto asset = oblivion::decode_nif_asset(bytes);
    CHECK(!asset.nodes.empty());
    CHECK(asset.animations.size() == 1);
    const auto& track = asset.animations[0].tracks.at(0);
    CHECK(track.rotations.size() == 2);
    // Rotation about NIF Z by pi/2 is Godot Y with the sign flipped: (x,y,z,w) = (0,0,-s,c)... with
    // the basis change (x,z,-y): the Z component lands on Y.
    const float s = std::sqrt(0.5f);
    CHECK(std::abs(track.rotations[1][2] - s) < 1e-4f && std::abs(track.rotations[1][5 - 1] - s) < 1e-4f);
    CHECK(std::abs(track.rotations[0][4] - 1.0f) < 1e-5f);
}

// X, Y and Z Euler keys of pi/2 each at t=1. The documented order is Rz * Ry * Rx (X applied first): rotating
// the NIF point (1,0,0) gives X -> (1,0,0), Y -> (0,0,-1), Z -> (0,0,-1), i.e. a single 90 degree turn about
// NIF Y, as the quaternion (x,y,z,w) = (0, s, 0, s) with s = sqrt(1/2). The Godot basis (x, z, -y) turns that into
// (0, 0, -s, s). The opposite order (Rx * Ry * Rz) would be a turn about X and give (s, 0, 0, s) instead.
void test_nif_euler_multi_axis_order() {
    const auto asset = oblivion::decode_nif_asset(nif_with_euler_and_bad_triangle(true));
    CHECK(asset.animations.size() == 1);
    const auto& track = asset.animations[0].tracks.at(0);
    CHECK(track.rotations.size() == 2);
    const float s = std::sqrt(0.5f);
    const auto& q = track.rotations[1];  // {time, x, y, z, w}
    CHECK(std::abs(q[1]) < 1e-4f && std::abs(q[2]) < 1e-4f);
    CHECK(std::abs(q[3] + s) < 1e-4f && std::abs(q[4] - s) < 1e-4f);
}

} // namespace

int main() {
    const auto directory = std::filesystem::temp_directory_path() /
        ("openob-hardening-" + std::to_string(std::chrono::steady_clock::now().time_since_epoch().count()));
    std::filesystem::create_directories(directory);
    try {
        test_command_table_cache(directory);
        test_esm_details(directory);
        test_nif_hardening();
        test_nif_euler_multi_axis_order();
        std::filesystem::remove_all(directory);
        return 0;
    } catch (const std::exception& error) {
        std::filesystem::remove_all(directory);
        std::cerr << error.what() << '\n';
        return 1;
    }
}
