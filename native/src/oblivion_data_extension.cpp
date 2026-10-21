#include "oblivion/game_data.hpp"
#include "oblivion/nif_mesh.hpp"

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>
#include <godot_cpp/variant/packed_vector2_array.hpp>
#include <godot_cpp/variant/packed_vector3_array.hpp>
#include <godot_cpp/variant/string.hpp>
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
                data->open(path);
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
            PackedVector3Array normals;
            normals.resize(static_cast<int64_t>(mesh.normals.size()));
            for (int64_t i = 0; i < static_cast<int64_t>(mesh.normals.size()); ++i) {
                const auto& value = mesh.normals[static_cast<std::size_t>(i)];
                normals.set(i, Vector3(value[0], value[1], value[2]));
            }
            item["normals"] = normals;
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
            nodes.push_back(item);
        }
        result["nodes"] = nodes;
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
        ClassDB::bind_method(D_METHOD("find_cell", "editor_id"), &OblivionData::find_cell);
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

    static Dictionary cell_to_dictionary(const oblivion::CellRecord& cell) {
        Dictionary result;
        result["form_id"] = static_cast<int64_t>(cell.form_id);
        result["editor_id"] = as_string(cell.editor_id);
        result["display_name"] = as_string(cell.display_name);
        result["interior"] = cell.interior;
        result["grid_x"] = cell.grid_x;
        result["grid_y"] = cell.grid_y;
        Array references;
        for (const auto& reference : cell.references) {
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
            references.push_back(entry);
        }
        result["references"] = references;
        return result;
    }

    mutable std::mutex state_mutex_;
    std::unique_ptr<oblivion::GameData> data_;
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

void register_oblivion_data_types(ModuleInitializationLevel level) {
    if (level != MODULE_INITIALIZATION_LEVEL_SCENE) return;
    ClassDB::register_class<OblivionData>();
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
