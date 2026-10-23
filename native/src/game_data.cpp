#include "oblivion/game_data.hpp"

#include <algorithm>
#include <array>
#include <cctype>
#include <chrono>
#include <fstream>
#include <map>
#include <ostream>
#include <stdexcept>
#include <system_error>

namespace oblivion {

const DialogTopic* GameData::find_topic_by_editor_id(std::string_view editor_id) const {
    for (const auto& [form_id, topic] : esm_.topics())
        if (topic.editor_id == editor_id) return &topic;
    return nullptr;
}
namespace {

std::string lower_ascii(std::string value) {
    std::transform(value.begin(), value.end(), value.begin(), [](unsigned char c) {
        return static_cast<char>(std::tolower(c));
    });
    return value;
}

// Calls visit(component) for each backslash-separated part of a normalized path.
template <typename Visit>
void for_each_component(std::string_view path, Visit visit) {
    std::size_t begin = 0;
    while (begin <= path.size()) {
        const auto end = path.find('\\', begin);
        const auto length = end == std::string_view::npos ? path.size() - begin : end - begin;
        if (length > 0) visit(path.substr(begin, length));
        if (end == std::string_view::npos) break;
        begin = end + 1;
    }
}

bool has_parent_component(std::string_view normalized) {
    bool escapes = false;
    for_each_component(normalized, [&](std::string_view component) {
        if (component == "..") escapes = true;
    });
    return escapes;
}

// Indexes every loose file under root by its lowercase, backslash-separated
// path relative to root. Lookups are then case-insensitive on any volume,
// including case-sensitive ones where the on-disk directory names are mixed case.
// The tree is walked one directory at a time, so a directory that cannot be listed or whose iteration fails
// midway loses only its own remaining entries (reported to `log`), not the rest of the tree.
std::map<std::string, std::filesystem::path, std::less<>> index_loose_files(const std::filesystem::path& root,
                                                                           std::ostream* log) {
    namespace fs = std::filesystem;
    std::map<std::string, fs::path, std::less<>> index;
    std::vector<fs::path> pending{root};
    const auto report = [log](const fs::path& where, const std::error_code& error) {
        if (log) *log << "OpenOB data index: loose files under " << where.string() << " skipped: " << error.message() << '\n';
    };
    while (!pending.empty()) {
        const auto directory = std::move(pending.back());
        pending.pop_back();
        std::error_code error;
        fs::directory_iterator it(directory, fs::directory_options::skip_permission_denied, error);
        if (error) {
            report(directory, error);
            continue;
        }
        const fs::directory_iterator end;
        while (it != end) {
            std::error_code entry_error;
            const auto& entry = *it;
            // Symbolic links to directories are not followed, as a recursive walk would not, so a link cycle ends.
            const auto link_status = entry.symlink_status(entry_error);
            if (!entry_error && link_status.type() == fs::file_type::directory) {
                pending.push_back(entry.path());
            } else if (entry.is_regular_file(entry_error) && !entry_error) {
                std::string key;
                for (const auto& part : entry.path().lexically_relative(root)) {
                    if (!key.empty()) key.push_back('\\');
                    key += lower_ascii(part.string());
                }
                // Files that differ only by case map to one key; the lexicographically smallest
                // on-disk path wins so the result does not depend on directory order.
                const auto [slot, inserted] = index.emplace(std::move(key), entry.path());
                if (!inserted && entry.path().string() < slot->second.string()) slot->second = entry.path();
            }
            // A failed increment leaves this directory's iterator unusable: the rest of this directory is skipped
            // and reported, and the other directories are still walked.
            std::error_code step_error;
            it.increment(step_error);
            if (step_error) {
                report(directory, step_error);
                break;
            }
        }
    }
    return index;
}

} // namespace

void GameData::open(const std::filesystem::path& data_directory, LoadProfile profile, std::ostream* log) {
    const auto startup_started = std::chrono::steady_clock::now();
    const bool visual_runtime = profile == LoadProfile::RuntimeVisuals;
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
    const auto discovered_archive_count = bsa_paths.size();
    if (visual_runtime) {
        // Runtime audio and dialogue are streamed from the original archives alongside visual assets.
        constexpr std::array<std::string_view, 3> visual_archives = {
            "oblivion - meshes.bsa",
            "oblivion - textures - compressed.bsa",
            "oblivion - misc.bsa",
        };
        std::erase_if(bsa_paths, [&visual_archives](const auto& path) {
            const auto filename = lower_ascii(path.filename().string());
            const bool visual_archive = std::find(visual_archives.begin(), visual_archives.end(), filename) != visual_archives.end();
            const bool audio_archive = filename.ends_with(" - sounds.bsa") || filename.starts_with("oblivion - voices");
            return not visual_archive && not audio_archive;
        });
    }

    const auto archives_started = std::chrono::steady_clock::now();
    std::vector<BsaArchive> archives;
    std::vector<std::filesystem::path> archive_paths;
    for (const auto& bsa_path : bsa_paths) {
        BsaArchive archive;
        archive.open(bsa_path);
        archives.push_back(std::move(archive));
        archive_paths.push_back(bsa_path);
    }
    const auto archives_finished = std::chrono::steady_clock::now();

    Esm4Database esm;
    esm.open(esm_path, visual_runtime);
    const auto startup_finished = std::chrono::steady_clock::now();
    if (log) {
        const std::chrono::duration<double> archive_duration = archives_finished - archives_started;
        const std::chrono::duration<double> esm_duration = startup_finished - archives_finished;
        const std::chrono::duration<double> total_duration = startup_finished - startup_started;
        *log << "OpenOB data index: " << archive_paths.size() << "/" << discovered_archive_count
             << " BSA archives in " << archive_duration.count() << "s; ESM in "
             << esm_duration.count() << "s; total " << total_duration.count() << "s"
             << (visual_runtime ? " (runtime visuals profile)" : " (full profile)") << '\n';
        if (esm.unplaced_reference_count() > 0)
            *log << "OpenOB data index: " << esm.unplaced_reference_count()
                 << " references have no owning cell in " << esm_path.string() << '\n';
    }
    data_directory_ = data_directory;
    loose_files_ = index_loose_files(data_directory, log);
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

const ScriptRecord* GameData::find_script(std::uint32_t form_id) const {
    return esm_.find_script(form_id);
}

const ScriptRecord* GameData::find_script(std::string_view editor_id) const {
    return esm_.find_script(editor_id);
}

std::vector<std::uint8_t> GameData::read_asset(std::string_view asset_path) const {
    if (!opened_)
        throw std::runtime_error("game data is not open");

    const auto normalized = normalize_asset_path(asset_path);
    if (has_parent_component(normalized))
        throw std::runtime_error("asset path escapes the game Data directory: " + std::string(asset_path));
    std::vector<std::string> candidates{normalized};
    const auto extension = lower_ascii(std::filesystem::path(normalized).extension().string());
    if ((extension == ".nif" || extension == ".kf") && !normalized.starts_with("meshes\\"))
        candidates.push_back("meshes\\" + normalized);

    for (const auto& candidate : candidates) {
        if (const auto loose = loose_files_.find(candidate); loose != loose_files_.end()) {
            const auto& loose_path = loose->second;
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
