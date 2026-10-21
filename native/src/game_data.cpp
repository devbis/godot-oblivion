#include "oblivion/game_data.hpp"

#include <algorithm>
#include <cctype>
#include <fstream>
#include <stdexcept>

namespace oblivion {
namespace {

std::string lower_ascii(std::string value) {
    std::transform(value.begin(), value.end(), value.begin(), [](unsigned char c) {
        return static_cast<char>(std::tolower(c));
    });
    return value;
}

} // namespace

void GameData::open(const std::filesystem::path& data_directory) {
    if (!std::filesystem::is_directory(data_directory))
        throw std::runtime_error("not a game Data directory: " + data_directory.string());

    std::filesystem::path esm_path;
    std::vector<std::filesystem::path> bsa_paths;
    for (const auto& item : std::filesystem::directory_iterator(data_directory)) {
        if (!item.is_regular_file()) continue;
        const auto extension = lower_ascii(item.path().extension().string());
        const auto filename = lower_ascii(item.path().filename().string());
        if (extension == ".esm" && filename == "oblivion.esm") esm_path = item.path();
        else if (extension == ".bsa") bsa_paths.push_back(item.path());
    }
    if (esm_path.empty())
        throw std::runtime_error("Oblivion.esm was not found in " + data_directory.string());

    std::sort(bsa_paths.begin(), bsa_paths.end(), [](const auto& a, const auto& b) {
        return lower_ascii(a.filename().string()) < lower_ascii(b.filename().string());
    });
    std::vector<BsaArchive> archives;
    std::vector<std::filesystem::path> archive_paths;
    for (const auto& bsa_path : bsa_paths) {
        BsaArchive archive;
        archive.open(bsa_path);
        archives.push_back(std::move(archive));
        archive_paths.push_back(bsa_path);
    }

    Esm4Database esm;
    esm.open(esm_path);
    data_directory_ = data_directory;
    archives_ = std::move(archives);
    archive_paths_ = std::move(archive_paths);
    esm_ = std::move(esm);
    opened_ = true;
}

const CellRecord* GameData::find_cell(std::string_view editor_id) const {
    return esm_.find_cell(editor_id);
}

const CellRecord* GameData::find_cell(std::uint32_t form_id) const {
    return esm_.find_cell(form_id);
}

const NpcBaseRecord* GameData::find_npc_base(std::uint32_t form_id) const {
    return esm_.find_npc_base(form_id);
}

const RaceFaceGenRecord* GameData::find_race_face_gen(std::uint32_t form_id) const {
    return esm_.find_race_face_gen(form_id);
}

const OutfitRecord* GameData::find_outfit(std::uint32_t form_id) const {
    return esm_.find_outfit(form_id);
}

const AiPackageRecord* GameData::find_ai_package(std::uint32_t form_id) const {
    return esm_.find_ai_package(form_id);
}

const std::string* GameData::find_item_model_path(std::uint32_t form_id, bool female) const {
    return esm_.find_item_model_path(form_id, female);
}

const std::string* GameData::find_world_item_model_path(std::uint32_t form_id, bool female) const {
    return esm_.find_world_item_model_path(form_id, female);
}

std::uint16_t GameData::find_item_biped_slots(std::uint32_t form_id) const {
    return esm_.find_item_biped_slots(form_id);
}

std::uint32_t GameData::find_form_id_by_editor_id(std::string_view editor_id) const {
    return esm_.find_form_id_by_editor_id(editor_id);
}

std::vector<std::uint32_t> GameData::find_form_ids_by_editor_id_prefix(std::string_view prefix) const {
    return esm_.find_form_ids_by_editor_id_prefix(prefix);
}

const std::string* GameData::find_editor_id(std::uint32_t form_id) const {
    return esm_.find_editor_id(form_id);
}

const std::string* GameData::find_record_type(std::uint32_t form_id) const {
    return esm_.find_record_type(form_id);
}

std::vector<std::uint8_t> GameData::read_asset(std::string_view asset_path) const {
    if (!opened_)
        throw std::runtime_error("game data is not open");

    const auto normalized = normalize_asset_path(asset_path);
    std::vector<std::string> candidates{normalized};
    const auto extension = lower_ascii(std::filesystem::path(normalized).extension().string());
    if ((extension == ".nif" || extension == ".kf") && !normalized.starts_with("meshes\\"))
        candidates.push_back("meshes\\" + normalized);

    for (const auto& candidate : candidates) {
        std::filesystem::path loose_path = data_directory_;
        std::string relative = candidate;
        std::replace(relative.begin(), relative.end(), '\\', std::filesystem::path::preferred_separator);
        loose_path /= relative;
        if (std::filesystem::is_regular_file(loose_path)) {
            std::ifstream input(loose_path, std::ios::binary | std::ios::ate);
            const auto size = input.tellg();
            if (size < 0) throw std::runtime_error("cannot size " + loose_path.string());
            std::vector<std::uint8_t> bytes(static_cast<std::size_t>(size));
            input.seekg(0);
            if (!bytes.empty()) input.read(reinterpret_cast<char*>(bytes.data()), static_cast<std::streamsize>(bytes.size()));
            if (!input) throw std::runtime_error("cannot read " + loose_path.string());
            return bytes;
        }
        for (auto it = archives_.rbegin(); it != archives_.rend(); ++it) {
            if (it->contains(candidate)) return it->read(candidate);
        }
    }
    throw std::runtime_error("asset not found: " + std::string(asset_path));
}

} // namespace oblivion
