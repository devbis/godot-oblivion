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
#include <string>
#include <string_view>
#include <vector>

namespace oblivion {

struct PlacedReference {
    std::uint32_t form_id = 0;
    std::uint32_t base_form_id = 0;
    std::array<float, 3> position{};
    std::array<float, 3> rotation{};
    std::uint32_t teleport_ref_id = 0;
    std::uint32_t teleport_cell_id = 0;
    std::array<float, 3> teleport_position{};
    std::array<float, 3> teleport_rotation{};
    std::string record_type;
    std::string reference_name;
    std::string base_editor_id;
    std::string editor_id;
    std::string model_path;
};

struct NpcInventoryEntry {
    std::uint32_t form_id = 0;
    std::int32_t count = 0;
};

struct NpcBaseRecord {
    std::uint32_t form_id = 0;
    std::string editor_id;
    std::string name;
    std::uint32_t flags = 0;
    std::uint32_t race_form_id = 0;
    std::uint32_t hair_form_id = 0;
    std::uint32_t eye_form_id = 0;
    std::uint32_t default_outfit_form_id = 0;
    std::array<std::uint8_t, 4> hair_color{};
    std::vector<float> face_symmetric;
    std::vector<float> face_asymmetric;
    std::vector<float> face_texture_coefficients;
    std::vector<std::uint8_t> face_texture;
    std::vector<NpcInventoryEntry> inventory;
    std::vector<std::uint32_t> ai_package_form_ids;
};

struct RaceFaceGenRecord {
    std::uint32_t form_id = 0;
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
};

struct CellRecord {
    std::uint32_t form_id = 0;
    std::string editor_id;
    std::string display_name;
    bool interior = true;
    std::int32_t grid_x = 0;
    std::int32_t grid_y = 0;
    std::vector<PlacedReference> references;
};

class Esm4Database {
public:
    void open(const std::filesystem::path& path);
    [[nodiscard]] const CellRecord* find_cell(std::string_view editor_id) const;
    [[nodiscard]] const CellRecord* find_cell(std::uint32_t form_id) const;
    [[nodiscard]] const NpcBaseRecord* find_npc_base(std::uint32_t form_id) const;
    [[nodiscard]] const RaceFaceGenRecord* find_race_face_gen(std::uint32_t form_id) const;
    [[nodiscard]] const OutfitRecord* find_outfit(std::uint32_t form_id) const;
    [[nodiscard]] const AiPackageRecord* find_ai_package(std::uint32_t form_id) const;
    [[nodiscard]] const std::string* find_item_model_path(std::uint32_t form_id, bool female) const;
    [[nodiscard]] const std::string* find_world_item_model_path(std::uint32_t form_id, bool female) const;
    [[nodiscard]] std::uint16_t find_item_biped_slots(std::uint32_t form_id) const;
    [[nodiscard]] std::uint32_t find_form_id_by_editor_id(std::string_view editor_id) const;
    [[nodiscard]] std::vector<std::uint32_t> find_form_ids_by_editor_id_prefix(std::string_view prefix) const;
    [[nodiscard]] const std::string* find_editor_id(std::uint32_t form_id) const;
    [[nodiscard]] const std::string* find_record_type(std::uint32_t form_id) const;
    [[nodiscard]] const std::vector<CellRecord>& cells() const noexcept { return cells_; }
    [[nodiscard]] std::size_t record_count() const noexcept { return record_count_; }
    [[nodiscard]] const std::map<std::string, float>& float_game_settings() const noexcept { return float_game_settings_; }
    [[nodiscard]] const std::filesystem::path& path() const noexcept { return path_; }

private:
    std::filesystem::path path_;
    std::vector<CellRecord> cells_;
    std::map<std::uint32_t, std::size_t> cell_by_id_;
    std::map<std::uint32_t, std::string> base_model_by_id_;
    std::map<std::uint32_t, std::string> base_editor_id_by_id_;
    std::map<std::string, std::uint32_t> form_id_by_editor_id_;
    std::map<std::uint32_t, NpcBaseRecord> npc_by_id_;
    std::map<std::uint32_t, RaceFaceGenRecord> race_face_gen_by_id_;
    std::map<std::uint32_t, OutfitRecord> outfit_by_id_;
    std::map<std::uint32_t, AiPackageRecord> ai_package_by_id_;
    std::map<std::uint32_t, std::string> item_model_by_id_;
    std::map<std::uint32_t, std::string> female_item_model_by_id_;
    std::map<std::uint32_t, std::string> world_item_model_by_id_;
    std::map<std::uint32_t, std::string> female_world_item_model_by_id_;
    std::map<std::uint32_t, std::uint16_t> item_biped_slots_by_id_;
    std::map<std::uint32_t, std::string> record_type_by_id_;
    std::map<std::uint32_t, std::uint32_t> cell_by_reference_id_;
    std::map<std::string, float> float_game_settings_;
    std::size_t record_count_ = 0;

    void parse_file(const std::vector<std::uint8_t>& bytes);
    void parse_record(std::string_view type, std::uint32_t form_id, std::uint32_t flags,
                      std::uint32_t active_cell_id, const std::uint8_t* data,
                      std::size_t data_size);
};

} // namespace oblivion
