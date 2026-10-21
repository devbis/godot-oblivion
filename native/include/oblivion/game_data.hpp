#pragma once

#include "oblivion/bsa_archive.hpp"
#include "oblivion/esm4_database.hpp"

#include <filesystem>
#include <optional>
#include <string>
#include <vector>

namespace oblivion {

class GameData {
public:
    enum class LoadProfile { Full, RuntimeVisuals };

    void open(const std::filesystem::path& data_directory, LoadProfile profile = LoadProfile::Full);
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
    [[nodiscard]] std::vector<std::uint8_t> read_asset(std::string_view asset_path) const;
    [[nodiscard]] bool is_open() const noexcept { return opened_; }
    [[nodiscard]] const std::filesystem::path& data_directory() const noexcept { return data_directory_; }
    [[nodiscard]] const std::vector<CellRecord>& cells() const noexcept { return esm_.cells(); }
    [[nodiscard]] std::size_t archive_count() const noexcept { return archives_.size(); }
    [[nodiscard]] std::size_t record_count() const noexcept { return esm_.record_count(); }
    [[nodiscard]] const std::map<std::string, float>& float_game_settings() const noexcept {
        return esm_.float_game_settings();
    }
    [[nodiscard]] const std::vector<std::filesystem::path>& archive_paths() const noexcept { return archive_paths_; }

private:
    std::filesystem::path data_directory_;
    Esm4Database esm_;
    std::vector<BsaArchive> archives_;
    std::vector<std::filesystem::path> archive_paths_;
    bool opened_ = false;
};

} // namespace oblivion
