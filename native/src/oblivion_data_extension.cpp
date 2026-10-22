#include "oblivion/command_table.hpp"
#include "oblivion/game_data.hpp"
#include "oblivion/nif_mesh.hpp"
#include "oblivion/quest_driver.hpp"
#include "oblivion/quest_stage.hpp"

#include <godot_cpp/classes/ref.hpp>
#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>
#include <godot_cpp/variant/packed_string_array.hpp>
#include <godot_cpp/variant/packed_vector2_array.hpp>
#include <godot_cpp/variant/packed_vector3_array.hpp>
#include <godot_cpp/variant/string.hpp>
#include <godot_cpp/variant/utility_functions.hpp>
#include <godot_cpp/godot.hpp>

#include <algorithm>
#include <array>
#include <atomic>
#include <bit>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <memory>
#include <mutex>
#include <stdexcept>
#include <thread>
#include <unordered_set>

namespace godot {
namespace {

PackedFloat32Array as_packed_coefficients(const std::vector<float>& coefficients) {
    PackedFloat32Array result;
    result.resize(static_cast<int64_t>(coefficients.size()));
    for (int64_t i = 0; i < static_cast<int64_t>(coefficients.size()); ++i)
        result.set(i, coefficients[static_cast<std::size_t>(i)]);
    return result;
}

PackedFloat32Array add_face_coefficients(const std::vector<float>& race,
                                         const std::vector<float>& individual) {
    const auto count = std::max(race.size(), individual.size());
    PackedFloat32Array result;
    result.resize(static_cast<int64_t>(count));
    for (int64_t i = 0; i < static_cast<int64_t>(count); ++i) {
        const auto index = static_cast<std::size_t>(i);
        result.set(i, (index < race.size() ? race[index] : 0.0f)
            + (index < individual.size() ? individual[index] : 0.0f));
    }
    return result;
}

template <std::size_t Size>
Array race_parts_to_array(const std::array<oblivion::RaceFaceGenRecord::Part, Size>& parts) {
    Array result;
    for (const auto& part : parts) {
        Dictionary item;
        item["model_path"] = String::utf8(part.model_path.c_str());
        item["texture_path"] = String::utf8(part.texture_path.c_str());
        result.push_back(item);
    }
    return result;
}

template <std::size_t Size>
bool has_race_parts(const std::array<oblivion::RaceFaceGenRecord::Part, Size>& parts) {
    return std::any_of(parts.begin(), parts.end(), [](const auto& part) {
        return !part.model_path.empty() || !part.texture_path.empty();
    });
}

const std::vector<float>& race_shape_coefficients(const oblivion::RaceFaceGenRecord* race, bool symmetric) {
    static const std::vector<float> empty;
    if (!race) return empty;
    return symmetric ? race->face_symmetric : race->face_asymmetric;
}

std::uint32_t read_u32_le(const std::uint8_t* bytes) {
    return static_cast<std::uint32_t>(bytes[0])
        | (static_cast<std::uint32_t>(bytes[1]) << 8)
        | (static_cast<std::uint32_t>(bytes[2]) << 16)
        | (static_cast<std::uint32_t>(bytes[3]) << 24);
}

PackedByteArray apply_facegen_texture(const PackedByteArray& image_data, std::int64_t width,
                                     std::int64_t height, const PackedByteArray& egt_data,
                                     const PackedFloat32Array& coefficients) {
    constexpr std::size_t header_size = 64;
    if (width <= 0 || height <= 0 || egt_data.size() < static_cast<std::int64_t>(header_size)) return {};
    const auto* egt = egt_data.ptr();
    if (std::string_view(reinterpret_cast<const char*>(egt), 8) != "FREGT003") return {};

    const std::uint32_t rows = read_u32_le(egt + 8);
    const std::uint32_t columns = read_u32_le(egt + 12);
    const std::uint32_t symmetric_count = read_u32_le(egt + 16);
    const std::uint32_t asymmetric_count = read_u32_le(egt + 20);
    if (rows == 0 || columns == 0 || rows % static_cast<std::uint32_t>(height) != 0
        || columns % static_cast<std::uint32_t>(width) != 0
        || symmetric_count > 256 || asymmetric_count > 256) return {};

    const std::size_t pixels = static_cast<std::size_t>(width) * static_cast<std::size_t>(height);
    const std::size_t egt_pixels = static_cast<std::size_t>(rows) * columns;
    const std::size_t scale_y = rows / static_cast<std::uint32_t>(height);
    const std::size_t scale_x = columns / static_cast<std::uint32_t>(width);
    const std::size_t sample_count = scale_x * scale_y;
    const std::size_t mode_size = sizeof(float) + egt_pixels * 3;
    const std::size_t mode_count = static_cast<std::size_t>(symmetric_count) + asymmetric_count;
    if (pixels > static_cast<std::size_t>(image_data.size()) / 4
        || header_size + mode_count * mode_size != static_cast<std::size_t>(egt_data.size())
        || coefficients.is_empty()) return {};

    const auto coefficient_count = std::min<std::size_t>(symmetric_count, coefficients.size());
    std::vector<float> deltas(pixels * 3, 0.0f);
    for (std::size_t mode = 0; mode < coefficient_count; ++mode) {
        const std::size_t mode_offset = header_size + mode * mode_size;
        const float scale = std::bit_cast<float>(read_u32_le(egt + mode_offset));
        const float weight = coefficients[static_cast<std::int64_t>(mode)] * scale;
        if (!std::isfinite(weight) || std::abs(weight) < 0.000001f) continue;
        const auto* mode_deltas = egt + mode_offset + sizeof(float);
        const auto* red = mode_deltas;
        const auto* green = mode_deltas + egt_pixels;
        const auto* blue = mode_deltas + egt_pixels * 2;
        for (std::size_t y = 0; y < static_cast<std::size_t>(height); ++y) {
            for (std::size_t x = 0; x < static_cast<std::size_t>(width); ++x) {
                const std::size_t image_pixel = y * static_cast<std::size_t>(width) + x;
                std::array<float, 3> average_delta{};
                for (std::size_t dy = 0; dy < scale_y; ++dy) {
                    const std::size_t egt_row = static_cast<std::size_t>(rows) - (y * scale_y + dy) - 1;
                    for (std::size_t dx = 0; dx < scale_x; ++dx) {
                        const std::size_t egt_pixel = egt_row * columns + x * scale_x + dx;
                        average_delta[0] += static_cast<std::int8_t>(red[egt_pixel]);
                        average_delta[1] += static_cast<std::int8_t>(green[egt_pixel]);
                        average_delta[2] += static_cast<std::int8_t>(blue[egt_pixel]);
                    }
                }
                for (std::size_t channel = 0; channel < 3; ++channel)
                    deltas[image_pixel * 3 + channel] += average_delta[channel] / static_cast<float>(sample_count) * weight;
            }
        }
    }

    PackedByteArray result = image_data;
    auto* output = result.ptrw();
    const auto* source = image_data.ptr();
    for (std::size_t pixel = 0; pixel < pixels; ++pixel) {
        for (std::size_t channel = 0; channel < 3; ++channel) {
            const float value = static_cast<float>(source[pixel * 4 + channel]) + deltas[pixel * 3 + channel];
            output[pixel * 4 + channel] = static_cast<std::uint8_t>(std::clamp(std::lround(value), 0l, 255l));
        }
    }
    return result;
}

} // namespace

// Text and action conversions shared by the data object and the quest driver.
String utf8_text(const std::string& value) { return String::utf8(value.c_str()); }

Dictionary action_to_dictionary(const oblivion::ScriptAction& action) {
    Dictionary item;
    item["command"] = utf8_text(action.command);
    item["target"] = utf8_text(action.target);
    Array arguments;
    for (const auto& argument : action.arguments)
        arguments.push_back(argument.is_text ? Variant(utf8_text(argument.text)) : Variant(argument.number));
    item["arguments"] = arguments;
    return item;
}

// Forward declaration: the driver class is defined after the data class that creates it.
class OblivionQuestWorld;

class OblivionData final : public RefCounted {
    GDCLASS(OblivionData, RefCounted)

public:
    ~OblivionData() override {
        if (worker_.joinable()) worker_.join();
    }

    void open_game_async(const String& data_directory) {
        if (loading_.load()) return;
        if (worker_.joinable()) worker_.join();
        const CharString utf8_path = data_directory.utf8();
        const std::string path(utf8_path.get_data());
        {
            std::lock_guard<std::mutex> lock(state_mutex_);
            data_.reset();
            error_.clear();
        }
        loading_.store(true);
        worker_ = std::thread([this, path]() {
            try {
                auto data = std::make_unique<oblivion::GameData>();
                data->open(path, oblivion::GameData::LoadProfile::RuntimeVisuals);
                std::lock_guard<std::mutex> lock(state_mutex_);
                data_ = std::move(data);
            } catch (const std::exception& error) {
                std::lock_guard<std::mutex> lock(state_mutex_);
                error_ = error.what();
            }
            loading_.store(false);
        });
    }

    bool is_loading() const { return loading_.load(); }

    bool is_ready() const {
        if (loading_.load()) return false;
        std::lock_guard<std::mutex> lock(state_mutex_);
        return data_ != nullptr;
    }

    String get_error() const {
        std::lock_guard<std::mutex> lock(state_mutex_);
        return String::utf8(error_.c_str());
    }

    Dictionary get_summary() const {
        Dictionary result;
        std::lock_guard<std::mutex> lock(state_mutex_);
        if (!data_) return result;
        result["data_directory"] = String::utf8(data_->data_directory().string().c_str());
        result["cell_count"] = static_cast<int64_t>(data_->cells().size());
        result["record_count"] = static_cast<int64_t>(data_->record_count());
        result["archive_count"] = static_cast<int64_t>(data_->archive_count());
        return result;
    }

    Array list_cells() const {
        Array result;
        std::lock_guard<std::mutex> lock(state_mutex_);
        if (!data_) return result;
        for (const auto& cell : data_->cells()) result.push_back(cell_to_dictionary(cell));
        return result;
    }

    Dictionary find_exterior_region(int64_t grid_x, int64_t grid_y,
                                    int64_t worldspace_form_id, int64_t radius,
                                    int64_t static_reference_radius = -1,
                                    int64_t tree_reference_radius = -1) const {
        std::lock_guard<std::mutex> lock(state_mutex_);
        if (!data_) return {};
        const auto& cells = data_->cells();
        const oblivion::CellRecord* center = nullptr;
        for (const auto& cell : cells) {
            if (cell.exterior_grid_cell && !cell.interior && cell.has_grid
                && cell.worldspace_form_id == static_cast<std::uint32_t>(worldspace_form_id)
                && cell.grid_x == grid_x && cell.grid_y == grid_y) {
                center = &cell;
                break;
            }
        }
        if (!center) return {};

        const auto range = std::max<int64_t>(0, std::min<int64_t>(radius, 12));
        const auto static_range = std::max<int64_t>(0, std::min<int64_t>(
            static_reference_radius < 0 ? range : static_reference_radius, 12));
        const auto tree_range = std::max<int64_t>(0, std::min<int64_t>(
            tree_reference_radius < 0 ? range : tree_reference_radius, 12));
        Dictionary result = cell_to_dictionary(*center);
        Array references;
        Array land_cells;
        Array water_cells;
        std::unordered_set<std::uint32_t> seen_references;
        for (const auto& cell : cells) {
            if (cell.worldspace_form_id != center->worldspace_form_id) continue;
            if (cell.exterior_grid_cell && !cell.interior && cell.has_grid
                && std::abs(static_cast<int64_t>(cell.grid_x) - grid_x) <= range
                && std::abs(static_cast<int64_t>(cell.grid_y) - grid_y) <= range) {
                if (cell.land_heights.size() == 33 * 33) {
                    Dictionary land;
                    land["grid_x"] = cell.grid_x;
                    land["grid_y"] = cell.grid_y;
                    PackedFloat32Array heights;
                    heights.resize(static_cast<int64_t>(cell.land_heights.size()));
                    for (int64_t i = 0; i < heights.size(); ++i)
                        heights.set(i, cell.land_heights[static_cast<std::size_t>(i)]);
                    land["heights"] = heights;
                    land["texture_path"] = as_string(cell.land_texture_path);
                    land_cells.push_back(land);
                }
                if (cell.has_water_level || center->has_worldspace_water_level) {
                    Dictionary water;
                    water["grid_x"] = cell.grid_x;
                    water["grid_y"] = cell.grid_y;
                    water["height"] = cell.has_water_level
                        ? cell.water_height : center->worldspace_water_height;
                    water_cells.push_back(water);
                }
            }
            for (const auto& reference : cell.references) {
                const auto reference_grid_x = static_cast<int64_t>(std::floor(reference.position[0] / 4096.0f));
                const auto reference_grid_y = static_cast<int64_t>(std::floor(reference.position[1] / 4096.0f));
                const auto reference_range = reference.is_tree ? tree_range : static_range;
                if (std::abs(reference_grid_x - grid_x) > reference_range
                    || std::abs(reference_grid_y - grid_y) > reference_range
                    || !seen_references.insert(reference.form_id).second)
                    continue;
                references.push_back(reference_to_dictionary(reference));
            }
        }
        result["references"] = references;
        result["land_cells"] = land_cells;
        result["water_cells"] = water_cells;
        result["display_name"] = String("Exterior (") + String::num_int64(grid_x)
            + ", " + String::num_int64(grid_y) + ")";
        return result;
    }

    // Runs one stage of a quest and returns { "error": String, "runs": Array } where each run
    // describes an entry: whether its conditions hold, its log text, and the actions it requests.
    // The quests of the loaded game, every one with a script, running together. It keeps a reference to this
    // data so the records it reads stay alive. Returns null when the command table cannot be read.
    Ref<OblivionQuestWorld> create_quest_world(const String& executable_path, const String& cache_dir) const;

    const oblivion::GameData* game_data() const {
        std::lock_guard<std::mutex> lock(state_mutex_);
        return data_.get();
    }

    Dictionary run_quest_stage(const String& quest_editor_id, int64_t stage, const String& executable_path,
                               const String& cache_dir) const {
        Dictionary result;
        Array runs;
        result["runs"] = runs;
        result["error"] = String();
        const CharString quest_value = quest_editor_id.utf8();
        const CharString executable_value = executable_path.utf8();
        const CharString cache_value = cache_dir.utf8();
        std::lock_guard<std::mutex> lock(state_mutex_);
        if (!data_) {
            result["error"] = String("game data is not loaded");
            return result;
        }
        const auto* quest = data_->find_quest(quest_value.get_data());
        if (!quest) {
            result["error"] = String("quest not found");
            return result;
        }
        try {
            const auto commands = oblivion::load_command_table(executable_value.get_data(), cache_value.get_data());
            const auto* quest_script = data_->find_script(quest->script_form_id);
            for (const auto& run : oblivion::run_quest_stage(*quest, static_cast<unsigned>(stage),
                                                             oblivion::make_command_lookup(commands), quest_script,
                                                             quest_state_)) {
                runs.push_back(stage_run_to_dictionary(run));
            }
            result["runs"] = runs;
        } catch (const std::exception& error) {
            result["error"] = as_string(error.what());
        }
        return result;
    }

    Dictionary find_cell(const String& editor_id) const {
        const CharString value = editor_id.utf8();
        std::lock_guard<std::mutex> lock(state_mutex_);
        if (!data_) return {};
        const auto* cell = data_->find_cell(value.get_data());
        return cell ? cell_to_dictionary(*cell) : Dictionary{};
    }

    Dictionary find_cell_by_id(int64_t form_id) const {
        std::lock_guard<std::mutex> lock(state_mutex_);
        if (!data_) return {};
        const auto* cell = data_->find_cell(static_cast<uint32_t>(form_id));
        return cell ? cell_to_dictionary(*cell) : Dictionary{};
    }

    Dictionary find_npc_base(int64_t form_id) const {
        std::lock_guard<std::mutex> lock(state_mutex_);
        if (!data_) return {};
        const auto* npc = data_->find_npc_base(static_cast<uint32_t>(form_id));
        if (!npc) return {};
        const auto* race = data_->find_race_face_gen(npc->race_form_id);
        const auto& race_symmetric = race_shape_coefficients(race, true);
        const auto& race_asymmetric = race_shape_coefficients(race, false);
        Dictionary result;
        result["form_id"] = static_cast<int64_t>(npc->form_id);
        result["editor_id"] = as_string(npc->editor_id);
        result["name"] = as_string(npc->name);
        result["flags"] = static_cast<int64_t>(npc->flags);
        result["female"] = (npc->flags & 0x000001) != 0;
        result["race_form_id"] = static_cast<int64_t>(npc->race_form_id);
        result["hair_form_id"] = static_cast<int64_t>(npc->hair_form_id);
        result["eye_form_id"] = static_cast<int64_t>(npc->eye_form_id);
        result["default_outfit_form_id"] = static_cast<int64_t>(npc->default_outfit_form_id);
        PackedByteArray hair_color;
        hair_color.resize(static_cast<int64_t>(npc->hair_color.size()));
        for (int64_t i = 0; i < static_cast<int64_t>(npc->hair_color.size()); ++i)
            hair_color.set(i, npc->hair_color[static_cast<std::size_t>(i)]);
        result["hair_color"] = hair_color;
        result["face_symmetric"] = add_face_coefficients(race_symmetric, npc->face_symmetric);
        result["face_asymmetric"] = add_face_coefficients(race_asymmetric, npc->face_asymmetric);
        result["face_symmetric_race"] = as_packed_coefficients(race_symmetric);
        result["face_asymmetric_race"] = as_packed_coefficients(race_asymmetric);
        result["face_symmetric_individual"] = as_packed_coefficients(npc->face_symmetric);
        result["face_asymmetric_individual"] = as_packed_coefficients(npc->face_asymmetric);
        PackedByteArray face_texture;
        face_texture.resize(static_cast<int64_t>(npc->face_texture.size()));
        for (int64_t i = 0; i < static_cast<int64_t>(npc->face_texture.size()); ++i)
            face_texture.set(i, npc->face_texture[static_cast<std::size_t>(i)]);
        result["face_texture"] = face_texture;
        result["face_texture_coefficients"] = add_face_coefficients(
            race ? race->face_texture_coefficients : std::vector<float>{}, npc->face_texture_coefficients);
        if (race) {
            const bool female = (npc->flags & 0x000001) != 0;
            const auto& head_parts = female && has_race_parts(race->head_parts_female)
                ? race->head_parts_female : race->head_parts_male;
            const auto& body_parts = female && has_race_parts(race->body_parts_female)
                ? race->body_parts_female : race->body_parts_male;
            result["race_head_parts"] = race_parts_to_array(head_parts);
            result["race_body_parts"] = race_parts_to_array(body_parts);
        } else {
            result["race_head_parts"] = Array{};
            result["race_body_parts"] = Array{};
        }
        Array inventory;
        for (const auto& item : npc->inventory) {
            Dictionary entry;
            entry["form_id"] = static_cast<int64_t>(item.form_id);
            entry["count"] = item.count;
            inventory.push_back(entry);
        }
        result["inventory"] = inventory;
        PackedInt64Array ai_packages;
        ai_packages.resize(static_cast<int64_t>(npc->ai_package_form_ids.size()));
        for (int64_t i = 0; i < static_cast<int64_t>(npc->ai_package_form_ids.size()); ++i)
            ai_packages.set(i, static_cast<int64_t>(npc->ai_package_form_ids[static_cast<std::size_t>(i)]));
        result["ai_package_form_ids"] = ai_packages;
        return result;
    }

    Array get_outfit_items(int64_t form_id) const {
        Array result;
        std::lock_guard<std::mutex> lock(state_mutex_);
        if (!data_) return result;
        const auto* outfit = data_->find_outfit(static_cast<std::uint32_t>(form_id));
        if (!outfit) return result;
        for (const auto item_id : outfit->item_form_ids)
            result.push_back(static_cast<int64_t>(item_id));
        return result;
    }

    Dictionary get_ai_package_info(int64_t form_id) const {
        std::lock_guard<std::mutex> lock(state_mutex_);
        if (!data_) return {};
        const auto* package = data_->find_ai_package(static_cast<std::uint32_t>(form_id));
        if (!package) return {};
        Dictionary result;
        result["form_id"] = static_cast<int64_t>(package->form_id);
        result["editor_id"] = as_string(package->editor_id);
        result["flags"] = static_cast<int64_t>(package->flags);
        result["package_type"] = package->package_type;
        result["location_type"] = package->location_type;
        result["location_form_id"] = static_cast<int64_t>(package->location_form_id);
        result["location_radius"] = package->location_radius;
        return result;
    }

    String find_item_model_path(int64_t form_id, bool female) const {
        std::lock_guard<std::mutex> lock(state_mutex_);
        if (!data_) return {};
        const auto* path = data_->find_item_model_path(static_cast<std::uint32_t>(form_id), female);
        return path ? as_string(*path) : String{};
    }

    int64_t get_item_biped_slots(int64_t form_id) const {
        std::lock_guard<std::mutex> lock(state_mutex_);
        if (!data_) return 0;
        return data_->find_item_biped_slots(static_cast<std::uint32_t>(form_id));
    }

    int64_t find_form_id_by_editor_id(const String& editor_id) const {
        const CharString value = editor_id.utf8();
        std::lock_guard<std::mutex> lock(state_mutex_);
        if (!data_) return 0;
        return static_cast<int64_t>(data_->find_form_id_by_editor_id(value.get_data()));
    }

    String find_editor_id(int64_t form_id) const {
        std::lock_guard<std::mutex> lock(state_mutex_);
        if (!data_) return {};
        const auto* editor_id = data_->find_editor_id(static_cast<std::uint32_t>(form_id));
        return editor_id ? as_string(*editor_id) : String{};
    }

    String find_record_type(int64_t form_id) const {
        std::lock_guard<std::mutex> lock(state_mutex_);
        if (!data_) return {};
        const auto* record_type = data_->find_record_type(static_cast<std::uint32_t>(form_id));
        return record_type ? as_string(*record_type) : String{};
    }

    PackedByteArray read_asset(const String& asset_path) const {
        const CharString path = asset_path.utf8();
        std::vector<uint8_t> bytes;
        {
            std::lock_guard<std::mutex> lock(state_mutex_);
            if (!data_) return {};
            try {
                bytes = data_->read_asset(path.get_data());
            } catch (const std::exception& error) {
                error_ = error.what();
                return {};
            }
        }
        PackedByteArray result;
        result.resize(static_cast<int64_t>(bytes.size()));
        for (int64_t i = 0; i < static_cast<int64_t>(bytes.size()); ++i)
            result.set(i, bytes[static_cast<std::size_t>(i)]);
        return result;
    }

    PackedByteArray apply_facegen_texture_data(const PackedByteArray& image_data, int64_t width,
                                               int64_t height, const PackedByteArray& egt_data,
                                               const PackedFloat32Array& coefficients) const {
        return apply_facegen_texture(image_data, width, height, egt_data, coefficients);
    }

    bool request_nif_meshes(const String& asset_path) {
        if (loading_.load() || asset_loading_.load()) return false;
        if (worker_.joinable()) worker_.join();
        const CharString utf8 = asset_path.utf8();
        const std::string path(utf8.get_data());
        {
            std::lock_guard<std::mutex> lock(state_mutex_);
            if (!data_) return false;
        }
        {
            std::lock_guard<std::mutex> lock(asset_mutex_);
            asset_data_ = {};
            asset_bytes_.clear();
            asset_error_.clear();
            asset_ready_ = false;
        }
        asset_loading_.store(true);
        worker_ = std::thread([this, path]() {
            try {
                std::vector<std::uint8_t> bytes;
                {
                    std::lock_guard<std::mutex> lock(state_mutex_);
                    if (!data_) throw std::runtime_error("game data is not ready");
                    bytes = data_->read_asset(path);
                }
                auto asset = oblivion::decode_nif_asset(bytes);
                std::lock_guard<std::mutex> lock(asset_mutex_);
                asset_data_ = std::move(asset);
                asset_bytes_ = std::move(bytes);
                asset_ready_ = true;
            } catch (const std::exception& error) {
                std::lock_guard<std::mutex> lock(asset_mutex_);
                asset_error_ = error.what();
                asset_ready_ = true;
            }
            asset_loading_.store(false);
        });
        return true;
    }

    bool is_asset_loading() const { return asset_loading_.load(); }

    String get_asset_error() const {
        std::lock_guard<std::mutex> lock(asset_mutex_);
        return String::utf8(asset_error_.c_str());
    }

    Dictionary take_nif_meshes() {
        Dictionary result;
        oblivion::NifAssetData asset_data;
        std::vector<std::uint8_t> source_bytes;
        {
            std::lock_guard<std::mutex> lock(asset_mutex_);
            if (!asset_ready_) return result;
            asset_data = std::move(asset_data_);
            source_bytes = std::move(asset_bytes_);
            asset_ready_ = false;
        }
        PackedByteArray packed_source;
        packed_source.resize(static_cast<int64_t>(source_bytes.size()));
        for (int64_t i = 0; i < static_cast<int64_t>(source_bytes.size()); ++i)
            packed_source.set(i, source_bytes[static_cast<std::size_t>(i)]);
        result["source_bytes"] = packed_source;
        Array mesh_array;
        for (const auto& mesh : asset_data.meshes) {
            Dictionary item;
            item["name"] = String::utf8(mesh.name.c_str());
            item["parent_node_name"] = String::utf8(mesh.parent_node_name.c_str());
            item["diffuse_texture_path"] = String::utf8(mesh.diffuse_texture_path.c_str());
            item["alpha_blend"] = mesh.alpha_blend;
            item["alpha_test"] = mesh.alpha_test;
            item["alpha_threshold"] = mesh.alpha_threshold;
            PackedVector3Array vertices;
            vertices.resize(static_cast<int64_t>(mesh.vertices.size()));
            for (int64_t i = 0; i < static_cast<int64_t>(mesh.vertices.size()); ++i) {
                const auto& value = mesh.vertices[static_cast<std::size_t>(i)];
                vertices.set(i, Vector3(value[0], value[1], value[2]));
            }
            item["vertices"] = vertices;
            PackedVector3Array parent_local_vertices;
            parent_local_vertices.resize(static_cast<int64_t>(mesh.parent_local_vertices.size()));
            for (int64_t i = 0; i < static_cast<int64_t>(mesh.parent_local_vertices.size()); ++i) {
                const auto& value = mesh.parent_local_vertices[static_cast<std::size_t>(i)];
                parent_local_vertices.set(i, Vector3(value[0], value[1], value[2]));
            }
            item["parent_local_vertices"] = parent_local_vertices;
            PackedVector3Array normals;
            normals.resize(static_cast<int64_t>(mesh.normals.size()));
            for (int64_t i = 0; i < static_cast<int64_t>(mesh.normals.size()); ++i) {
                const auto& value = mesh.normals[static_cast<std::size_t>(i)];
                normals.set(i, Vector3(value[0], value[1], value[2]));
            }
            item["normals"] = normals;
            PackedVector3Array parent_local_normals;
            parent_local_normals.resize(static_cast<int64_t>(mesh.parent_local_normals.size()));
            for (int64_t i = 0; i < static_cast<int64_t>(mesh.parent_local_normals.size()); ++i) {
                const auto& value = mesh.parent_local_normals[static_cast<std::size_t>(i)];
                parent_local_normals.set(i, Vector3(value[0], value[1], value[2]));
            }
            item["parent_local_normals"] = parent_local_normals;
            PackedVector2Array uvs;
            uvs.resize(static_cast<int64_t>(mesh.uvs.size()));
            for (int64_t i = 0; i < static_cast<int64_t>(mesh.uvs.size()); ++i) {
                const auto& value = mesh.uvs[static_cast<std::size_t>(i)];
                uvs.set(i, Vector2(value[0], value[1]));
            }
            item["uvs"] = uvs;
            PackedInt32Array indices;
            indices.resize(static_cast<int64_t>(mesh.indices.size()));
            for (int64_t i = 0; i < static_cast<int64_t>(mesh.indices.size()); ++i)
                indices.set(i, static_cast<int32_t>(mesh.indices[static_cast<std::size_t>(i)]));
            item["indices"] = indices;
            Array bone_names;
            for (const auto& bone_name : mesh.bone_names)
                bone_names.push_back(String::utf8(bone_name.c_str()));
            item["bone_names"] = bone_names;
            PackedInt32Array bone_indices;
            bone_indices.resize(static_cast<int64_t>(mesh.bone_indices.size()));
            for (int64_t i = 0; i < static_cast<int64_t>(mesh.bone_indices.size()); ++i)
                bone_indices.set(i, mesh.bone_indices[static_cast<std::size_t>(i)]);
            item["bone_indices"] = bone_indices;
            PackedFloat32Array bone_weights;
            bone_weights.resize(static_cast<int64_t>(mesh.bone_weights.size()));
            for (int64_t i = 0; i < static_cast<int64_t>(mesh.bone_weights.size()); ++i)
                bone_weights.set(i, mesh.bone_weights[static_cast<std::size_t>(i)]);
            item["bone_weights"] = bone_weights;
            mesh_array.push_back(item);
        }
        result["meshes"] = mesh_array;
        Array nodes;
        for (const auto& node : asset_data.nodes) {
            Dictionary item;
            item["name"] = String::utf8(node.name.c_str());
            item["parent_name"] = String::utf8(node.parent_name.c_str());
            item["translation"] = Vector3(node.translation[0], node.translation[1], node.translation[2]);
            PackedFloat32Array rotation_rows;
            rotation_rows.resize(9);
            for (int i = 0; i < 9; ++i) rotation_rows.set(i, node.rotation_rows[static_cast<std::size_t>(i)]);
            item["rotation_rows"] = rotation_rows;
            item["scale"] = node.scale;
            item["global_translation"] = Vector3(
                node.global_translation[0], node.global_translation[1], node.global_translation[2]);
            PackedFloat32Array global_rotation_rows;
            global_rotation_rows.resize(9);
            for (int i = 0; i < 9; ++i)
                global_rotation_rows.set(i, node.global_rotation_rows[static_cast<std::size_t>(i)]);
            item["global_rotation_rows"] = global_rotation_rows;
            item["global_scale"] = node.global_scale;
            nodes.push_back(item);
        }
        result["nodes"] = nodes;
        Array physics_bodies;
        for (const auto& body : asset_data.physics_bodies) {
            Dictionary item;
            item["block_index"] = static_cast<int64_t>(body.block_index);
            item["node_name"] = String::utf8(body.node_name.c_str());
            item["node_global_translation"] = Vector3(
                body.node_global_translation[0], body.node_global_translation[1], body.node_global_translation[2]);
            PackedFloat32Array node_global_rotation_rows;
            node_global_rotation_rows.resize(9);
            for (int i = 0; i < 9; ++i)
                node_global_rotation_rows.set(i, body.node_global_rotation_rows[static_cast<std::size_t>(i)]);
            item["node_global_rotation_rows"] = node_global_rotation_rows;
            item["node_global_scale"] = body.node_global_scale;
            item["havok_translation"] = Vector3(
                body.havok_translation[0], body.havok_translation[1], body.havok_translation[2]);
            PackedFloat32Array havok_rotation;
            havok_rotation.resize(4);
            for (int i = 0; i < 4; ++i)
                havok_rotation.set(i, body.havok_rotation[static_cast<std::size_t>(i)]);
            item["havok_rotation"] = havok_rotation;
            item["mass"] = body.mass;
            item["linear_damping"] = body.linear_damping;
            item["angular_damping"] = body.angular_damping;
            item["gravity_factor"] = body.gravity_factor;
            item["friction"] = body.friction;
            item["restitution"] = body.restitution;
            item["collision_layer"] = body.collision_layer;
            Dictionary shape;
            shape["type"] = String::utf8(body.shape.type.c_str());
            shape["point1"] = Vector3(body.shape.point1[0], body.shape.point1[1], body.shape.point1[2]);
            shape["point2"] = Vector3(body.shape.point2[0], body.shape.point2[1], body.shape.point2[2]);
            shape["radius1"] = body.shape.radius1;
            shape["radius2"] = body.shape.radius2;
            PackedVector3Array shape_vertices;
            shape_vertices.resize(static_cast<int64_t>(body.shape.vertices.size()));
            for (int64_t i = 0; i < static_cast<int64_t>(body.shape.vertices.size()); ++i) {
                const auto& vertex = body.shape.vertices[static_cast<std::size_t>(i)];
                shape_vertices.set(i, Vector3(vertex[0], vertex[1], vertex[2]));
            }
            shape["vertices"] = shape_vertices;
            item["shape"] = shape;
            physics_bodies.push_back(item);
        }
        result["physics_bodies"] = physics_bodies;
        Array physics_constraints;
        for (const auto& constraint : asset_data.physics_constraints) {
            Dictionary item;
            item["type"] = String::utf8(constraint.type.c_str());
            item["body_a_node_name"] = String::utf8(constraint.body_a_node_name.c_str());
            item["body_b_node_name"] = String::utf8(constraint.body_b_node_name.c_str());
            item["pivot_a"] = Vector3(constraint.pivot_a[0], constraint.pivot_a[1], constraint.pivot_a[2]);
            item["pivot_b"] = Vector3(constraint.pivot_b[0], constraint.pivot_b[1], constraint.pivot_b[2]);
            item["twist_axis_a"] = Vector3(
                constraint.twist_axis_a[0], constraint.twist_axis_a[1], constraint.twist_axis_a[2]);
            item["plane_axis_a"] = Vector3(
                constraint.plane_axis_a[0], constraint.plane_axis_a[1], constraint.plane_axis_a[2]);
            item["cone_max_angle"] = constraint.cone_max_angle;
            item["plane_min_angle"] = constraint.plane_min_angle;
            item["plane_max_angle"] = constraint.plane_max_angle;
            item["twist_min_angle"] = constraint.twist_min_angle;
            item["twist_max_angle"] = constraint.twist_max_angle;
            item["max_friction"] = constraint.max_friction;
            physics_constraints.push_back(item);
        }
        result["physics_constraints"] = physics_constraints;
        Array animations;
        for (const auto& animation : asset_data.animations) {
            Dictionary animation_item;
            animation_item["name"] = String::utf8(animation.name.c_str());
            animation_item["start_time"] = animation.start_time;
            animation_item["stop_time"] = animation.stop_time;
            Array tracks;
            for (const auto& track : animation.tracks) {
                Dictionary track_item;
                track_item["node_name"] = String::utf8(track.node_name.c_str());
                PackedFloat32Array translations;
                translations.resize(static_cast<int64_t>(track.translations.size() * 4));
                int64_t cursor = 0;
                for (const auto& key : track.translations)
                    for (const float value : key) translations.set(cursor++, value);
                track_item["translations"] = translations;
                PackedFloat32Array rotations;
                rotations.resize(static_cast<int64_t>(track.rotations.size() * 5));
                cursor = 0;
                for (const auto& key : track.rotations)
                    for (const float value : key) rotations.set(cursor++, value);
                track_item["rotations"] = rotations;
                PackedFloat32Array scales;
                scales.resize(static_cast<int64_t>(track.scales.size() * 2));
                cursor = 0;
                for (const auto& key : track.scales)
                    for (const float value : key) scales.set(cursor++, value);
                track_item["scales"] = scales;
                tracks.push_back(track_item);
            }
            animation_item["tracks"] = tracks;
            animations.push_back(animation_item);
        }
        result["animations"] = animations;
        return result;
    }

protected:
    static void _bind_methods() {
        ClassDB::bind_method(D_METHOD("open_game_async", "data_directory"), &OblivionData::open_game_async);
        ClassDB::bind_method(D_METHOD("is_loading"), &OblivionData::is_loading);
        ClassDB::bind_method(D_METHOD("is_ready"), &OblivionData::is_ready);
        ClassDB::bind_method(D_METHOD("get_error"), &OblivionData::get_error);
        ClassDB::bind_method(D_METHOD("get_summary"), &OblivionData::get_summary);
        ClassDB::bind_method(D_METHOD("list_cells"), &OblivionData::list_cells);
        ClassDB::bind_method(D_METHOD("find_exterior_region", "grid_x", "grid_y", "worldspace_form_id", "radius",
                                      "static_reference_radius", "tree_reference_radius"),
                             &OblivionData::find_exterior_region, DEFVAL(-1), DEFVAL(-1));
        ClassDB::bind_method(D_METHOD("find_cell", "editor_id"), &OblivionData::find_cell);
        ClassDB::bind_method(D_METHOD("create_quest_world", "executable_path", "cache_dir"), &OblivionData::create_quest_world);
        ClassDB::bind_method(D_METHOD("run_quest_stage", "quest_editor_id", "stage", "executable_path", "cache_dir"),
                             &OblivionData::run_quest_stage);
        ClassDB::bind_method(D_METHOD("find_cell_by_id", "form_id"), &OblivionData::find_cell_by_id);
        ClassDB::bind_method(D_METHOD("find_npc_base", "form_id"), &OblivionData::find_npc_base);
        ClassDB::bind_method(D_METHOD("get_outfit_items", "form_id"), &OblivionData::get_outfit_items);
        ClassDB::bind_method(D_METHOD("get_ai_package_info", "form_id"), &OblivionData::get_ai_package_info);
        ClassDB::bind_method(D_METHOD("find_item_model_path", "form_id", "female"), &OblivionData::find_item_model_path);
        ClassDB::bind_method(D_METHOD("get_item_biped_slots", "form_id"), &OblivionData::get_item_biped_slots);
        ClassDB::bind_method(D_METHOD("find_form_id_by_editor_id", "editor_id"), &OblivionData::find_form_id_by_editor_id);
        ClassDB::bind_method(D_METHOD("find_editor_id", "form_id"), &OblivionData::find_editor_id);
        ClassDB::bind_method(D_METHOD("find_record_type", "form_id"), &OblivionData::find_record_type);
        ClassDB::bind_method(D_METHOD("read_asset", "asset_path"), &OblivionData::read_asset);
        ClassDB::bind_method(D_METHOD("apply_facegen_texture_data", "image_data", "width", "height",
                                      "egt_data", "coefficients"), &OblivionData::apply_facegen_texture_data);
        ClassDB::bind_method(D_METHOD("request_nif_meshes", "asset_path"), &OblivionData::request_nif_meshes);
        ClassDB::bind_method(D_METHOD("is_asset_loading"), &OblivionData::is_asset_loading);
        ClassDB::bind_method(D_METHOD("get_asset_error"), &OblivionData::get_asset_error);
        ClassDB::bind_method(D_METHOD("take_nif_meshes"), &OblivionData::take_nif_meshes);
    }

private:
    static String as_string(const std::string& value) { return String::utf8(value.c_str()); }

    static Dictionary stage_run_to_dictionary(const oblivion::StageEntryRun& run) {
        Dictionary entry;
        entry["conditions_hold"] = run.conditions_hold;
        entry["completes"] = run.completes;
        entry["log"] = as_string(run.log_text);
        PackedStringArray parse_errors;
        for (const auto& error : run.parse_errors) parse_errors.push_back(as_string(error));
        entry["parse_errors"] = parse_errors;
        PackedStringArray missing;
        for (const auto& name : run.missing_conditions) missing.push_back(as_string(name));
        entry["missing_conditions"] = missing;
        Array actions;
        for (const auto& action : run.actions) actions.push_back(action_to_dictionary(action));
        entry["actions"] = actions;
        return entry;
    }

    static Dictionary reference_to_dictionary(const oblivion::PlacedReference& reference) {
        Dictionary entry;
        entry["form_id"] = static_cast<int64_t>(reference.form_id);
        entry["base_form_id"] = static_cast<int64_t>(reference.base_form_id);
        entry["record_type"] = as_string(reference.record_type);
        entry["reference_name"] = as_string(reference.reference_name);
        entry["base_editor_id"] = as_string(reference.base_editor_id);
        entry["position"] = PackedFloat32Array{reference.position[0], reference.position[1], reference.position[2]};
        entry["rotation"] = PackedFloat32Array{reference.rotation[0], reference.rotation[1], reference.rotation[2]};
        entry["teleport_ref_id"] = static_cast<int64_t>(reference.teleport_ref_id);
        entry["teleport_cell_id"] = static_cast<int64_t>(reference.teleport_cell_id);
        entry["teleport_position"] = PackedFloat32Array{reference.teleport_position[0], reference.teleport_position[1], reference.teleport_position[2]};
        entry["teleport_rotation"] = PackedFloat32Array{reference.teleport_rotation[0], reference.teleport_rotation[1], reference.teleport_rotation[2]};
        entry["editor_id"] = as_string(reference.editor_id);
        entry["model_path"] = as_string(reference.model_path);
        entry["is_tree"] = reference.is_tree;
        entry["tree_billboard_width"] = reference.tree_billboard_width;
        entry["tree_billboard_height"] = reference.tree_billboard_height;
        entry["tree_billboard_texture_path"] = as_string(reference.tree_billboard_texture_path);
        return entry;
    }

    static Dictionary cell_to_dictionary(const oblivion::CellRecord& cell) {
        Dictionary result;
        result["form_id"] = static_cast<int64_t>(cell.form_id);
        result["worldspace_form_id"] = static_cast<int64_t>(cell.worldspace_form_id);
        result["editor_id"] = as_string(cell.editor_id);
        result["display_name"] = as_string(cell.display_name);
        result["interior"] = cell.interior;
        result["exterior_grid_cell"] = cell.exterior_grid_cell;
        result["has_grid"] = cell.has_grid;
        result["has_water_level"] = cell.has_water_level;
        result["has_worldspace_water_level"] = cell.has_worldspace_water_level;
        result["grid_x"] = cell.grid_x;
        result["grid_y"] = cell.grid_y;
        result["water_height"] = cell.water_height;
        result["worldspace_water_height"] = cell.worldspace_water_height;
        if (cell.land_heights.size() == 33 * 33) {
            Dictionary land;
            land["grid_x"] = cell.grid_x;
            land["grid_y"] = cell.grid_y;
            PackedFloat32Array heights;
            heights.resize(static_cast<int64_t>(cell.land_heights.size()));
            for (int64_t i = 0; i < heights.size(); ++i)
                heights.set(i, cell.land_heights[static_cast<std::size_t>(i)]);
            land["heights"] = heights;
            land["texture_path"] = as_string(cell.land_texture_path);
            result["land"] = land;
        }
        Array references;
        for (const auto& reference : cell.references) references.push_back(reference_to_dictionary(reference));
        result["references"] = references;
        return result;
    }

    mutable std::mutex state_mutex_;
    std::unique_ptr<oblivion::GameData> data_;
    // Quest variables persist between stage runs of the loaded game.
    mutable oblivion::QuestState quest_state_;
    mutable std::string error_;
    std::thread worker_;
    std::atomic<bool> loading_{false};
    std::atomic<bool> asset_loading_{false};
    mutable std::mutex asset_mutex_;
    oblivion::NifAssetData asset_data_;
    std::vector<std::uint8_t> asset_bytes_;
    std::string asset_error_;
    bool asset_ready_ = false;
};


// The quests of the loaded game running together: GameMode of every started quest runs on each tick, and stage
// results run when a stage is set, in this quest or another. Results come back as Dictionaries; the caller applies
// the actions to the scene.
class OblivionQuestWorld final : public RefCounted {
    GDCLASS(OblivionQuestWorld, RefCounted)

public:
    // Starts a quest at a stage. `distance` is called as distance(from: String, to: String) and returns
    // a distance in game units, or null when the scene cannot answer.
    Dictionary start(const String& quest_editor_id, int64_t stage, const Callable& distance) {
        return tick_to_dictionary(world_->start(utf8_value(quest_editor_id), static_cast<unsigned>(stage), distance_function(distance)));
    }

    // Runs GameMode of every started quest once after `seconds` have passed since the last tick.
    Dictionary tick(double seconds, const Callable& distance) {
        return tick_to_dictionary(world_->tick(seconds, distance_function(distance)));
    }

    // The stage of a quest, or -1 when the quest is not in the world.
    int64_t get_stage(const String& quest_editor_id) {
        const auto* driver = world_->find(utf8_value(quest_editor_id));
        return driver ? static_cast<int64_t>(driver->stage()) : -1;
    }

    // A quest variable by name, or -1 when the quest is not in the world or does not declare it.
    double get_variable(const String& quest_editor_id, const String& variable) {
        const auto* driver = world_->find(utf8_value(quest_editor_id));
        const auto value = driver ? driver->variable(utf8_value(variable)) : std::nullopt;
        return value ? *value : -1.0;
    }

    // Registers an NPC whose script's GameMode runs on every tick. False when the NPC or its script is missing.
    bool add_actor(const String& npc_editor_id) {
        const auto* game = owner_.is_valid() ? owner_->game_data() : nullptr;
        const auto form_id = game ? game->find_form_id_by_editor_id(utf8_value(npc_editor_id)) : 0u;
        const auto* npc = game ? game->find_npc_base(form_id) : nullptr;
        const auto* script = npc ? game->find_script(npc->script_form_id) : nullptr;
        if (!script) return false;
        world_->add_actor(form_id, *script);
        return true;
    }

    // Names the NPC a placed reference of the scene stands for, so SayTo to that reference is to that NPC.
    void set_reference_base(const String& reference_name, const String& npc_editor_id) {
        const auto* game = owner_.is_valid() ? owner_->game_data() : nullptr;
        world_->set_reference_base(utf8_value(reference_name), game ? game->find_form_id_by_editor_id(utf8_value(npc_editor_id)) : 0u);
    }

    // The player as a dialogue listener: the race (by editor ID) and sex that topic conditions read.
    void set_listener(const String& race_editor_id, bool female) {
        const auto* game = owner_.is_valid() ? owner_->game_data() : nullptr;
        world_->set_listener(game ? game->find_form_id_by_editor_id(utf8_value(race_editor_id)) : 0u, female);
    }

    // The package an NPC starts now, judged with the stage of the quest. Empty when none holds.
    Dictionary select_package(const String& quest_editor_id, const String& npc_editor_id) {
        Dictionary result;
        const auto* driver = world_->find(utf8_value(quest_editor_id));
        const auto* game = owner_.is_valid() ? owner_->game_data() : nullptr;
        const auto* npc = game ? game->find_npc_base(game->find_form_id_by_editor_id(utf8_value(npc_editor_id))) : nullptr;
        if (!driver || !npc) return result;
        std::vector<const oblivion::AiPackageRecord*> packages;
        for (const auto package_id : npc->ai_package_form_ids)
            if (const auto* package = game->find_ai_package(package_id)) packages.push_back(package);
        const auto* chosen = driver->select_package(packages);
        if (!chosen) return result;
        result["editor_id"] = utf8_text(chosen->editor_id);
        result["package_type"] = static_cast<int64_t>(chosen->package_type);
        result["location_type"] = static_cast<int64_t>(chosen->location_type);
        result["location_form_id"] = static_cast<int64_t>(chosen->location_form_id);
        result["radius"] = static_cast<int64_t>(chosen->location_radius);
        result["flags"] = static_cast<int64_t>(chosen->flags);
        return result;
    }

    // Runs an event of an NPC's script (for example OnPackageDone with the package name) on a quest.
    Dictionary run_actor_event(const String& quest_editor_id, const String& npc_editor_id, const String& event,
                               const String& detail, const Callable& distance) {
        auto* driver = world_->find(utf8_value(quest_editor_id));
        const auto* game = owner_.is_valid() ? owner_->game_data() : nullptr;
        const auto* npc = game ? game->find_npc_base(game->find_form_id_by_editor_id(utf8_value(npc_editor_id))) : nullptr;
        const auto* script = npc ? game->find_script(npc->script_form_id) : nullptr;
        if (!driver || !script) return Dictionary();
        return tick_to_dictionary(driver->run_actor_event(*script, utf8_value(event), utf8_value(detail), distance_function(distance)));
    }

    void attach(const Ref<OblivionData>& owner, std::unique_ptr<oblivion::QuestWorld> world) {
        owner_ = owner;
        world_ = std::move(world);
    }

    static void _bind_methods() {
        ClassDB::bind_method(D_METHOD("start", "quest_editor_id", "stage", "distance"), &OblivionQuestWorld::start);
        ClassDB::bind_method(D_METHOD("tick", "seconds", "distance"), &OblivionQuestWorld::tick);
        ClassDB::bind_method(D_METHOD("get_stage", "quest_editor_id"), &OblivionQuestWorld::get_stage);
        ClassDB::bind_method(D_METHOD("add_actor", "npc_editor_id"), &OblivionQuestWorld::add_actor);
        ClassDB::bind_method(D_METHOD("get_variable", "quest_editor_id", "variable"), &OblivionQuestWorld::get_variable);
        ClassDB::bind_method(D_METHOD("set_listener", "race_editor_id", "female"), &OblivionQuestWorld::set_listener);
        ClassDB::bind_method(D_METHOD("set_reference_base", "reference_name", "npc_editor_id"), &OblivionQuestWorld::set_reference_base);
        ClassDB::bind_method(D_METHOD("select_package", "quest_editor_id", "npc_editor_id"), &OblivionQuestWorld::select_package);
        ClassDB::bind_method(D_METHOD("run_actor_event", "quest_editor_id", "npc_editor_id", "event", "detail", "distance"),
                             &OblivionQuestWorld::run_actor_event);
    }

private:
    Ref<OblivionData> owner_;
    std::unique_ptr<oblivion::QuestWorld> world_;

    static std::string utf8_value(const String& value) {
        const CharString text = value.utf8();
        return std::string(text.get_data());
    }

    static oblivion::DistanceFunction distance_function(const Callable& callable) {
        if (callable.is_null() || !callable.is_valid()) return {};
        return [callable](std::string_view from, std::string_view to) -> std::optional<double> {
            const Variant value = callable.call(utf8_text(std::string(from)), utf8_text(std::string(to)));
            if (value.get_type() == Variant::FLOAT) return static_cast<double>(value);
            if (value.get_type() == Variant::INT) return static_cast<double>(static_cast<int64_t>(value));
            return std::nullopt;
        };
    }

    static Dictionary tick_to_dictionary(const oblivion::QuestTick& tick) {
        Dictionary result;
        result["stage"] = static_cast<int64_t>(tick.stage);
        PackedStringArray changes;
        for (const auto& change : tick.stage_changes) changes.push_back(utf8_text(change));
        result["stage_changes"] = changes;
        Array actions;
        for (const auto& action : tick.actions) actions.push_back(action_to_dictionary(action));
        result["actions"] = actions;
        PackedStringArray unanswered;
        for (const auto& name : tick.unanswered) unanswered.push_back(utf8_text(name));
        result["unanswered"] = unanswered;
        PackedStringArray errors;
        for (const auto& error : tick.parse_errors) errors.push_back(utf8_text(error));
        result["parse_errors"] = errors;
        return result;
    }
};

Ref<OblivionQuestWorld> OblivionData::create_quest_world(const String& executable_path, const String& cache_dir) const {
    const CharString executable_value = executable_path.utf8();
    const CharString cache_value = cache_dir.utf8();
    const oblivion::GameData* game = game_data();
    if (!game) return Ref<OblivionQuestWorld>();
    try {
        const auto commands = oblivion::load_command_table(executable_value.get_data(), cache_value.get_data());
        auto world = std::make_unique<oblivion::QuestWorld>(oblivion::make_command_lookup(commands));
        world->set_answer(oblivion::answer_fresh_player);
        world->set_topic_finder([game](std::string_view editor_id) { return game->find_topic_by_editor_id(editor_id); });
        for (const auto& [form_id, quest] : game->quests())
            if (const auto* script = game->find_script(quest.script_form_id)) world->add(quest, *script);
        Ref<OblivionQuestWorld> result;
        result.instantiate();
        result->attach(Ref<OblivionData>(const_cast<OblivionData*>(this)), std::move(world));
        return result;
    } catch (const std::exception& error) {
        UtilityFunctions::push_error(String("quest world: ") + utf8_text(error.what()));
        return Ref<OblivionQuestWorld>();
    }
}

void register_oblivion_data_types(ModuleInitializationLevel level) {
    if (level != MODULE_INITIALIZATION_LEVEL_SCENE) return;
    ClassDB::register_class<OblivionData>();
    ClassDB::register_class<OblivionQuestWorld>();
}

void unregister_oblivion_data_types(ModuleInitializationLevel) {}

} // namespace godot

extern "C" {
GDExtensionBool GDE_EXPORT oblivion_data_library_init(
    GDExtensionInterfaceGetProcAddress get_proc_address,
    GDExtensionClassLibraryPtr library,
    GDExtensionInitialization* initialization) {
    godot::GDExtensionBinding::InitObject init_obj(get_proc_address, library, initialization);
    init_obj.register_initializer(godot::register_oblivion_data_types);
    init_obj.register_terminator(godot::unregister_oblivion_data_types);
    init_obj.set_minimum_library_initialization_level(godot::MODULE_INITIALIZATION_LEVEL_SCENE);
    return init_obj.init();
}
}
