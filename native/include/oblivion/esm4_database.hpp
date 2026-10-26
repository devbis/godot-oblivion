/*
 * TES4 ESM index for cell discovery and placed reference transforms.
 * The field layout was cross-checked against OpenMW's components/esm4 reader
 * and cell/reference records. No OpenMW implementation source is included.
 */
#pragma once

#include <array>
#include <cstdint>
#include <filesystem>
#include <map>
#include <optional>
#include <string>
#include <string_view>
#include <utility>
#include <vector>

#include "oblivion/script_records.hpp"

namespace oblivion {

struct PlacedReference {
    std::uint32_t form_id = 0;
    std::uint32_t base_form_id = 0;
    std::uint32_t script_form_id = 0;  // SCRI: the script attached to this reference
    std::array<float, 3> position{};
    std::array<float, 3> rotation{};
    std::uint32_t teleport_ref_id = 0;
    std::uint32_t teleport_cell_id = 0;
    std::uint8_t lock_level = 0;         // XLOC: 0 when the reference is not locked
    std::uint32_t lock_key_form_id = 0;  // XLOC: the key that opens it (0 when none is named)
    std::array<float, 3> teleport_position{};
    std::array<float, 3> teleport_rotation{};
    std::string record_type;
    std::string reference_name;
    std::string base_editor_id;
    std::string editor_id;
    std::string model_path;
    bool initially_disabled = false;  // record flag 0x0800: a script enables the reference later
    std::uint32_t enable_parent_form_id = 0;  // XESP: the reference follows this one's enabled state (0 when none)
    bool enable_parent_inverted = false;      // XESP flag 1: it is enabled while the parent is disabled
    bool is_tree = false;
    float tree_billboard_width = 0.0f;
    float tree_billboard_height = 0.0f;
    std::string tree_billboard_texture_path;
};

struct TreeBaseRecord {
    std::string model_path;
    float billboard_width = 0.0f;
    float billboard_height = 0.0f;
};

struct NpcInventoryEntry {
    std::uint32_t form_id = 0;
    std::int32_t count = 0;
};

struct CombatStyleRecord {
    std::uint32_t form_id = 0;
    std::uint8_t dodge_chance = 75;
    std::uint8_t dodge_left_right_chance = 50;
    std::uint8_t block_chance = 30;
    std::uint8_t power_attack_chance = 25;
    std::array<std::uint8_t, 5> power_attack_chances{20, 20, 20, 20, 20};
    bool has_power_attack_chance = false;
    bool has_power_attack_chances = false;
    float dodge_left_right_min_time = 0.5f;
    float dodge_left_right_max_time = 1.5f;
    float dodge_forward_min_time = 0.5f;
    float dodge_forward_max_time = 1.0f;
    float dodge_backward_min_time = 0.25f;
    float dodge_backward_max_time = 0.75f;
    bool has_advanced_data = false;
    bool advanced_enabled = false;
    bool choose_attack_using_chance = false;
    float dodge_fatigue_mod_mult = -20.0f;
    float dodge_fatigue_mod_base = 0.0f;
    float dodge_under_attack_mult = 1.0f;
    float dodge_not_under_attack_mult = 0.75f;
    float dodge_back_under_attack_mult = 1.0f;
    float dodge_back_not_under_attack_mult = 0.7f;
    float dodge_forward_while_attacking_mult = 1.0f;
    float dodge_forward_not_attacking_mult = 0.5f;
    float block_skill_modifier_mult = 20.0f;
    float block_skill_modifier_base = 0.0f;
    float block_under_attack_mult = 2.0f;
    float block_not_under_attack_mult = 1.0f;
};

struct SpellEffectRecord {
    std::string code;
    std::uint32_t magnitude = 0;
    std::uint32_t area = 0;
    std::uint32_t duration = 0;
    std::uint32_t range_type = 0; // EFIT: 0 Self, 1 Touch, 2 Target
    std::int32_t actor_value = -1;
    std::uint32_t magic_effect_flags = 0; // MGEF DATA flags
    std::uint32_t magic_school = 0; // Alteration through Restoration
    float base_cost = 0.0f;
};

// The WEAP DATA subrecord: how the weapon is held (and so which first-person clips play) and how fast and far it swings.
struct WeaponRecord {
    // 0 blade one hand, 1 blade two hand, 2 blunt one hand, 3 blunt two hand, 4 staff, 5 bow.
    std::uint32_t weapon_type = 0;
    float speed = 1.0f;
    float reach = 1.0f;
    std::uint32_t flags = 0;
    std::uint16_t damage = 0;
};

struct SpellRecord {
    std::uint32_t form_id = 0;
    std::uint8_t spell_type = 0;
    std::uint32_t cost = 0;
    std::uint8_t level = 0;
    std::uint8_t flags = 0;
    std::vector<SpellEffectRecord> effects;
};

struct NpcBaseRecord {
    std::uint32_t form_id = 0;
    std::uint32_t script_form_id = 0;  // SCRI: the script attached to every actor of this base
    std::uint32_t class_form_id = 0;
    std::string editor_id;
    std::string name;
    std::uint32_t flags = 0;
    std::uint16_t base_magicka = 0;
    std::uint16_t base_fatigue = 0;
    std::int16_t level_or_offset = 0;
    std::uint32_t base_health = 0;
    std::array<std::uint8_t, 21> skills{};
    std::array<std::uint8_t, 8> attributes{};
    bool has_actor_values = false;
    std::uint32_t race_form_id = 0;
    std::uint32_t combat_style_form_id = 0;
    std::uint32_t hair_form_id = 0;
    std::uint32_t eye_form_id = 0;
    std::uint32_t default_outfit_form_id = 0;
    std::array<std::uint8_t, 4> hair_color{};
    std::vector<float> face_symmetric;
    std::vector<float> face_asymmetric;
    std::vector<float> face_texture_coefficients;
    std::vector<std::uint8_t> face_texture;
    std::vector<NpcInventoryEntry> inventory;
    std::vector<std::uint32_t> spell_form_ids;
    std::vector<std::uint32_t> ai_package_form_ids;
    // AIDT: how readily the actor starts a fight (0 never, 100 frenzied) and how long it stands its ground.
    std::uint8_t aggression = 0;
    std::uint8_t confidence = 50;
    // SNAM: the factions the actor belongs to, with its rank in each.
    std::vector<std::pair<std::uint32_t, std::int8_t>> factions;
};

struct CreatureBaseRecord {
    std::uint32_t form_id = 0;
    std::uint32_t script_form_id = 0;
    std::string editor_id;
    std::string name;
    std::string model_path;                    // MODL: the skeleton NIF
    std::vector<std::string> body_part_paths;  // NIFZ: the skin NIFs attached to the skeleton
    std::vector<std::string> animation_files;  // KFFZ: extra clip names next to the skeleton
    std::uint32_t flags = 0;                   // ACBS flags: Essential, Respawn, Walks, Flies, Swims, ...
    std::uint16_t base_magicka = 0;
    std::uint16_t base_fatigue = 0;
    std::int16_t level_or_offset = 0;
    // DATA: 0 animal, 1 creature, 2 daedra, 3 undead, 4 humanoid, 5 horse, 6 giant.
    std::uint8_t creature_type = 0;
    std::uint8_t combat_skill = 0;
    std::uint16_t base_health = 0;
    std::uint16_t attack_damage = 0;
    std::array<std::uint8_t, 8> attributes{};
    std::uint32_t combat_style_form_id = 0;
    float base_scale = 1.0f;     // BNAM
    float attack_reach = 0.0f;   // RNAM, in game units
    std::uint8_t aggression = 0;
    std::uint8_t confidence = 50;
    std::vector<std::uint32_t> spell_form_ids;
    std::vector<std::uint32_t> ai_package_form_ids;
    std::vector<std::pair<std::uint32_t, std::int8_t>> factions;
};

struct RaceFaceGenRecord {
    std::uint32_t form_id = 0;
    std::string display_name;
    std::uint32_t voice_form_id_male = 0;
    std::uint32_t voice_form_id_female = 0;
    std::vector<float> face_symmetric;
    std::vector<float> face_asymmetric;
    std::vector<float> face_texture_coefficients;
    struct Part {
        std::string model_path;
        std::string texture_path;
    };
    std::array<Part, 9> head_parts_male{};
    std::array<Part, 9> head_parts_female{};
    std::array<Part, 5> body_parts_male{};
    std::array<Part, 5> body_parts_female{};
};

struct OutfitRecord {
    std::uint32_t form_id = 0;
    std::string editor_id;
    std::vector<std::uint32_t> item_form_ids;
};

struct AiPackageRecord {
    std::uint32_t form_id = 0;
    std::string editor_id;
    std::uint32_t flags = 0;
    std::uint8_t package_type = 0;
    std::int32_t location_type = -1;
    std::uint32_t location_form_id = 0;
    std::int32_t location_radius = 0;
    std::int32_t target_type = -1;
    std::uint32_t target_form_id = 0;
    std::int32_t target_distance = 0;
    std::vector<QuestCondition> conditions;  // CTDA: the package starts only when these hold
};

struct PathgridRecord {
    std::uint32_t form_id = 0;
    std::uint32_t cell_form_id = 0;
    std::vector<std::array<float, 3>> points;
    std::vector<std::pair<std::uint32_t, std::uint32_t>> edges;
};

// An IDLE record: a node of the idle animation tree. MODL is the .kf file of an animation, or a folder
// (no ".kf") that only groups its children; ANAM is the animation group (4 special idle, 5 whole body, ...,
// 0x80 no return file); DATA is the parent and the previous sibling (both 0 when there is none).
struct IdleRecord {
    std::uint32_t form_id = 0;
    std::string editor_id;
    std::string animation_file;
    std::uint8_t group_flags = 0;
    std::uint32_t parent_form_id = 0;
    std::uint32_t previous_sibling_form_id = 0;
    std::vector<QuestCondition> conditions;  // CTDA (and the older 20-byte CTDT)
    [[nodiscard]] bool is_folder() const;    // no .kf file: the node only groups its children
};

struct CellRecord {
    std::uint32_t form_id = 0;
    std::uint32_t worldspace_form_id = 0;
    std::string editor_id;
    std::string display_name;
    bool interior = true;
    bool exterior_grid_cell = false;
    bool has_grid = false;
    bool has_water_level = false;
    bool has_worldspace_water_level = false;
    std::int32_t grid_x = 0;
    std::int32_t grid_y = 0;
    float water_height = 0.0f;
    float worldspace_water_height = 0.0f;
    std::vector<float> land_heights;
    std::uint32_t land_texture_form_id = 0;
    std::string land_texture_path;
    std::vector<PlacedReference> references;
};

class Esm4Database {
public:
    void open(const std::filesystem::path& path, bool runtime_visuals_only = false);
    [[nodiscard]] const CellRecord* find_cell(std::string_view editor_id) const;
    [[nodiscard]] const CellRecord* find_cell(std::uint32_t form_id) const;
    // The cell a placed reference lies in, or 0 when the form is not a placed reference.
    [[nodiscard]] std::uint32_t cell_of_reference(std::uint32_t reference_form_id) const {
        const auto found = cell_by_reference_id_.find(reference_form_id);
        return found == cell_by_reference_id_.end() ? 0u : found->second;
    }
    [[nodiscard]] const NpcBaseRecord* find_npc_base(std::uint32_t form_id) const;
    [[nodiscard]] const CreatureBaseRecord* find_creature_base(std::uint32_t form_id) const;
    [[nodiscard]] const CombatStyleRecord* find_combat_style(std::uint32_t form_id) const;
    [[nodiscard]] const SpellRecord* find_spell(std::uint32_t form_id) const;
    [[nodiscard]] const WeaponRecord* find_weapon(std::uint32_t form_id) const;
    [[nodiscard]] const RaceFaceGenRecord* find_race_face_gen(std::uint32_t form_id) const;
    [[nodiscard]] const std::string* find_race_voice_folder(std::uint32_t form_id, bool female) const;
    [[nodiscard]] const OutfitRecord* find_outfit(std::uint32_t form_id) const;
    [[nodiscard]] const AiPackageRecord* find_ai_package(std::uint32_t form_id) const;
    [[nodiscard]] const PathgridRecord* find_pathgrid(std::uint32_t cell_form_id) const;
    [[nodiscard]] const IdleRecord* find_idle(std::uint32_t form_id) const;
    // The children of an idle node (0: the roots), in sibling order (each follows its previous sibling).
    [[nodiscard]] const std::vector<const IdleRecord*>& idle_children(std::uint32_t parent_form_id) const;
    [[nodiscard]] std::size_t idle_count() const noexcept { return idle_by_id_.size(); }
    [[nodiscard]] const std::string* find_item_model_path(std::uint32_t form_id, bool female) const;
    [[nodiscard]] const std::string* find_world_item_model_path(std::uint32_t form_id, bool female) const;
    [[nodiscard]] std::uint16_t find_item_biped_slots(std::uint32_t form_id) const;
    [[nodiscard]] std::uint32_t find_form_id_by_editor_id(std::string_view editor_id) const;
    [[nodiscard]] std::vector<std::uint32_t> find_form_ids_by_editor_id_prefix(std::string_view prefix) const;
    [[nodiscard]] const std::string* find_editor_id(std::uint32_t form_id) const;
    [[nodiscard]] const std::string* find_record_type(std::uint32_t form_id) const;
    [[nodiscard]] const std::string* find_record_display_name(std::uint32_t form_id) const;
    [[nodiscard]] const std::string* find_record_icon_path(std::uint32_t form_id) const;
    [[nodiscard]] const ScriptRecord* find_script(std::uint32_t form_id) const;
    [[nodiscard]] const ScriptRecord* find_script(std::string_view editor_id) const;
    [[nodiscard]] const std::map<std::uint32_t, ScriptRecord>& scripts() const noexcept { return script_by_id_; }
    [[nodiscard]] const QuestRecord* find_quest(std::uint32_t form_id) const;
    // The initial value (FLTV) of a GLOB record, or nullopt when there is no such global.
    [[nodiscard]] std::optional<float> find_global_value(std::uint32_t form_id) const;
    [[nodiscard]] const DialogTopic* find_topic(std::uint32_t form_id) const;
    [[nodiscard]] const std::map<std::uint32_t, DialogTopic>& topics() const noexcept { return topic_by_id_; }
    [[nodiscard]] const std::vector<std::uint32_t>& topic_order() const noexcept { return topic_order_; }
    [[nodiscard]] const std::map<std::uint32_t, QuestRecord>& quests() const noexcept { return quest_by_id_; }
    [[nodiscard]] const QuestRecord* find_quest(std::string_view editor_id) const;
    [[nodiscard]] const std::vector<CellRecord>& cells() const noexcept { return cells_; }
    [[nodiscard]] std::size_t record_count() const noexcept { return record_count_; }
    // References whose owning cell never appeared in the file. They are kept
    // out of every cell rather than dropped silently, and counted here.
    [[nodiscard]] std::size_t unplaced_reference_count() const noexcept { return unplaced_reference_count_; }
    // Form ID and owning cell ID (0 when the reference had no cell) of each reference that is not in any cell.
    [[nodiscard]] const std::vector<std::pair<std::uint32_t, std::uint32_t>>& unplaced_references() const noexcept { return unplaced_references_; }
    [[nodiscard]] const std::map<std::string, float>& float_game_settings() const noexcept { return float_game_settings_; }
    [[nodiscard]] std::optional<float> find_float_game_setting(std::string_view name) const;
    [[nodiscard]] const std::map<std::string, std::int32_t>& integer_game_settings() const noexcept { return integer_game_settings_; }
    [[nodiscard]] std::optional<std::int32_t> find_integer_game_setting(std::string_view name) const;
    [[nodiscard]] const std::filesystem::path& path() const noexcept { return path_; }

private:
    std::filesystem::path path_;
    std::vector<CellRecord> cells_;
    std::map<std::uint32_t, std::size_t> cell_by_id_;
    std::map<std::uint32_t, std::string> base_model_by_id_;
    std::map<std::uint32_t, std::string> base_editor_id_by_id_;
    std::map<std::uint32_t, std::string> record_display_name_by_id_;
    std::map<std::uint32_t, std::string> record_icon_path_by_id_;
    std::map<std::uint32_t, std::uint32_t> script_form_id_by_id_;
    std::map<std::string, std::uint32_t> form_id_by_editor_id_;
    std::map<std::uint32_t, NpcBaseRecord> npc_by_id_;
    std::map<std::uint32_t, CreatureBaseRecord> creature_by_id_;
    std::map<std::uint32_t, CombatStyleRecord> combat_style_by_id_;
    std::map<std::uint32_t, SpellRecord> spell_by_id_;
    std::map<std::uint32_t, WeaponRecord> weapon_by_id_;
    std::map<std::uint32_t, RaceFaceGenRecord> race_face_gen_by_id_;
    std::map<std::uint32_t, OutfitRecord> outfit_by_id_;
    std::map<std::uint32_t, AiPackageRecord> ai_package_by_id_;
    std::map<std::uint32_t, PathgridRecord> pathgrid_by_cell_id_;
    std::map<std::uint32_t, IdleRecord> idle_by_id_;
    std::map<std::uint32_t, std::vector<const IdleRecord*>> idle_children_by_parent_;
    std::map<std::uint32_t, TreeBaseRecord> tree_by_id_;
    std::map<std::uint32_t, std::string> item_model_by_id_;
    std::map<std::uint32_t, std::string> female_item_model_by_id_;
    std::map<std::uint32_t, std::string> world_item_model_by_id_;
    std::map<std::uint32_t, std::string> female_world_item_model_by_id_;
    std::map<std::uint32_t, std::uint16_t> item_biped_slots_by_id_;
    std::map<std::uint32_t, std::string> land_texture_path_by_id_;
    std::map<std::uint32_t, float> worldspace_water_level_by_id_;
    std::map<std::string, std::size_t> cell_by_editor_id_;
    std::map<std::uint32_t, std::size_t> record_type_by_id_;
    std::vector<std::string> record_type_names_;
    std::map<std::string, std::size_t, std::less<>> record_type_index_;
    std::map<std::uint32_t, std::vector<PlacedReference>> references_by_cell_id_;
    std::map<std::uint32_t, std::uint32_t> cell_by_reference_id_;
    std::map<std::uint32_t, ScriptRecord> script_by_id_;
    std::map<std::uint32_t, QuestRecord> quest_by_id_;
    std::map<std::string, std::uint32_t> quest_id_by_editor_id_;
    std::map<std::string, std::uint32_t> script_id_by_editor_id_;
    std::map<std::string, float> float_game_settings_;
    std::map<std::string, std::int32_t> integer_game_settings_;
    struct MagicEffectRecord {
        std::uint32_t flags = 0;
        std::uint32_t school = 0;
        float base_cost = 0.0f;
    };
    std::map<std::string, MagicEffectRecord, std::less<>> magic_effect_by_code_;
    std::map<std::uint32_t, float> global_value_by_id_;
    std::size_t record_count_ = 0;
    std::size_t unplaced_reference_count_ = 0;
    std::vector<std::pair<std::uint32_t, std::uint32_t>> unplaced_references_;
    std::map<std::uint32_t, DialogTopic> topic_by_id_;
    std::vector<std::uint32_t> topic_order_;
    std::map<std::uint32_t, std::vector<DialogResponse>> responses_by_topic_;
    std::uint32_t active_topic_id_ = 0;  // topic of the INFO group being walked

    void parse_file(const std::vector<std::uint8_t>& bytes, bool runtime_visuals_only);
    void attach_references();
    void build_idle_tree();
    void parse_record(std::string_view type, std::uint32_t form_id, std::uint32_t flags,
                      std::uint32_t active_cell_id, std::uint32_t worldspace_form_id,
                      bool exterior_grid_context, const std::uint8_t* data, std::size_t data_size);
    [[nodiscard]] std::size_t intern_record_type(std::string_view type);
};

} // namespace oblivion
