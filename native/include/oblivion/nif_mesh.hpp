#pragma once

#include <array>
#include <cstdint>
#include <string>
#include <vector>

namespace oblivion {

struct NifMeshData {
    std::string name;
    std::string parent_node_name;
    std::string diffuse_texture_path;
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
    std::vector<NifAnimationTrackData> tracks;
};

struct NifAssetData {
    std::vector<NifMeshData> meshes;
    std::vector<NifNodeData> nodes;
    std::vector<NifAnimationData> animations;
    std::vector<NifPhysicsBodyData> physics_bodies;
    std::vector<NifPhysicsConstraintData> physics_constraints;
};

// Decode static NiShape geometry and its node transforms from an Oblivion NIF.
// Coordinates are converted from NIF's Z-up basis to Godot's Y-up basis but
// remain in the game's unscaled scene units.
[[nodiscard]] std::vector<NifMeshData> decode_nif_meshes(const std::vector<std::uint8_t>& bytes);
[[nodiscard]] NifAssetData decode_nif_asset(const std::vector<std::uint8_t>& bytes);

} // namespace oblivion
