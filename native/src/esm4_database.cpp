/*
 * TES4 ESM record and group layout.
 *
 * OpenMW format reference: components/esm4/reader.hpp, reader.cpp,
 * loadcell.cpp and loadrefr.cpp, Copyright (C) 2015-2021 cc9cii. Those files
 * carry the permissive notice printed below; this implementation is a new,
 * bounded parser using the documented record layout.
 * NPC, outfit, and equipment subrecord layouts were also cross-checked
 * against xEdit's wbDefinitionsTES4.pas; no xEdit implementation is included.
 *
 * Copyright (C) 2015-2021 cc9cii (format reference notice)
 *
 * This software is provided 'as-is', without any express or implied
 * warranty. In no event will the authors be held liable for any damages
 * arising from the use of this software.
 *
 * Permission is granted to anyone to use this software for any purpose,
 * including commercial applications, and to alter it and redistribute it
 * freely, subject to these restrictions:
 * 1. The origin must not be misrepresented; altered versions must be marked.
 * 2. This notice may not be removed or altered from this source distribution.
 */
#include "oblivion/esm4_database.hpp"

#include <algorithm>
#include <cctype>
#include <cstring>
#include <fstream>
#include <limits>
#include <stdexcept>

#include <zlib.h>

namespace oblivion {
namespace {

constexpr std::uint32_t kCompressedRecord = 0x00040000;
constexpr std::uint32_t kGroup = 0x50555247; // GRUP, little endian
constexpr std::uint32_t kCellChildGroup = 6;
constexpr std::uint32_t kCellPersistentGroup = 8;
constexpr std::uint32_t kCellTemporaryGroup = 9;
constexpr std::uint32_t kCellVisibleDistanceGroup = 10;
constexpr std::size_t kTes4RecordHeaderSize = 20;
// Oblivion's TES4 records and GRUP headers are 20 bytes; later TES5 headers
// add the two-byte form version and two-byte unknown fields.
constexpr std::size_t kRecordHeaderSize = 20;
constexpr std::size_t kGroupHeaderSize = 20;

std::uint16_t u16(const std::uint8_t* data) {
    return static_cast<std::uint16_t>(data[0])
        | (static_cast<std::uint16_t>(data[1]) << 8);
}

std::uint32_t u32(const std::uint8_t* data) {
    return static_cast<std::uint32_t>(data[0])
        | (static_cast<std::uint32_t>(data[1]) << 8)
        | (static_cast<std::uint32_t>(data[2]) << 16)
        | (static_cast<std::uint32_t>(data[3]) << 24);
}

float f32(const std::uint8_t* data) {
    const auto bits = u32(data);
    float result = 0.0f;
    std::memcpy(&result, &bits, sizeof(result));
    return result;
}

std::vector<std::uint8_t> read_file(const std::filesystem::path& path) {
    std::ifstream input(path, std::ios::binary | std::ios::ate);
    if (!input)
        throw std::runtime_error("cannot open " + path.string());
    const auto end = input.tellg();
    if (end < 0 || static_cast<std::uint64_t>(end) > std::numeric_limits<std::size_t>::max())
        throw std::runtime_error("cannot size " + path.string());
    std::vector<std::uint8_t> result(static_cast<std::size_t>(end));
    input.seekg(0);
    if (!result.empty())
        input.read(reinterpret_cast<char*>(result.data()), static_cast<std::streamsize>(result.size()));
    if (!input)
        throw std::runtime_error("cannot read " + path.string());
    return result;
}

void check_range(std::size_t total, std::size_t at, std::size_t count, std::string_view label) {
    if (at > total || count > total - at)
        throw std::runtime_error("ESM4 " + std::string(label) + " is out of bounds");
}

std::string read_zstring(const std::uint8_t* data, std::size_t size) {
    const auto* end = static_cast<const std::uint8_t*>(std::memchr(data, 0, size));
    if (!end)
        return std::string(reinterpret_cast<const char*>(data), size);
    return std::string(reinterpret_cast<const char*>(data), static_cast<std::size_t>(end - data));
}

std::vector<std::uint8_t> decompress_record(const std::uint8_t* data, std::size_t size,
                                           std::string_view type, std::uint32_t form_id) {
    if (size < 4)
        throw std::runtime_error("compressed ESM4 " + std::string(type) + " record "
            + std::to_string(form_id) + " has an invalid data size " + std::to_string(size));
    const std::uint32_t output_size = u32(data);
    std::vector<std::uint8_t> result(output_size);
    uLongf actual = static_cast<uLongf>(result.size());
    const int status = uncompress(result.data(), &actual, data + 4, static_cast<uLong>(size - 4));
    if (status != Z_OK || actual != result.size())
        throw std::runtime_error("cannot decompress ESM4 record");
    return result;
}

bool is_cell_reference_group(std::uint32_t type) {
    return type == kCellChildGroup || type == kCellPersistentGroup
        || type == kCellTemporaryGroup || type == kCellVisibleDistanceGroup;
}

std::string lower_ascii(std::string value) {
    std::transform(value.begin(), value.end(), value.begin(), [](unsigned char character) {
        return static_cast<char>(std::tolower(character));
    });
    return value;
}

} // namespace

void Esm4Database::open(const std::filesystem::path& path) {
    cells_.clear();
    cell_by_id_.clear();
    base_model_by_id_.clear();
    base_editor_id_by_id_.clear();
    form_id_by_editor_id_.clear();
    npc_by_id_.clear();
    race_face_gen_by_id_.clear();
    outfit_by_id_.clear();
    ai_package_by_id_.clear();
    item_model_by_id_.clear();
    female_item_model_by_id_.clear();
    world_item_model_by_id_.clear();
    female_world_item_model_by_id_.clear();
    item_biped_slots_by_id_.clear();
    record_type_by_id_.clear();
    cell_by_reference_id_.clear();
    float_game_settings_.clear();
    record_count_ = 0;
    const auto bytes = read_file(path);
    parse_file(bytes);
    for (const auto& [form_id, editor_id] : base_editor_id_by_id_)
        form_id_by_editor_id_.try_emplace(lower_ascii(editor_id), form_id);
    for (auto& cell : cells_) {
        for (auto& reference : cell.references) {
            if (auto model = base_model_by_id_.find(reference.base_form_id); model != base_model_by_id_.end())
                reference.model_path = model->second;
            else if (auto world_model = world_item_model_by_id_.find(reference.base_form_id);
                     world_model != world_item_model_by_id_.end())
                reference.model_path = world_model->second;
            else if (auto item_model = item_model_by_id_.find(reference.base_form_id);
                     item_model != item_model_by_id_.end())
                reference.model_path = item_model->second;
            if (auto editor = base_editor_id_by_id_.find(reference.base_form_id); editor != base_editor_id_by_id_.end())
                reference.base_editor_id = editor->second;
            reference.editor_id = reference.reference_name.empty()
                ? reference.base_editor_id : reference.reference_name;
            cell_by_reference_id_[reference.form_id] = cell.form_id;
        }
    }
    for (auto& cell : cells_) {
        for (auto& reference : cell.references) {
            if (auto target = cell_by_reference_id_.find(reference.teleport_ref_id);
                target != cell_by_reference_id_.end())
                reference.teleport_cell_id = target->second;
        }
    }
    path_ = path;
}

const CellRecord* Esm4Database::find_cell(std::string_view editor_id) const {
    auto equal_fold = [](std::string_view a, std::string_view b) {
        if (a.size() != b.size()) return false;
        for (std::size_t i = 0; i < a.size(); ++i) {
            auto ca = static_cast<unsigned char>(a[i]);
            auto cb = static_cast<unsigned char>(b[i]);
            if (std::tolower(ca) != std::tolower(cb)) return false;
        }
        return true;
    };
    const auto it = std::find_if(cells_.begin(), cells_.end(), [&](const CellRecord& cell) {
        return equal_fold(cell.editor_id, editor_id);
    });
    return it == cells_.end() ? nullptr : &*it;
}

const CellRecord* Esm4Database::find_cell(std::uint32_t form_id) const {
    const auto it = cell_by_id_.find(form_id);
    return it == cell_by_id_.end() ? nullptr : &cells_[it->second];
}

const NpcBaseRecord* Esm4Database::find_npc_base(std::uint32_t form_id) const {
    const auto it = npc_by_id_.find(form_id);
    return it == npc_by_id_.end() ? nullptr : &it->second;
}

const RaceFaceGenRecord* Esm4Database::find_race_face_gen(std::uint32_t form_id) const {
    const auto it = race_face_gen_by_id_.find(form_id);
    return it == race_face_gen_by_id_.end() ? nullptr : &it->second;
}

const OutfitRecord* Esm4Database::find_outfit(std::uint32_t form_id) const {
    const auto it = outfit_by_id_.find(form_id);
    return it == outfit_by_id_.end() ? nullptr : &it->second;
}

const AiPackageRecord* Esm4Database::find_ai_package(std::uint32_t form_id) const {
    const auto it = ai_package_by_id_.find(form_id);
    return it == ai_package_by_id_.end() ? nullptr : &it->second;
}

const std::string* Esm4Database::find_item_model_path(std::uint32_t form_id, bool female) const {
    if (female) {
        const auto female = female_item_model_by_id_.find(form_id);
        if (female != female_item_model_by_id_.end()) return &female->second;
    }
    const auto male = item_model_by_id_.find(form_id);
    return male == item_model_by_id_.end() ? nullptr : &male->second;
}

const std::string* Esm4Database::find_world_item_model_path(std::uint32_t form_id, bool female) const {
    if (female) {
        const auto female_world = female_world_item_model_by_id_.find(form_id);
        if (female_world != female_world_item_model_by_id_.end()) return &female_world->second;
    }
    const auto male_world = world_item_model_by_id_.find(form_id);
    return male_world == world_item_model_by_id_.end() ? nullptr : &male_world->second;
}

std::uint16_t Esm4Database::find_item_biped_slots(std::uint32_t form_id) const {
    const auto it = item_biped_slots_by_id_.find(form_id);
    return it == item_biped_slots_by_id_.end() ? 0 : it->second;
}

std::uint32_t Esm4Database::find_form_id_by_editor_id(std::string_view editor_id) const {
    const auto it = form_id_by_editor_id_.find(lower_ascii(std::string(editor_id)));
    return it == form_id_by_editor_id_.end() ? 0 : it->second;
}

std::vector<std::uint32_t> Esm4Database::find_form_ids_by_editor_id_prefix(std::string_view prefix) const {
    const auto lower_prefix = lower_ascii(std::string(prefix));
    std::vector<std::uint32_t> result;
    auto it = form_id_by_editor_id_.lower_bound(lower_prefix);
    while (it != form_id_by_editor_id_.end()
           && it->first.compare(0, lower_prefix.size(), lower_prefix) == 0) {
        result.push_back(it->second);
        ++it;
    }
    return result;
}

const std::string* Esm4Database::find_editor_id(std::uint32_t form_id) const {
    const auto it = base_editor_id_by_id_.find(form_id);
    return it == base_editor_id_by_id_.end() ? nullptr : &it->second;
}

const std::string* Esm4Database::find_record_type(std::uint32_t form_id) const {
    const auto it = record_type_by_id_.find(form_id);
    return it == record_type_by_id_.end() ? nullptr : &it->second;
}

void Esm4Database::parse_file(const std::vector<std::uint8_t>& bytes) {
    if (bytes.size() < kTes4RecordHeaderSize)
        throw std::runtime_error("ESM file is too small");
    if (std::memcmp(bytes.data(), "TES4", 4) != 0)
        throw std::runtime_error("ESM file does not begin with a TES4 header");
    const auto header_data_size = u32(bytes.data() + 4);
    check_range(bytes.size(), kTes4RecordHeaderSize, header_data_size, "TES4 header record");
    const std::size_t records_begin = kTes4RecordHeaderSize + header_data_size;

    auto walk = [&](auto&& self, std::size_t begin, std::size_t end,
                    std::uint32_t active_cell_id) -> void {
        std::size_t cursor = begin;
        while (cursor < end) {
            check_range(end, cursor, 4, "record type");
            const std::uint32_t type_id = u32(bytes.data() + cursor);
            if (type_id == kGroup) {
                check_range(end, cursor, kGroupHeaderSize, "GRUP header");
                const auto group_size = u32(bytes.data() + cursor + 4);
                const auto group_label = u32(bytes.data() + cursor + 8);
                const auto group_type = u32(bytes.data() + cursor + 12);
                if (group_size < kGroupHeaderSize || group_size > end - cursor)
                    throw std::runtime_error("ESM4 GRUP has an invalid size");
                const auto child_cell_id = is_cell_reference_group(group_type) ? group_label : active_cell_id;
                self(self, cursor + kGroupHeaderSize, cursor + group_size, child_cell_id);
                cursor += group_size;
                continue;
            }

            check_range(end, cursor, kRecordHeaderSize, "record header");
            const auto data_size = u32(bytes.data() + cursor + 4);
            const auto flags = u32(bytes.data() + cursor + 8);
            const auto form_id = u32(bytes.data() + cursor + 12);
            check_range(end, cursor + kRecordHeaderSize, data_size, "record data");
            const auto* record_data = bytes.data() + cursor + kRecordHeaderSize;
            const auto* record_type = reinterpret_cast<const char*>(bytes.data() + cursor);
            std::vector<std::uint8_t> inflated;
            if (flags & kCompressedRecord) {
                inflated = decompress_record(record_data, data_size, std::string_view(record_type, 4), form_id);
                record_data = inflated.data();
                parse_record(std::string_view(record_type, 4), form_id, flags, active_cell_id,
                             record_data, inflated.size());
            } else {
                parse_record(std::string_view(record_type, 4), form_id, flags, active_cell_id,
                             record_data, data_size);
            }
            ++record_count_;
            cursor += kRecordHeaderSize + data_size;
        }
    };

    if (records_begin > bytes.size())
        throw std::runtime_error("ESM header record extends beyond the file");
    walk(walk, records_begin, bytes.size(), 0);
}

void Esm4Database::parse_record(std::string_view type, std::uint32_t form_id, std::uint32_t,
                                std::uint32_t active_cell_id, const std::uint8_t* data,
                                std::size_t data_size) {
    bool is_cell = type == "CELL";
    bool is_reference = type == "REFR" || type == "ACHR" || type == "ACRE";
    bool is_game_setting = type == "GMST";
    bool is_npc_base = type == "NPC_";
    bool is_race = type == "RACE";
    bool is_outfit = type == "OTFT";
    bool is_ai_package = type == "PACK";
    const bool is_item_model = type == "ARMO" || type == "CLOT" || type == "WEAP"
        || type == "HAIR" || type == "EYES" || type == "ALCH" || type == "AMMO"
        || type == "APPA" || type == "BOOK" || type == "INGR" || type == "KEYM"
        || type == "MISC" || type == "SLGM" || type == "SGST";
    CellRecord cell;
    cell.form_id = form_id;
    cell.interior = true;
    PlacedReference reference;
    reference.form_id = form_id;
    NpcBaseRecord npc;
    npc.form_id = form_id;
    RaceFaceGenRecord race_face_gen;
    race_face_gen.form_id = form_id;
    OutfitRecord outfit;
    outfit.form_id = form_id;
    AiPackageRecord ai_package;
    ai_package.form_id = form_id;
    int race_part_section = -1;
    int race_part_index = -1;
    bool race_part_female = false;
    if (is_reference)
        reference.record_type.assign(type);
    std::string base_editor_id;

    std::size_t cursor = 0;
    while (cursor < data_size) {
        check_range(data_size, cursor, 6, "subrecord header");
        const auto* subrecord_type_data = data + cursor;
        const std::string_view subrecord_type(reinterpret_cast<const char*>(subrecord_type_data), 4);
        std::uint32_t subrecord_size = u16(data + cursor + 4);
        cursor += 6;
        if (subrecord_type == "XXXX") {
            check_range(data_size, cursor, 4, "XXXX extended size");
            subrecord_size = u32(data + cursor);
            cursor += 4;
            check_range(data_size, cursor, 6, "extended subrecord header");
            subrecord_type_data = data + cursor;
            cursor += 6;
        }
        check_range(data_size, cursor, subrecord_size, "subrecord data");
        const std::string_view tag(reinterpret_cast<const char*>(subrecord_type_data), 4);
        const auto* value = data + cursor;

        if (tag == "EDID") {
            const auto text = read_zstring(value, subrecord_size);
            if (is_cell) cell.editor_id = text;
            else if (is_reference) reference.reference_name = text;
            else if (type == "STAT" || type == "DOOR" || type == "FURN" || type == "ACTI" || type == "MSTT" || type == "RACE" || is_game_setting || is_npc_base || is_item_model || is_outfit || is_ai_package)
                base_editor_id = text;
            if (is_npc_base) npc.editor_id = text;
            if (is_outfit) outfit.editor_id = text;
            if (is_ai_package) ai_package.editor_id = text;
        } else if (tag == "FULL" && is_cell) {
            cell.display_name = read_zstring(value, subrecord_size);
        } else if (tag == "FULL" && is_npc_base) {
            npc.name = read_zstring(value, subrecord_size);
        } else if (tag == "DATA" && is_cell && subrecord_size >= 2) {
            cell.interior = (u16(value) & 0x0001) != 0;
        } else if (tag == "XCLC" && is_cell && subrecord_size >= 8) {
            cell.grid_x = static_cast<std::int32_t>(u32(value));
            cell.grid_y = static_cast<std::int32_t>(u32(value + 4));
        } else if (tag == "MODL" && (type == "STAT" || type == "DOOR" || type == "FURN" || type == "ACTI" || type == "MSTT")) {
            const auto path = read_zstring(value, subrecord_size);
            if (!path.empty()) base_model_by_id_[form_id] = path;
        } else if (tag == "MODL" && is_item_model) {
            const auto path = read_zstring(value, subrecord_size);
            if (!path.empty()) item_model_by_id_[form_id] = path;
        } else if (tag == "MOD3" && (type == "ARMO" || type == "CLOT")) {
            const auto path = read_zstring(value, subrecord_size);
            if (!path.empty()) female_item_model_by_id_[form_id] = path;
        } else if (tag == "MOD2" && (type == "ARMO" || type == "CLOT")) {
            const auto path = read_zstring(value, subrecord_size);
            if (!path.empty()) world_item_model_by_id_[form_id] = path;
        } else if (tag == "MOD4" && (type == "ARMO" || type == "CLOT")) {
            const auto path = read_zstring(value, subrecord_size);
            if (!path.empty()) female_world_item_model_by_id_[form_id] = path;
        } else if (tag == "BMDT" && (type == "ARMO" || type == "CLOT") && subrecord_size >= 2) {
            item_biped_slots_by_id_[form_id] = u16(value);
        } else if (tag == "INAM" && is_outfit && subrecord_size >= 4) {
            outfit.item_form_ids.push_back(u32(value));
        } else if (tag == "NAME" && is_reference && subrecord_size >= 4) {
            reference.base_form_id = u32(value);
        } else if (tag == "ACBS" && is_npc_base && subrecord_size >= 4) {
            npc.flags = u32(value);
        } else if (tag == "RNAM" && is_npc_base && subrecord_size >= 4) {
            npc.race_form_id = u32(value);
        } else if (tag == "HNAM" && is_npc_base && subrecord_size >= 4) {
            npc.hair_form_id = u32(value);
        } else if (tag == "ENAM" && is_npc_base && subrecord_size >= 4) {
            npc.eye_form_id = u32(value);
        } else if (tag == "HCLR" && is_npc_base && subrecord_size >= npc.hair_color.size()) {
            std::copy_n(value, npc.hair_color.size(), npc.hair_color.begin());
        } else if ((tag == "FGGS" || tag == "FGGA") && is_npc_base && subrecord_size % 4 == 0) {
            auto& target = tag == "FGGS" ? npc.face_symmetric : npc.face_asymmetric;
            target.reserve(subrecord_size / 4);
            for (std::size_t offset = 0; offset < subrecord_size; offset += 4)
                target.push_back(f32(value + offset));
        } else if ((tag == "FGGS" || tag == "FGGA") && is_race && subrecord_size % 4 == 0) {
            // TES4 stores a single race shape basis even when these fields follow FNAM.
            auto& target = tag == "FGGS" ? race_face_gen.face_symmetric : race_face_gen.face_asymmetric;
            target.clear();
            target.reserve(subrecord_size / 4);
            for (std::size_t offset = 0; offset < subrecord_size; offset += 4)
                target.push_back(f32(value + offset));
        } else if (tag == "FGTS" && is_race && subrecord_size % 4 == 0) {
            auto& target = race_face_gen.face_texture_coefficients;
            target.clear();
            target.reserve(subrecord_size / 4);
            for (std::size_t offset = 0; offset < subrecord_size; offset += 4)
                target.push_back(f32(value + offset));
        } else if (tag == "NAM0" && is_race) {
            race_part_section = 0;
            race_part_index = -1;
        } else if (tag == "NAM1" && is_race) {
            race_part_section = 1;
            race_part_index = 4;
        } else if (tag == "MNAM" && is_race) {
            race_part_female = false;
        } else if (tag == "FNAM" && is_race) {
            race_part_female = true;
        } else if (tag == "INDX" && is_race && subrecord_size >= 4) {
            race_part_index = static_cast<int>(u32(value));
        } else if (tag == "MODL" && is_race && race_part_section >= 0 && race_part_index >= 0) {
            const auto path = read_zstring(value, subrecord_size);
            if (race_part_section == 0 && race_part_index < 9) {
                auto& parts = race_part_female ? race_face_gen.head_parts_female : race_face_gen.head_parts_male;
                parts[static_cast<std::size_t>(race_part_index)].model_path = path;
            } else if (race_part_section == 1 && race_part_index < 5) {
                auto& parts = race_part_female ? race_face_gen.body_parts_female : race_face_gen.body_parts_male;
                parts[static_cast<std::size_t>(race_part_index)].model_path = path;
            }
        } else if (tag == "ICON" && is_race && race_part_section >= 0 && race_part_index >= 0) {
            const auto path = read_zstring(value, subrecord_size);
            if (race_part_section == 0 && race_part_index < 9) {
                auto& parts = race_part_female ? race_face_gen.head_parts_female : race_face_gen.head_parts_male;
                parts[static_cast<std::size_t>(race_part_index)].texture_path = path;
            } else if (race_part_section == 1 && race_part_index < 5) {
                auto& parts = race_part_female ? race_face_gen.body_parts_female : race_face_gen.body_parts_male;
                parts[static_cast<std::size_t>(race_part_index)].texture_path = path;
            }
        } else if (tag == "FGTS" && is_npc_base) {
            npc.face_texture.assign(value, value + subrecord_size);
            if (subrecord_size % 4 == 0) {
                npc.face_texture_coefficients.reserve(subrecord_size / 4);
                for (std::size_t offset = 0; offset < subrecord_size; offset += 4)
                    npc.face_texture_coefficients.push_back(f32(value + offset));
            }
        } else if (tag == "DOFT" && is_npc_base && subrecord_size >= 4) {
            npc.default_outfit_form_id = u32(value);
        } else if (tag == "CNTO" && is_npc_base && subrecord_size >= 8) {
            npc.inventory.push_back({u32(value), static_cast<std::int32_t>(u32(value + 4))});
        } else if (tag == "PKID" && is_npc_base && subrecord_size >= 4) {
            npc.ai_package_form_ids.push_back(u32(value));
        } else if (tag == "PKDT" && is_ai_package) {
            if (subrecord_size >= 8) {
                ai_package.flags = u32(value);
                ai_package.package_type = value[4];
            } else if (subrecord_size >= 4) {
                ai_package.flags = u16(value);
                ai_package.package_type = value[2];
            }
        } else if (tag == "PLDT" && is_ai_package && subrecord_size >= 12) {
            ai_package.location_type = static_cast<std::int32_t>(u32(value));
            ai_package.location_form_id = u32(value + 4);
            ai_package.location_radius = static_cast<std::int32_t>(u32(value + 8));
        } else if (tag == "DATA" && is_reference && subrecord_size >= 24) {
            for (std::size_t i = 0; i < 3; ++i) {
                reference.position[i] = f32(value + 4 * i);
                reference.rotation[i] = f32(value + 12 + 4 * i);
            }
        } else if (tag == "XTEL" && is_reference && subrecord_size >= 28) {
            reference.teleport_ref_id = u32(value);
            for (std::size_t i = 0; i < 3; ++i) {
                reference.teleport_position[i] = f32(value + 4 + 4 * i);
                reference.teleport_rotation[i] = f32(value + 16 + 4 * i);
            }
        } else if (tag == "DATA" && is_game_setting && subrecord_size >= 4
                   && !base_editor_id.empty() && base_editor_id.front() == 'f') {
            float_game_settings_[base_editor_id] = f32(value);
        }
        cursor += subrecord_size;
    }

    if (is_cell) {
        cell_by_id_[form_id] = cells_.size();
        cells_.push_back(std::move(cell));
    } else if (is_reference && active_cell_id != 0) {
        if (const auto cell_it = cell_by_id_.find(active_cell_id); cell_it != cell_by_id_.end())
            cells_[cell_it->second].references.push_back(std::move(reference));
    }
    if (is_npc_base)
        npc_by_id_[form_id] = std::move(npc);
    if (is_race)
        race_face_gen_by_id_[form_id] = std::move(race_face_gen);
    if (is_outfit)
        outfit_by_id_[form_id] = std::move(outfit);
    if (is_ai_package)
        ai_package_by_id_[form_id] = std::move(ai_package);
    record_type_by_id_[form_id] = std::string(type);
    if (!base_editor_id.empty())
        base_editor_id_by_id_[form_id] = std::move(base_editor_id);
}

} // namespace oblivion
