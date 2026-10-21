#pragma once

#include <array>
#include <cstdint>
#include <string>
#include <vector>

namespace oblivion {

struct NifMeshData {
    std::string name;
    std::string diffuse_texture_path;
    bool alpha_blend = false;
    bool alpha_test = false;
    std::uint8_t alpha_threshold = 128;
    std::vector<std::string> bone_names;
    std::vector<std::array<float, 3>> vertices;
    std::vector<std::array<float, 3>> normals;
    std::vector<std::array<float, 2>> uvs;
    std::vector<std::uint32_t> indices;
    std::vector<std::int32_t> bone_indices;
    std::vector<float> bone_weights;
};

struct NifNodeData {
    std::string name;
    std::string parent_name;
    std::array<float, 3> translation{};
    std::array<float, 9> rotation_rows{};
    float scale = 1.0f;
};

struct NifAnimationTrackData {
    std::string node_name;
    // Packed as time,x,y,z and time,x,y,z,w respectively.
    std::vector<std::array<float, 4>> translations;
    std::vector<std::array<float, 5>> rotations;
    std::vector<std::array<float, 2>> scales;
};

struct NifAnimationData {
    std::string name;
    float start_time = 0.0f;
    float stop_time = 0.0f;
    std::vector<NifAnimationTrackData> tracks;
};

struct NifAssetData {
    std::vector<NifMeshData> meshes;
    std::vector<NifNodeData> nodes;
    std::vector<NifAnimationData> animations;
};

// Decode static NiShape geometry and its node transforms from an Oblivion NIF.
// Coordinates are converted from NIF's Z-up basis to Godot's Y-up basis but
// remain in the game's unscaled scene units.
[[nodiscard]] std::vector<NifMeshData> decode_nif_meshes(const std::vector<std::uint8_t>& bytes);
[[nodiscard]] NifAssetData decode_nif_asset(const std::vector<std::uint8_t>& bytes);

} // namespace oblivion
