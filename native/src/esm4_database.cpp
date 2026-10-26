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
#include <array>
#include <cctype>
#include <cstring>
#include <fstream>
#include <iterator>
#include <limits>
#include <optional>
#include <set>
#include <stdexcept>

#include "inflate_bounded.hpp"

namespace oblivion {
namespace {

constexpr std::uint32_t kCompressedRecord = 0x00040000;
constexpr std::uint32_t kGroup = 0x50555247; // GRUP, little endian
constexpr std::uint32_t kCellChildGroup = 6;
// Oblivion nests GRUPs about six levels deep; this bound only stops corrupt
// files from recursing until the stack overflows.
constexpr std::size_t kMaxGroupDepth = 64;
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
    return inflate_bounded(data + 4, size - 4, u32(data),
                           "ESM4 " + std::string(type) + " record " + std::to_string(form_id));
}

bool is_cell_reference_group(std::uint32_t type) {
    // Only type 6 introduces a cell ID. Its type 8/9/10 children inherit it.
    // Type 8 can also occur directly under a worldspace and holds world-wide
    // persistent references, so its label must not be treated as a cell ID.
    return type == kCellChildGroup;
}

std::string lower_ascii(std::string value) {
    std::transform(value.begin(), value.end(), value.begin(), [](unsigned char character) {
        return static_cast<char>(std::tolower(character));
    });
    return value;
}

// Parses a 24-byte CTDA. When the "use global" flag (0x04) is set, the comparison field is the
// form id of a GLOB record rather than a float.
QuestCondition parse_condition(const std::uint8_t* value, std::size_t size) {
    QuestCondition condition;
    condition.operator_code = value[0];
    condition.function_index = u16(value + 8);
    condition.parameter1 = u32(value + 12);
    condition.parameter2 = u32(value + 16);
    if (size >= 24) condition.run_on = u32(value + 20);
    // TES4 marks "run on target" in the type byte (bit 0x02): the condition is about the listener, not the speaker.
    if ((condition.operator_code & 0x02) != 0) condition.run_on = 1;
    if ((condition.operator_code & 0x04) != 0) {
        condition.comparison_is_global = true;
        condition.comparison_global_form_id = u32(value + 4);
    } else {
        condition.comparison = f32(value + 4);
    }
    return condition;
}

bool is_runtime_visual_record(std::string_view type) {
    static constexpr std::array relevant_types = {
        std::string_view("CELL"), std::string_view("REFR"), std::string_view("ACHR"),
        std::string_view("ACRE"), std::string_view("GMST"), std::string_view("NPC_"), std::string_view("CREA"),
        std::string_view("RACE"), std::string_view("OTFT"), std::string_view("PACK"), std::string_view("IDLE"),
        std::string_view("TREE"), std::string_view("LAND"), std::string_view("LTEX"),
        std::string_view("WRLD"), std::string_view("STAT"), std::string_view("DOOR"),
        std::string_view("FURN"), std::string_view("ACTI"), std::string_view("MSTT"),
        std::string_view("ARMO"), std::string_view("CLOT"), std::string_view("WEAP"), std::string_view("SPEL"),
        std::string_view("MGEF"), std::string_view("CSTY"),
        std::string_view("HAIR"), std::string_view("EYES"), std::string_view("ALCH"),
        std::string_view("AMMO"), std::string_view("APPA"), std::string_view("BOOK"),
        std::string_view("INGR"), std::string_view("KEYM"), std::string_view("MISC"),
        std::string_view("SLGM"), std::string_view("SGST"),
        std::string_view("QUST"), std::string_view("SCPT"), std::string_view("GLOB"), std::string_view("DIAL"), std::string_view("INFO"),
        std::string_view("PGRD"),
    };
    return std::find(relevant_types.begin(), relevant_types.end(), type) != relevant_types.end();
}

} // namespace

void Esm4Database::open(const std::filesystem::path& path, bool runtime_visuals_only) {
    cells_.clear();
    cell_by_id_.clear();
    cell_by_editor_id_.clear();
    base_model_by_id_.clear();
    base_editor_id_by_id_.clear();
    record_display_name_by_id_.clear();
    record_icon_path_by_id_.clear();
    script_form_id_by_id_.clear();
    form_id_by_editor_id_.clear();
    npc_by_id_.clear();
    combat_style_by_id_.clear();
    spell_by_id_.clear();
    weapon_by_id_.clear();
    magic_effect_by_code_.clear();
    race_face_gen_by_id_.clear();
    outfit_by_id_.clear();
    ai_package_by_id_.clear();
    pathgrid_by_cell_id_.clear();
    idle_by_id_.clear();
    idle_children_by_parent_.clear();
    tree_by_id_.clear();
    item_model_by_id_.clear();
    female_item_model_by_id_.clear();
    world_item_model_by_id_.clear();
    female_world_item_model_by_id_.clear();
    item_biped_slots_by_id_.clear();
    land_texture_path_by_id_.clear();
    worldspace_water_level_by_id_.clear();
    record_type_by_id_.clear();
    record_type_names_.clear();
    script_by_id_.clear();
    script_id_by_editor_id_.clear();
    quest_by_id_.clear();
    quest_id_by_editor_id_.clear();
    topic_by_id_.clear();
    topic_order_.clear();
    responses_by_topic_.clear();
    active_topic_id_ = 0;
    record_type_index_.clear();
    references_by_cell_id_.clear();
    cell_by_reference_id_.clear();
    float_game_settings_.clear();
    global_value_by_id_.clear();
    record_count_ = 0;
    unplaced_reference_count_ = 0;
    unplaced_references_.clear();
    const auto bytes = read_file(path);
    parse_file(bytes, runtime_visuals_only);
    build_idle_tree();
    for (std::size_t index = 0; index < cells_.size(); ++index)
        if (!cells_[index].editor_id.empty())
            cell_by_editor_id_.try_emplace(lower_ascii(cells_[index].editor_id), index);
    for (auto& cell : cells_) {
        if (const auto water = worldspace_water_level_by_id_.find(cell.worldspace_form_id);
            water != worldspace_water_level_by_id_.end()) {
            cell.has_worldspace_water_level = true;
            cell.worldspace_water_height = water->second;
        }
        if (const auto texture = land_texture_path_by_id_.find(cell.land_texture_form_id);
            texture != land_texture_path_by_id_.end())
            cell.land_texture_path = texture->second.find('/') == std::string::npos
                ? "textures/landscape/" + texture->second : texture->second;
    }
    for (const auto& [form_id, script] : script_by_id_)
        script_id_by_editor_id_.try_emplace(lower_ascii(script.editor_id), form_id);
    for (const auto& [form_id, quest] : quest_by_id_)
        quest_id_by_editor_id_.try_emplace(lower_ascii(quest.editor_id), form_id);
    for (auto& [topic_id, responses] : responses_by_topic_) {
        if (const auto topic = topic_by_id_.find(topic_id); topic != topic_by_id_.end())
            topic->second.responses = std::move(responses);
    }
    responses_by_topic_.clear();
    for (const auto& [form_id, editor_id] : base_editor_id_by_id_)
        form_id_by_editor_id_.try_emplace(lower_ascii(editor_id), form_id);
    for (auto& cell : cells_) {
        for (auto& reference : cell.references) {
            if (reference.script_form_id == 0) {
                if (const auto script = script_form_id_by_id_.find(reference.base_form_id);
                    script != script_form_id_by_id_.end())
                    reference.script_form_id = script->second;
            }
            if (auto model = base_model_by_id_.find(reference.base_form_id); model != base_model_by_id_.end())
                reference.model_path = model->second;
            else if (auto world_model = world_item_model_by_id_.find(reference.base_form_id);
                     world_model != world_item_model_by_id_.end())
                reference.model_path = world_model->second;
            else if (auto item_model = item_model_by_id_.find(reference.base_form_id);
                     item_model != item_model_by_id_.end())
                reference.model_path = item_model->second;
            if (auto tree = tree_by_id_.find(reference.base_form_id); tree != tree_by_id_.end()) {
                reference.is_tree = true;
                reference.tree_billboard_width = tree->second.billboard_width;
                reference.tree_billboard_height = tree->second.billboard_height;
                const auto& model_path = tree->second.model_path;
                const auto separator = model_path.find_last_of("/\\");
                std::string stem = model_path.substr(separator == std::string::npos ? 0 : separator + 1);
                const auto extension = stem.find_last_of('.');
                if (extension != std::string::npos) stem.resize(extension);
                if (!stem.empty())
                    reference.tree_billboard_texture_path = "textures/trees/billboards/"
                        + lower_ascii(stem) + ".dds";
            }
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
    const auto it = cell_by_editor_id_.find(lower_ascii(std::string(editor_id)));
    return it == cell_by_editor_id_.end() ? nullptr : &cells_[it->second];
}

const CellRecord* Esm4Database::find_cell(std::uint32_t form_id) const {
    const auto it = cell_by_id_.find(form_id);
    return it == cell_by_id_.end() ? nullptr : &cells_[it->second];
}

const NpcBaseRecord* Esm4Database::find_npc_base(std::uint32_t form_id) const {
    const auto it = npc_by_id_.find(form_id);
    return it == npc_by_id_.end() ? nullptr : &it->second;
}

const CreatureBaseRecord* Esm4Database::find_creature_base(std::uint32_t form_id) const {
    const auto it = creature_by_id_.find(form_id);
    return it == creature_by_id_.end() ? nullptr : &it->second;
}

const CombatStyleRecord* Esm4Database::find_combat_style(std::uint32_t form_id) const {
    const auto it = combat_style_by_id_.find(form_id);
    return it == combat_style_by_id_.end() ? nullptr : &it->second;
}

const SpellRecord* Esm4Database::find_spell(std::uint32_t form_id) const {
    const auto it = spell_by_id_.find(form_id);
    return it == spell_by_id_.end() ? nullptr : &it->second;
}

const WeaponRecord* Esm4Database::find_weapon(std::uint32_t form_id) const {
    const auto it = weapon_by_id_.find(form_id);
    return it == weapon_by_id_.end() ? nullptr : &it->second;
}

std::optional<float> Esm4Database::find_float_game_setting(std::string_view name) const {
    const auto it = float_game_settings_.find(std::string(name));
    if (it == float_game_settings_.end()) return std::nullopt;
    return it->second;
}

const RaceFaceGenRecord* Esm4Database::find_race_face_gen(std::uint32_t form_id) const {
    const auto it = race_face_gen_by_id_.find(form_id);
    return it == race_face_gen_by_id_.end() ? nullptr : &it->second;
}

const std::string* Esm4Database::find_race_voice_folder(std::uint32_t form_id, bool female) const {
    const auto race = race_face_gen_by_id_.find(form_id);
    if (race == race_face_gen_by_id_.end()) return nullptr;
    const auto voice_form_id = female ? race->second.voice_form_id_female : race->second.voice_form_id_male;
    const auto voice_race = race_face_gen_by_id_.find(voice_form_id != 0 ? voice_form_id : form_id);
    if (voice_race != race_face_gen_by_id_.end() && !voice_race->second.display_name.empty())
        return &voice_race->second.display_name;
    if (voice_form_id != 0 && !race->second.display_name.empty()) return &race->second.display_name;
    return nullptr;
}

const OutfitRecord* Esm4Database::find_outfit(std::uint32_t form_id) const {
    const auto it = outfit_by_id_.find(form_id);
    return it == outfit_by_id_.end() ? nullptr : &it->second;
}

const AiPackageRecord* Esm4Database::find_ai_package(std::uint32_t form_id) const {
    const auto it = ai_package_by_id_.find(form_id);
    return it == ai_package_by_id_.end() ? nullptr : &it->second;
}

const PathgridRecord* Esm4Database::find_pathgrid(std::uint32_t cell_form_id) const {
    const auto it = pathgrid_by_cell_id_.find(cell_form_id);
    return it == pathgrid_by_cell_id_.end() ? nullptr : &it->second;
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
    return it == record_type_by_id_.end() ? nullptr : &record_type_names_[it->second];
}

const std::string* Esm4Database::find_record_display_name(std::uint32_t form_id) const {
    const auto it = record_display_name_by_id_.find(form_id);
    return it == record_display_name_by_id_.end() ? nullptr : &it->second;
}

const std::string* Esm4Database::find_record_icon_path(std::uint32_t form_id) const {
    const auto it = record_icon_path_by_id_.find(form_id);
    return it == record_icon_path_by_id_.end() ? nullptr : &it->second;
}

std::size_t Esm4Database::intern_record_type(std::string_view type) {
    // Oblivion has about 60 record types, so the table stays tiny while a
    // million-record file would otherwise store one string per record.
    if (const auto it = record_type_index_.find(type); it != record_type_index_.end())
        return it->second;
    const auto index = record_type_names_.size();
    record_type_names_.emplace_back(type);
    record_type_index_.emplace(record_type_names_.back(), index);
    return index;
}

void Esm4Database::attach_references() {
    for (auto& [cell_id, references] : references_by_cell_id_) {
        const auto cell_it = cell_by_id_.find(cell_id);
        if (cell_it == cell_by_id_.end()) {
            unplaced_reference_count_ += references.size();
            for (const auto& reference : references) unplaced_references_.emplace_back(reference.form_id, cell_id);
            continue;
        }
        auto& target = cells_[cell_it->second].references;
        target.insert(target.end(), std::make_move_iterator(references.begin()),
                      std::make_move_iterator(references.end()));
    }
    references_by_cell_id_.clear();
}

const DialogTopic* Esm4Database::find_topic(std::uint32_t form_id) const {
    const auto it = topic_by_id_.find(form_id);
    return it == topic_by_id_.end() ? nullptr : &it->second;
}

std::optional<float> Esm4Database::find_global_value(std::uint32_t form_id) const {
    const auto found = global_value_by_id_.find(form_id);
    if (found == global_value_by_id_.end()) return std::nullopt;
    return found->second;
}

const QuestRecord* Esm4Database::find_quest(std::uint32_t form_id) const {
    const auto it = quest_by_id_.find(form_id);
    return it == quest_by_id_.end() ? nullptr : &it->second;
}

const QuestRecord* Esm4Database::find_quest(std::string_view editor_id) const {
    const auto it = quest_id_by_editor_id_.find(lower_ascii(std::string(editor_id)));
    return it == quest_id_by_editor_id_.end() ? nullptr : find_quest(it->second);
}

const ScriptRecord* Esm4Database::find_script(std::uint32_t form_id) const {
    const auto it = script_by_id_.find(form_id);
    return it == script_by_id_.end() ? nullptr : &it->second;
}

const ScriptRecord* Esm4Database::find_script(std::string_view editor_id) const {
    const auto it = script_id_by_editor_id_.find(lower_ascii(std::string(editor_id)));
    return it == script_id_by_editor_id_.end() ? nullptr : find_script(it->second);
}

void Esm4Database::parse_file(const std::vector<std::uint8_t>& bytes, bool runtime_visuals_only) {
    if (bytes.size() < kTes4RecordHeaderSize)
        throw std::runtime_error("ESM file is too small");
    if (std::memcmp(bytes.data(), "TES4", 4) != 0)
        throw std::runtime_error("ESM file does not begin with a TES4 header");
    const auto header_data_size = u32(bytes.data() + 4);
    check_range(bytes.size(), kTes4RecordHeaderSize, header_data_size, "TES4 header record");
    const std::size_t records_begin = kTes4RecordHeaderSize + header_data_size;

    auto walk = [&](auto&& self, std::size_t begin, std::size_t end,
                    std::uint32_t active_cell_id, std::uint32_t worldspace_form_id,
                    bool exterior_grid_context, std::size_t depth) -> void {
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
                if (depth >= kMaxGroupDepth)
                    throw std::runtime_error("ESM4 GRUP nesting exceeds the supported depth");
                const auto child_cell_id = is_cell_reference_group(group_type) ? group_label : active_cell_id;
                const auto child_worldspace_id = group_type == 1 ? group_label : worldspace_form_id;
                const bool child_exterior_grid_context = group_type == 4 || group_type == 5
                    ? true : group_type == 1 || group_type == 2 || group_type == 3
                        ? false : exterior_grid_context;
                // Type 7 groups hold the INFO responses of the DIAL topic whose form ID is the label.
                const auto saved_topic = active_topic_id_;
                if (group_type == 7) active_topic_id_ = group_label;
                self(self, cursor + kGroupHeaderSize, cursor + group_size, child_cell_id,
                     child_worldspace_id, child_exterior_grid_context, depth + 1);
                active_topic_id_ = saved_topic;
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
            const std::string_view record_type_view(record_type, 4);
            if (!runtime_visuals_only || is_runtime_visual_record(record_type_view)) {
                std::vector<std::uint8_t> inflated;
                if (flags & kCompressedRecord) {
                    inflated = decompress_record(record_data, data_size, record_type_view, form_id);
                    record_data = inflated.data();
                    parse_record(record_type_view, form_id, flags, active_cell_id,
                                 worldspace_form_id, exterior_grid_context,
                                 record_data, inflated.size());
                } else {
                    parse_record(record_type_view, form_id, flags, active_cell_id,
                                 worldspace_form_id, exterior_grid_context,
                                 record_data, data_size);
                }
            }
            ++record_count_;
            cursor += kRecordHeaderSize + data_size;
        }
    };

    walk(walk, records_begin, bytes.size(), 0, 0, false, 0);
    for (auto& [form_id, spell] : spell_by_id_) {
        (void)form_id;
        for (auto& effect : spell.effects) {
            const auto magic_effect = magic_effect_by_code_.find(lower_ascii(effect.code));
            if (magic_effect == magic_effect_by_code_.end()) continue;
            effect.magic_effect_flags = magic_effect->second.flags;
            effect.magic_school = magic_effect->second.school;
            effect.base_cost = magic_effect->second.base_cost;
        }
    }
    attach_references();
}

bool IdleRecord::is_folder() const {
    const auto size = animation_file.size();
    if (size < 3) return true;
    std::string tail = animation_file.substr(size - 3);
    for (auto& c : tail) c = static_cast<char>(std::tolower(static_cast<unsigned char>(c)));
    return tail != ".kf";
}

const IdleRecord* Esm4Database::find_idle(std::uint32_t form_id) const {
    const auto found = idle_by_id_.find(form_id);
    return found == idle_by_id_.end() ? nullptr : &found->second;
}

const std::vector<const IdleRecord*>& Esm4Database::idle_children(std::uint32_t parent_form_id) const {
    static const std::vector<const IdleRecord*> none;
    const auto found = idle_children_by_parent_.find(parent_form_id);
    return found == idle_children_by_parent_.end() ? none : found->second;
}

// Orders the children of every node by the previous-sibling links: the child with no previous sibling (or
// whose previous sibling is not one of its siblings) first, then the one that names it, and so on. Links that
// do not lead anywhere (broken, cyclic) leave the rest in form ID order, so the order is always complete.
void Esm4Database::build_idle_tree() {
    idle_children_by_parent_.clear();
    std::map<std::uint32_t, std::vector<const IdleRecord*>> unordered;
    for (const auto& [form_id, idle] : idle_by_id_) unordered[idle.parent_form_id].push_back(&idle);
    for (auto& [parent, siblings] : unordered) {
        std::set<std::uint32_t> ids;
        for (const auto* idle : siblings) ids.insert(idle->form_id);
        std::vector<const IdleRecord*> ordered;
        std::set<std::uint32_t> placed;
        const auto place_chain = [&](const IdleRecord* head) {
            const IdleRecord* current = head;
            while (current && placed.insert(current->form_id).second) {
                ordered.push_back(current);
                const IdleRecord* next = nullptr;
                for (const auto* candidate : siblings)
                    if (candidate->previous_sibling_form_id == current->form_id && !placed.count(candidate->form_id)) {
                        next = candidate;
                        break;
                    }
                current = next;
            }
        };
        for (const auto* idle : siblings)
            if (idle->previous_sibling_form_id == 0 || !ids.count(idle->previous_sibling_form_id)) place_chain(idle);
        for (const auto* idle : siblings) place_chain(idle);
        idle_children_by_parent_[parent] = std::move(ordered);
    }
}

void Esm4Database::parse_record(std::string_view type, std::uint32_t form_id, std::uint32_t record_flags,
                                std::uint32_t active_cell_id, std::uint32_t worldspace_form_id,
                                bool exterior_grid_context, const std::uint8_t* data, std::size_t data_size) {
    bool is_cell = type == "CELL";
    bool is_reference = type == "REFR" || type == "ACHR" || type == "ACRE";
    bool is_game_setting = type == "GMST";
    const bool is_global = type == "GLOB";
    bool is_npc_base = type == "NPC_";
    const bool is_creature = type == "CREA";
    const bool is_combat_style = type == "CSTY";
    bool is_race = type == "RACE";
    bool is_spell = type == "SPEL";
    bool is_magic_effect = type == "MGEF";
    bool is_outfit = type == "OTFT";
    bool is_ai_package = type == "PACK";
    const bool is_idle = type == "IDLE";
    const bool is_pathgrid = type == "PGRD";
    IdleRecord idle;
    idle.form_id = form_id;
    bool is_tree = type == "TREE";
    bool is_land = type == "LAND";
    bool is_land_texture = type == "LTEX";
    bool is_worldspace = type == "WRLD";
    bool is_script = type == "SCPT";
    bool is_quest = type == "QUST";
    const bool is_topic = type == "DIAL";
    const bool is_response = type == "INFO";
    DialogTopic topic;
    topic.form_id = form_id;
    DialogResponse response;
    response.form_id = form_id;
    QuestRecord quest;
    quest.form_id = form_id;
    const bool is_item_model = type == "ARMO" || type == "CLOT" || type == "WEAP"
        || type == "HAIR" || type == "EYES" || type == "ALCH" || type == "AMMO"
        || type == "APPA" || type == "BOOK" || type == "INGR" || type == "KEYM"
        || type == "MISC" || type == "SLGM" || type == "SGST";
    CellRecord cell;
    cell.form_id = form_id;
    cell.interior = true;
    PathgridRecord pathgrid;
    pathgrid.form_id = form_id;
    pathgrid.cell_form_id = active_cell_id;
    std::int16_t pathgrid_node_count = -1;
    std::vector<std::uint8_t> pathgrid_points_data;
    std::vector<std::uint8_t> pathgrid_links_data;
    PlacedReference reference;
    reference.form_id = form_id;
    NpcBaseRecord npc;
    npc.form_id = form_id;
    CreatureBaseRecord creature;
    creature.form_id = form_id;
    CombatStyleRecord combat_style;
    combat_style.form_id = form_id;
    SpellRecord spell;
    spell.form_id = form_id;
    MagicEffectRecord magic_effect;
    RaceFaceGenRecord race_face_gen;
    race_face_gen.form_id = form_id;
    OutfitRecord outfit;
    outfit.form_id = form_id;
    AiPackageRecord ai_package;
    ai_package.form_id = form_id;
    TreeBaseRecord tree;
    ScriptRecord script;
    script.form_id = form_id;
    std::vector<float> land_heights;
    std::map<std::uint32_t, std::size_t> land_texture_usage;
    int race_part_section = -1;
    int race_part_index = -1;
    bool race_part_female = false;
    if (is_reference) {
        reference.record_type.assign(type);
        reference.initially_disabled = (record_flags & 0x0800) != 0;
    }
    std::string base_editor_id;
    // GMST DATA can precede EDID, so the value is held until the name is known.
    std::optional<float> game_setting_value;
    std::optional<float> global_value;  // GLOB FLTV: every global is stored as a float, whatever its FNAM type

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

        if (tag == "SCRI" && subrecord_size >= 4)
            script_form_id_by_id_[form_id] = u32(value);

        if (tag == "EDID") {
            const auto text = read_zstring(value, subrecord_size);
            if (is_cell) cell.editor_id = text;
            else if (is_reference) reference.reference_name = text;
            else if (type == "STAT" || type == "DOOR" || type == "FURN" || type == "ACTI" || type == "MSTT" || type == "RACE" || is_game_setting || is_npc_base || is_creature || is_item_model || is_spell || is_magic_effect || is_outfit || is_ai_package || is_tree || is_combat_style)
                base_editor_id = text;
            if (is_npc_base) npc.editor_id = text;
            if (is_creature) creature.editor_id = text;
            if (is_script) script.editor_id = text;
            if (is_topic) topic.editor_id = text;
            if (is_quest) quest.editor_id = text;
            if (is_outfit) outfit.editor_id = text;
            if (is_ai_package) ai_package.editor_id = text;
            if (is_idle) idle.editor_id = text;
        } else if (tag == "FULL" && is_cell) {
            cell.display_name = read_zstring(value, subrecord_size);
        } else if (tag == "FULL" && is_npc_base) {
            npc.name = read_zstring(value, subrecord_size);
            record_display_name_by_id_[form_id] = npc.name;
        } else if (tag == "FULL" && is_race) {
            race_face_gen.display_name = lower_ascii(read_zstring(value, subrecord_size));
            record_display_name_by_id_[form_id] = race_face_gen.display_name;
        } else if (tag == "FULL" && is_creature) {
            creature.name = read_zstring(value, subrecord_size);
            record_display_name_by_id_[form_id] = creature.name;
        } else if (tag == "FULL" && (is_item_model || is_spell)) {
            const auto display_name = read_zstring(value, subrecord_size);
            if (!display_name.empty()) record_display_name_by_id_[form_id] = display_name;
        } else if (tag == "DATA" && is_cell && subrecord_size >= 1) {
            const std::uint16_t cell_flags = subrecord_size >= 2 ? u16(value) : value[0];
            cell.interior = (cell_flags & 0x0001) != 0;
        } else if (tag == "DATA" && is_pathgrid && subrecord_size >= 2) {
            pathgrid_node_count = static_cast<std::int16_t>(u16(value));
        } else if (tag == "PGRP" && is_pathgrid) {
            pathgrid_points_data.assign(value, value + subrecord_size);
        } else if (tag == "PGRR" && is_pathgrid) {
            pathgrid_links_data.assign(value, value + subrecord_size);
        } else if (tag == "XCLC" && is_cell && subrecord_size >= 8) {
            cell.grid_x = static_cast<std::int32_t>(u32(value));
            cell.grid_y = static_cast<std::int32_t>(u32(value + 4));
            cell.has_grid = true;
        } else if (tag == "XCLW" && is_cell && subrecord_size >= 4) {
            cell.water_height = f32(value);
            cell.has_water_level = true;
        } else if (tag == "ICON" && is_land_texture) {
            const auto texture_path = read_zstring(value, subrecord_size);
            if (!texture_path.empty()) land_texture_path_by_id_[form_id] = texture_path;
        } else if (tag == "ICON" && (is_item_model || is_spell)) {
            const auto icon_path = read_zstring(value, subrecord_size);
            if (!icon_path.empty()) record_icon_path_by_id_[form_id] = icon_path;
        } else if (tag == "SPIT" && is_spell && subrecord_size >= 16) {
            spell.spell_type = value[0];
            spell.cost = u32(value + 4);
            spell.level = value[8];
            spell.flags = value[12];
        } else if (tag == "EFIT" && is_spell && subrecord_size >= 24) {
            SpellEffectRecord effect;
            const auto code = u32(value);
            effect.code.resize(4);
            for (std::size_t i = 0; i < 4; ++i)
                effect.code[i] = static_cast<char>((code >> (i * 8)) & 0xff);
            effect.magnitude = u32(value + 4);
            effect.area = u32(value + 8);
            effect.duration = u32(value + 12);
            effect.range_type = u32(value + 16);
            effect.actor_value = static_cast<std::int32_t>(u32(value + 20));
            spell.effects.push_back(std::move(effect));
        } else if (tag == "DATA" && is_magic_effect && subrecord_size >= 16) {
            magic_effect.flags = u32(value);
            magic_effect.base_cost = f32(value + 4);
            magic_effect.school = u32(value + 12);
        } else if (tag == "DNAM" && is_worldspace && subrecord_size >= 8) {
            worldspace_water_level_by_id_[form_id] = f32(value + 4);
        } else if (tag == "VHGT" && is_land && subrecord_size >= 4 + 33 * 33) {
            constexpr std::size_t side = 33;
            land_heights.resize(side * side);
            float row_offset = f32(value);
            for (std::size_t y = 0; y < side; ++y) {
                row_offset += static_cast<std::int8_t>(value[4 + y * side]);
                land_heights[y * side] = row_offset * 8.0f;
                float column_offset = row_offset;
                for (std::size_t x = 1; x < side; ++x) {
                    column_offset += static_cast<std::int8_t>(value[4 + y * side + x]);
                    land_heights[y * side + x] = column_offset * 8.0f;
                }
            }
        } else if (tag == "VTEX" && is_land && subrecord_size % 4 == 0) {
            for (std::size_t offset = 0; offset < subrecord_size; offset += 4) {
                const auto texture_id = u32(value + offset);
                if (texture_id != 0) ++land_texture_usage[texture_id];
            }
        } else if ((tag == "BTXT" || tag == "ATXT") && is_land && subrecord_size >= 4) {
            const auto texture_id = u32(value);
            if (texture_id != 0) ++land_texture_usage[texture_id];
        } else if (tag == "MODL" && (type == "STAT" || type == "DOOR" || type == "FURN" || type == "ACTI" || type == "MSTT")) {
            const auto path = read_zstring(value, subrecord_size);
            if (!path.empty()) base_model_by_id_[form_id] = path;
        } else if (tag == "MODL" && is_creature) {
            creature.model_path = read_zstring(value, subrecord_size);
        } else if (tag == "NIFZ" && is_creature) {
            // NIFZ and KFFZ hold several zero-terminated strings back to back.
            std::size_t start = 0;
            for (std::size_t i = 0; i < subrecord_size; ++i) {
                if (value[i] != 0) continue;
                if (i > start) creature.body_part_paths.emplace_back(reinterpret_cast<const char*>(value + start), i - start);
                start = i + 1;
            }
        } else if (tag == "KFFZ" && is_creature) {
            std::size_t start = 0;
            for (std::size_t i = 0; i < subrecord_size; ++i) {
                if (value[i] != 0) continue;
                if (i > start) creature.animation_files.emplace_back(reinterpret_cast<const char*>(value + start), i - start);
                start = i + 1;
            }
        } else if (tag == "ACBS" && is_creature && subrecord_size >= 4) {
            creature.flags = u32(value);
            if (subrecord_size >= 6) creature.base_magicka = u16(value + 4);
            if (subrecord_size >= 8) creature.base_fatigue = u16(value + 6);
            if (subrecord_size >= 12) creature.level_or_offset = static_cast<std::int16_t>(u16(value + 10));
        } else if (tag == "DATA" && is_creature && subrecord_size >= 16) {
            creature.creature_type = value[0];
            creature.combat_skill = value[1];
            creature.base_health = u16(value + 6);
            creature.attack_damage = u16(value + 10);
            std::copy_n(value + 12, std::min<std::size_t>(creature.attributes.size(), subrecord_size - 12),
                        creature.attributes.begin());
        } else if (tag == "ZNAM" && is_creature && subrecord_size >= 4) {
            creature.combat_style_form_id = u32(value);
        } else if (tag == "BNAM" && is_creature && subrecord_size >= 4) {
            creature.base_scale = f32(value);
        } else if (tag == "RNAM" && is_creature && subrecord_size >= 1) {
            creature.attack_reach = static_cast<float>(value[0]);
        } else if (tag == "SCRI" && is_creature && subrecord_size >= 4) {
            creature.script_form_id = u32(value);
        } else if (tag == "SPLO" && is_creature && subrecord_size >= 4) {
            creature.spell_form_ids.push_back(u32(value));
        } else if (tag == "AIDT" && is_creature && subrecord_size >= 2) {
            creature.aggression = value[0];
            creature.confidence = value[1];
        } else if (tag == "SNAM" && is_creature && subrecord_size >= 5) {
            creature.factions.emplace_back(u32(value), static_cast<std::int8_t>(value[4]));
        } else if (tag == "PKID" && is_creature && subrecord_size >= 4) {
            creature.ai_package_form_ids.push_back(u32(value));
        } else if (tag == "MODL" && is_tree) {
            tree.model_path = read_zstring(value, subrecord_size);
        } else if ((tag == "BNAM" || tag == "MODT" || tag == "MODC" || tag == "MODS" || tag == "MODF")
                   && is_tree && subrecord_size == 8) {
            tree.billboard_width = f32(value);
            tree.billboard_height = f32(value + 4);
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
        } else if (tag == "DATA" && type == "WEAP" && subrecord_size >= 30) {
            WeaponRecord weapon;
            weapon.weapon_type = u32(value);
            weapon.speed = f32(value + 4);
            weapon.reach = f32(value + 8);
            weapon.flags = u32(value + 12);
            weapon.damage = u16(value + 28);
            weapon_by_id_[form_id] = weapon;
        } else if (tag == "BMDT" && (type == "ARMO" || type == "CLOT") && subrecord_size >= 2) {
            item_biped_slots_by_id_[form_id] = u16(value);
        } else if (tag == "INAM" && is_outfit && subrecord_size >= 4) {
            outfit.item_form_ids.push_back(u32(value));
        } else if (tag == "SCRI" && is_npc_base && subrecord_size >= 4) {
            npc.script_form_id = u32(value);
        } else if (tag == "SCRI" && is_reference && subrecord_size >= 4) {
            reference.script_form_id = u32(value);
        } else if (tag == "NAME" && is_reference && subrecord_size >= 4) {
            reference.base_form_id = u32(value);
        } else if (tag == "ACBS" && is_npc_base && subrecord_size >= 4) {
            npc.flags = u32(value);
            if (subrecord_size >= 12) {
                npc.base_magicka = u16(value + 4);
                npc.base_fatigue = u16(value + 6);
                npc.level_or_offset = static_cast<std::int16_t>(u16(value + 10));
            }
        } else if (tag == "RNAM" && is_npc_base && subrecord_size >= 4) {
            npc.race_form_id = u32(value);
        } else if (tag == "ZNAM" && is_npc_base && subrecord_size >= 4) {
            npc.combat_style_form_id = u32(value);
        } else if (tag == "CSTD" && is_combat_style) {
            if (subrecord_size >= 1) combat_style.dodge_chance = value[0];
            if (subrecord_size >= 2) combat_style.dodge_left_right_chance = value[1];
            if (subrecord_size >= 37) combat_style.block_chance = value[36];
            if (subrecord_size >= 8) combat_style.dodge_left_right_min_time = f32(value + 4);
            if (subrecord_size >= 12) combat_style.dodge_left_right_max_time = f32(value + 8);
            if (subrecord_size >= 16) combat_style.dodge_forward_min_time = f32(value + 12);
            if (subrecord_size >= 20) combat_style.dodge_forward_max_time = f32(value + 16);
            if (subrecord_size >= 24) combat_style.dodge_backward_min_time = f32(value + 20);
            if (subrecord_size >= 28) combat_style.dodge_backward_max_time = f32(value + 24);
            if (subrecord_size >= 81) combat_style.advanced_enabled = (value[80] & 0x01) != 0;
        } else if (tag == "CSAD" && is_combat_style) {
            combat_style.has_advanced_data = subrecord_size > 0;
            if (subrecord_size >= 4) combat_style.dodge_fatigue_mod_mult = f32(value);
            if (subrecord_size >= 8) combat_style.dodge_fatigue_mod_base = f32(value + 4);
            if (subrecord_size >= 20) combat_style.dodge_under_attack_mult = f32(value + 16);
            if (subrecord_size >= 24) combat_style.dodge_not_under_attack_mult = f32(value + 20);
            if (subrecord_size >= 28) combat_style.dodge_back_under_attack_mult = f32(value + 24);
            if (subrecord_size >= 32) combat_style.dodge_back_not_under_attack_mult = f32(value + 28);
            if (subrecord_size >= 36) combat_style.dodge_forward_while_attacking_mult = f32(value + 32);
            if (subrecord_size >= 40) combat_style.dodge_forward_not_attacking_mult = f32(value + 36);
            if (subrecord_size >= 44) combat_style.block_skill_modifier_mult = f32(value + 40);
            if (subrecord_size >= 48) combat_style.block_skill_modifier_base = f32(value + 44);
            if (subrecord_size >= 52) combat_style.block_under_attack_mult = f32(value + 48);
            if (subrecord_size >= 56) combat_style.block_not_under_attack_mult = f32(value + 52);
        } else if (tag == "VNAM" && is_race && subrecord_size >= 8) {
            race_face_gen.voice_form_id_male = u32(value);
            race_face_gen.voice_form_id_female = u32(value + 4);
        } else if (tag == "CNAM" && is_npc_base && subrecord_size >= 4) {
            npc.class_form_id = u32(value);
        } else if (tag == "DATA" && is_npc_base && subrecord_size >= 33) {
            std::copy_n(value, npc.skills.size(), npc.skills.begin());
            npc.base_health = u32(value + npc.skills.size());
            std::copy_n(value + npc.skills.size() + 4, npc.attributes.size(), npc.attributes.begin());
            npc.has_actor_values = true;
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
        } else if (tag == "SPLO" && is_npc_base && subrecord_size >= 4) {
            npc.spell_form_ids.push_back(u32(value));
        } else if (tag == "AIDT" && is_npc_base && subrecord_size >= 2) {
            npc.aggression = value[0];
            npc.confidence = value[1];
        } else if (tag == "SNAM" && is_npc_base && subrecord_size >= 5) {
            npc.factions.emplace_back(u32(value), static_cast<std::int8_t>(value[4]));
        } else if (tag == "PKID" && is_npc_base && subrecord_size >= 4) {
            npc.ai_package_form_ids.push_back(u32(value));
        } else if (tag == "CTDA" && is_ai_package && subrecord_size >= 24) {
            QuestCondition condition = parse_condition(value, subrecord_size);
            ai_package.conditions.push_back(condition);
        } else if ((tag == "CTDA" || tag == "CTDT") && is_idle && subrecord_size >= 20) {
            // CTDT is the 20-byte form of CTDA that the master also uses; parse_condition reads only the first 20 bytes.
            idle.conditions.push_back(parse_condition(value, subrecord_size));
        } else if (tag == "MODL" && is_idle) {
            idle.animation_file = read_zstring(value, subrecord_size);
        } else if (tag == "ANAM" && is_idle && subrecord_size >= 1) {
            idle.group_flags = value[0];
        } else if (tag == "DATA" && is_idle && subrecord_size >= 8) {
            idle.parent_form_id = u32(value);
            idle.previous_sibling_form_id = u32(value + 4);
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
        } else if (tag == "PTDT" && is_ai_package && subrecord_size >= 12) {
            ai_package.target_type = static_cast<std::int32_t>(u32(value));
            ai_package.target_form_id = u32(value + 4);
            ai_package.target_distance = static_cast<std::int32_t>(u32(value + 8));
        } else if (is_quest) {
            // Stages start at INDX; each entry starts at QSDT and owns the CTDA, CNAM and
            // result (SCTX, SCRO) subrecords that follow it, until the next QSDT or INDX.
            if (tag == "FULL") {
                quest.name = read_zstring(value, subrecord_size);
            } else if (tag == "SCRI" && subrecord_size >= 4) {
                quest.script_form_id = u32(value);
            } else if (tag == "DATA" && subrecord_size >= 2) {
                quest.flags = value[0];
                quest.priority = value[1];
            } else if (tag == "INDX" && subrecord_size >= 2) {
                QuestStage stage;
                stage.index = u16(value);
                quest.stages.push_back(std::move(stage));
            } else if (tag == "QSDT" && subrecord_size >= 1) {
                if (quest.stages.empty()) quest.stages.push_back(QuestStage{});
                quest.stages.back().entries.push_back(QuestStageEntry{});
                quest.stages.back().entries.back().completes = value[0] != 0;
            } else if (tag == "CTDA" && subrecord_size >= 24 && !quest.stages.empty() && !quest.stages.back().entries.empty()) {
                QuestCondition condition = parse_condition(value, subrecord_size);
                quest.stages.back().entries.back().conditions.push_back(condition);
            } else if (tag == "CNAM" && !quest.stages.empty() && !quest.stages.back().entries.empty()) {
                quest.stages.back().entries.back().log_text = read_zstring(value, subrecord_size);
            } else if (tag == "SCTX" && !quest.stages.empty() && !quest.stages.back().entries.empty()) {
                quest.stages.back().entries.back().result_source.assign(reinterpret_cast<const char*>(value), subrecord_size);
                while (!quest.stages.back().entries.back().result_source.empty() && quest.stages.back().entries.back().result_source.back() == '\0')
                    quest.stages.back().entries.back().result_source.pop_back();
            } else if (tag == "SCRO" && subrecord_size >= 4 && !quest.stages.empty() && !quest.stages.back().entries.empty()) {
                quest.stages.back().entries.back().result_references.push_back(u32(value));
            }
        } else if (is_topic) {
            if (tag == "EDID") topic.editor_id = read_zstring(value, subrecord_size);
            else if (tag == "FULL") topic.name = read_zstring(value, subrecord_size);
            else if (tag == "DATA" && subrecord_size >= 1) topic.topic_type = value[0];
            else if (tag == "QSTI" && subrecord_size >= 4) topic.quests.push_back(u32(value));
        } else if (is_response) {
            if (tag == "TRDT") {
                // Each TRDT starts a response; the NAM1 that follows is that response's text.
                DialogResponseLine line;
                line.number = subrecord_size >= 13 ? value[12] : static_cast<std::uint8_t>(response.lines.size() + 1);
                if (subrecord_size >= 16) {
                    line.emotion_type = u32(value);
                    line.emotion_value = static_cast<std::int32_t>(u32(value + 4));
                }
                response.lines.push_back(std::move(line));
            } else if (tag == "NAM1") {
                auto text = read_zstring(value, subrecord_size);
                if (response.lines.empty() || response.lines.back().has_text) {
                    DialogResponseLine line;
                    line.number = static_cast<std::uint8_t>(response.lines.size() + 1);
                    response.lines.push_back(std::move(line));
                }
                response.lines.back().text = text;
                response.lines.back().has_text = true;
                if (response.lines.size() == 1) response.text = std::move(text);
            } else if (tag == "DATA" && subrecord_size >= 3) response.flags = value[2];
            else if (tag == "QSTI" && subrecord_size >= 4) response.quest = u32(value);
            else if (tag == "CTDA" && subrecord_size >= 24) {
                QuestCondition condition = parse_condition(value, subrecord_size);
                response.conditions.push_back(condition);
            } else if (tag == "TCLT" && subrecord_size >= 4) response.topic_links.push_back(u32(value));
            else if (tag == "SCTX") {
                response.result_source.assign(reinterpret_cast<const char*>(value), subrecord_size);
                while (!response.result_source.empty() && response.result_source.back() == '\0') response.result_source.pop_back();
            } else if (tag == "SCRO" && subrecord_size >= 4) response.result_references.push_back(u32(value));
        } else if (tag == "SCHR" && is_script && subrecord_size >= 20) {
            script.compiled_size = u32(value + 8);
            script.variable_count = u32(value + 12);
            script.type = u16(value + 16);
            script.flags = u16(value + 18);
        } else if (tag == "SCTX" && is_script) {
            script.source.assign(reinterpret_cast<const char*>(value), subrecord_size);
            while (!script.source.empty() && script.source.back() == '\0') script.source.pop_back();
        } else if (tag == "SLSD" && is_script && subrecord_size >= 24) {
            // SLSD is followed by its SCVR name, so the variable is completed then.
            script.variables.push_back({u32(value), static_cast<std::uint32_t>(value[16]), {}});
        } else if (tag == "SCVR" && is_script && !script.variables.empty()) {
            script.variables.back().name = read_zstring(value, subrecord_size);
        } else if (tag == "SCRO" && is_script && subrecord_size >= 4) {
            script.referenced_form_ids.push_back(u32(value));
        } else if (tag == "DATA" && is_reference && subrecord_size >= 24) {
            for (std::size_t i = 0; i < 3; ++i) {
                reference.position[i] = f32(value + 4 * i);
                reference.rotation[i] = f32(value + 12 + 4 * i);
            }
        } else if (tag == "XESP" && is_reference && subrecord_size >= 5) {
            reference.enable_parent_form_id = u32(value);
            reference.enable_parent_inverted = (value[4] & 0x01) != 0;
        } else if (tag == "XLOC" && is_reference && subrecord_size >= 8) {
            reference.lock_level = value[0];
            reference.lock_key_form_id = u32(value + 4);
        } else if (tag == "XTEL" && is_reference && subrecord_size >= 28) {
            reference.teleport_ref_id = u32(value);
            for (std::size_t i = 0; i < 3; ++i) {
                reference.teleport_position[i] = f32(value + 4 + 4 * i);
                reference.teleport_rotation[i] = f32(value + 16 + 4 * i);
            }
        } else if (tag == "DATA" && is_game_setting && subrecord_size >= 4) {
            game_setting_value = f32(value);
        } else if (tag == "FLTV" && is_global && subrecord_size >= 4) {
            global_value = f32(value);
        }
        cursor += subrecord_size;
    }

    if (is_global && global_value) global_value_by_id_[form_id] = *global_value;

    if (is_pathgrid && active_cell_id != 0) {
        if (pathgrid_node_count < 0
            || pathgrid_points_data.size() != static_cast<std::size_t>(pathgrid_node_count) * 16u) {
            throw std::runtime_error("ESM4 PGRD has an invalid node count or PGRP size");
        }
        pathgrid.points.reserve(static_cast<std::size_t>(pathgrid_node_count));
        std::size_t expected_links_size = 0;
        for (std::int16_t index = 0; index < pathgrid_node_count; ++index) {
            const auto offset = static_cast<std::size_t>(index) * 16u;
            pathgrid.points.push_back({f32(pathgrid_points_data.data() + offset),
                                       f32(pathgrid_points_data.data() + offset + 4),
                                       f32(pathgrid_points_data.data() + offset + 8)});
            expected_links_size += pathgrid_points_data[offset + 12] * sizeof(std::int16_t);
        }
        if (pathgrid_links_data.size() < expected_links_size)
            throw std::runtime_error("ESM4 PGRD PGRR is shorter than its node link counts");
        std::size_t link_offset = 0;
        for (std::int16_t start_node = 0; start_node < pathgrid_node_count; ++start_node) {
            const auto point_offset = static_cast<std::size_t>(start_node) * 16u;
            const auto link_count = pathgrid_points_data[point_offset + 12];
            for (std::uint8_t link = 0; link < link_count; ++link) {
                const auto end_node = static_cast<std::int16_t>(u16(pathgrid_links_data.data() + link_offset));
                link_offset += sizeof(std::int16_t);
                if (end_node >= 0 && end_node < pathgrid_node_count)
                    pathgrid.edges.emplace_back(static_cast<std::uint32_t>(start_node),
                                                static_cast<std::uint32_t>(end_node));
            }
        }
        pathgrid_by_cell_id_[active_cell_id] = std::move(pathgrid);
    }

    if (is_game_setting && game_setting_value && !base_editor_id.empty() && base_editor_id.front() == 'f')
        float_game_settings_[base_editor_id] = *game_setting_value;

    if (is_cell) {
        cell.worldspace_form_id = worldspace_form_id;
        cell.exterior_grid_cell = exterior_grid_context;
        cell_by_id_[form_id] = cells_.size();
        cells_.push_back(std::move(cell));
    } else if (is_reference) {
        // The owning CELL may appear after its references, so attachment is
        // deferred until the whole file has been read.
        if (active_cell_id == 0) {
            ++unplaced_reference_count_;
            unplaced_references_.emplace_back(reference.form_id, 0u);
        }
        else references_by_cell_id_[active_cell_id].push_back(std::move(reference));
    } else if (is_land && active_cell_id != 0) {
        if (const auto cell_it = cell_by_id_.find(active_cell_id); cell_it != cell_by_id_.end()) {
            CellRecord& parent_cell = cells_[cell_it->second];
            if (!land_heights.empty()) parent_cell.land_heights = std::move(land_heights);
            if (!land_texture_usage.empty()) {
                const auto dominant = std::max_element(land_texture_usage.begin(), land_texture_usage.end(),
                    [](const auto& left, const auto& right) { return left.second < right.second; });
                parent_cell.land_texture_form_id = dominant->first;
            }
        }
    }
    if (is_npc_base)
        npc_by_id_[form_id] = std::move(npc);
    if (is_creature)
        creature_by_id_[form_id] = std::move(creature);
    if (is_combat_style)
        combat_style_by_id_[form_id] = std::move(combat_style);
    if (is_spell)
        spell_by_id_[form_id] = std::move(spell);
    if (is_magic_effect && !base_editor_id.empty())
        magic_effect_by_code_[lower_ascii(base_editor_id)] = magic_effect;
    if (is_race)
        race_face_gen_by_id_[form_id] = std::move(race_face_gen);
    if (is_outfit)
        outfit_by_id_[form_id] = std::move(outfit);
    if (is_ai_package)
        ai_package_by_id_[form_id] = std::move(ai_package);
    if (is_idle)
        idle_by_id_[form_id] = std::move(idle);
    if (is_tree) {
        if (!tree.model_path.empty()) base_model_by_id_[form_id] = tree.model_path;
        tree_by_id_[form_id] = std::move(tree);
    }
    if (is_worldspace)
        worldspace_water_level_by_id_.try_emplace(form_id, 0.0f);
    if (is_script)
        script_by_id_[form_id] = std::move(script);
    if (is_quest)
        quest_by_id_[form_id] = std::move(quest);
    if (is_topic) {
        topic_order_.push_back(form_id);
        topic_by_id_[form_id] = std::move(topic);
    }
    if (is_response) responses_by_topic_[active_topic_id_].push_back(std::move(response));
    record_type_by_id_[form_id] = intern_record_type(type);
    if (!base_editor_id.empty())
        base_editor_id_by_id_[form_id] = std::move(base_editor_id);
}

} // namespace oblivion
