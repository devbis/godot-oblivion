#pragma once

#include <array>
#include <cstdint>
#include <string>
#include <utility>
#include <vector>

#include <NifFile.hpp>

namespace oblivion {

struct NifMeshData {
    std::string name;
    std::string parent_node_name;
    std::string diffuse_texture_path;
    bool editor_marker = false;
    bool alpha_blend = false;
    bool alpha_test = false;
    std::uint8_t alpha_threshold = 128;
    std::vector<std::string> bone_names;
    std::vector<std::array<float, 3>> vertices;
    std::vector<std::array<float, 3>> parent_local_vertices;
    std::vector<std::array<float, 3>> normals;
    std::vector<std::array<float, 3>> parent_local_normals;
    std::vector<std::array<float, 2>> uvs;
    std::vector<std::uint32_t> indices;
    std::vector<std::int32_t> bone_indices;
    std::vector<float> bone_weights;
};

struct NifNodeData {
    std::string name;
    std::string parent_name;
    std::string parent_reference_node;
    std::array<float, 3> translation{};
    std::array<float, 9> rotation_rows{};
    float scale = 1.0f;
    std::array<float, 3> global_translation{};
    std::array<float, 9> global_rotation_rows{};
    float global_scale = 1.0f;
};

struct NifPhysicsShapeData {
    std::string type;
    std::array<float, 3> point1{};
    std::array<float, 3> point2{};
    float radius1 = 0.0f;
    float radius2 = 0.0f;
    std::vector<std::array<float, 3>> vertices;
};

struct NifPhysicsBodyData {
    std::uint32_t block_index = 0;
    std::string node_name;
    std::array<float, 3> node_global_translation{};
    std::array<float, 9> node_global_rotation_rows{};
    float node_global_scale = 1.0f;
    std::array<float, 3> havok_translation{};
    std::array<float, 4> havok_rotation{};
    float mass = 0.0f;
    float linear_damping = 0.0f;
    float angular_damping = 0.0f;
    float gravity_factor = 1.0f;
    float friction = 0.0f;
    float restitution = 0.0f;
    std::uint8_t collision_layer = 0;
    NifPhysicsShapeData shape;
};

struct NifPhysicsConstraintData {
    std::string type;
    std::string body_a_node_name;
    std::string body_b_node_name;
    std::array<float, 3> pivot_a{};
    std::array<float, 3> pivot_b{};
    std::array<float, 3> twist_axis_a{};
    std::array<float, 3> plane_axis_a{};
    float cone_max_angle = 0.0f;
    float plane_min_angle = 0.0f;
    float plane_max_angle = 0.0f;
    float twist_min_angle = 0.0f;
    float twist_max_angle = 0.0f;
    float max_friction = 0.0f;
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
    // NiControllerSequence cycle type: 0 loop, 1 reverse, 2 clamp.
    std::uint32_t cycle_type = 0;
    // The sequence's NiTextKeyExtraData entries: gameplay markers such as an attack's "hit" or a bow's "release".
    std::vector<std::pair<float, std::string>> text_keys;
    std::vector<NifAnimationTrackData> tracks;
};

struct NifAssetData {
    std::vector<NifMeshData> meshes;
    std::vector<NifNodeData> nodes;
    std::vector<NifAnimationData> animations;
    std::vector<NifPhysicsBodyData> physics_bodies;
    std::vector<NifPhysicsConstraintData> physics_constraints;
    bool collision_enabled = false;
};

// Parses NIF bytes with nifly without copying them. Throws if nifly rejects the data.
void load_nif_file(const std::vector<std::uint8_t>& bytes, nifly::NifFile& file);

// Resolves one entry of a NIF string palette, or an empty string when it is absent.
[[nodiscard]] std::string nif_string_palette_entry(const nifly::NiHeader& header,
                                                   const nifly::NiBlockRef<nifly::NiStringPalette>& palette_ref,
                                                   std::uint32_t offset);

// Decode static NiShape geometry from an Oblivion NIF. Node-table and physics
// decoding are skipped; animation tracks are still parsed. Coordinates are
// converted from NIF's Z-up basis to Godot's Y-up basis but remain in the
// game's unscaled scene units.
[[nodiscard]] std::vector<NifMeshData> decode_nif_meshes(const std::vector<std::uint8_t>& bytes);
[[nodiscard]] NifAssetData decode_nif_asset(const std::vector<std::uint8_t>& bytes);

} // namespace oblivion
