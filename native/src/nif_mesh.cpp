/*
 * NIF geometry bridge built on nifly, Copyright (C) 2020-2026 ousnius and
 * contributors. nifly is GPL-3.0; its full license is in extern/nifly/LICENSE.
 * This file converts parsed static geometry into engine-neutral arrays.
 */
#include "oblivion/nif_mesh.hpp"

#include <algorithm>
#include <cctype>
#include <cmath>
#include <istream>
#include <stdexcept>
#include <streambuf>
#include <unordered_map>
#include <unordered_set>

#include <Geometry.hpp>
#include <Animation.hpp>
#include <ExtraData.hpp>
#include <bhk.hpp>
#include <ExtraData.hpp>
#include <Nodes.hpp>
#include <Skin.hpp>

namespace oblivion {
namespace {

// Oblivion's chain NIF maps BHK body spacing to NiNode spacing at 1:7.
constexpr float kHavokToGameUnits = 7.0f;

bool starts_with_case_insensitive(std::string_view value, std::string_view prefix) {
    if (value.size() < prefix.size()) return false;
    for (std::size_t index = 0; index < prefix.size(); ++index) {
        const auto value_char = static_cast<unsigned char>(value[index]);
        const auto prefix_char = static_cast<unsigned char>(prefix[index]);
        if (std::tolower(value_char) != std::tolower(prefix_char)) return false;
    }
    return true;
}

bool is_editor_marker_geometry(std::string_view name) {
    return starts_with_case_insensitive(name, "EditorMarker") ||
           starts_with_case_insensitive(name, "VisibilityEditorMarker");
}

bool root_has_editor_marker_flag(nifly::NifFile& file, nifly::NiAVObject& root) {
    for (const auto& extra_data_ref : root.extraDataRefs) {
        const auto* flags = file.GetHeader().GetBlock<nifly::BSXFlags>(extra_data_ref);
        if (flags && (flags->integerData & nifly::BSX_EDITOR_MARKER) != 0) return true;
    }
    return false;
}

bool root_has_havok_flag(nifly::NifFile& file, nifly::NiAVObject& root) {
    for (const auto& extra_data_ref : root.extraDataRefs) {
        const auto* flags = file.GetHeader().GetBlock<nifly::BSXFlags>(extra_data_ref);
        if (flags && (flags->integerData & nifly::BSX_HAVOK) != 0) return true;
    }
    return false;
}

std::array<float, 3> to_godot(const nifly::Vector3& value) {
    return {value.x, value.z, -value.y};
}

std::array<float, 4> to_godot(const nifly::Quaternion& value) {
    // NIF Z-up vectors map to Godot Y-up as (x, z, -y). The same basis
    // conjugation remaps the vector part of a unit quaternion.
    return {value.x, value.z, -value.y, value.w};
}

// Read-only view over caller-owned bytes. It lets nifly parse the asset
// without copying it into an intermediate string.
class MemoryStreambuf final : public std::streambuf {
public:
    MemoryStreambuf(const std::uint8_t* data, std::size_t size) {
        auto* begin = const_cast<char*>(reinterpret_cast<const char*>(data));
        setg(begin, begin, begin + size);
    }

protected:
    pos_type seekoff(off_type offset, std::ios_base::seekdir direction, std::ios_base::openmode) override {
        const off_type size = egptr() - eback();
        off_type base = 0;
        switch (direction) {
        case std::ios_base::beg: base = 0; break;
        case std::ios_base::cur: base = gptr() - eback(); break;
        case std::ios_base::end: base = size; break;
        default: return pos_type(off_type(-1));
        }
        const off_type target = base + offset;
        if (target < 0 || target > size) return pos_type(off_type(-1));
        setg(eback(), eback() + target, egptr());
        return pos_type(target);
    }

    pos_type seekpos(pos_type position, std::ios_base::openmode mode) override {
        return seekoff(off_type(position), std::ios_base::beg, mode);
    }
};

using GlobalTransforms = std::unordered_map<const nifly::NiAVObject*, nifly::MatTransform>;
using ParentMap = std::unordered_map<const nifly::NiAVObject*, const nifly::NiNode*>;

// One pass over the blocks: child -> first node that lists it (the same answer
// NifFile::GetParentNode gives, without a full scan per lookup).
ParentMap build_parent_map(nifly::NifFile& file) {
    ParentMap parents;
    auto& header = file.GetHeader();
    const auto block_count = header.GetNumBlocks();
    for (uint32_t block_index = 0; block_index < block_count; ++block_index) {
        auto* node = header.GetBlock<nifly::NiNode>(block_index);
        if (!node) continue;
        for (const auto& child_ref : node->childRefs) {
            if (child_ref.IsEmpty()) continue;
            const auto* child = header.GetBlock<nifly::NiAVObject>(child_ref.index);
            if (child) parents.emplace(child, node);
        }
    }
    return parents;
}

// Composes transforms down the parent chain, iteratively so a malformed deep
// chain cannot overflow the stack. Results are keyed by block pointer, not node
// name, so duplicate names in one NIF resolve correctly. A parent cycle ends
// the walk at the first repeated block.
nifly::MatTransform global_transform(const ParentMap& parents, const nifly::NiAVObject* object,
                                     GlobalTransforms& cache) {
    nifly::MatTransform identity;
    identity.Clear();
    if (!object) return identity;
    std::vector<const nifly::NiAVObject*> chain;
    std::unordered_set<const nifly::NiAVObject*> seen;
    nifly::MatTransform base = identity;
    for (const auto* current = object; current;) {
        if (const auto cached = cache.find(current); cached != cache.end()) {
            base = cached->second;
            break;
        }
        if (!seen.insert(current).second) break;
        chain.push_back(current);
        const auto parent = parents.find(current);
        current = parent == parents.end() ? nullptr : parent->second;
    }
    for (auto it = chain.rbegin(); it != chain.rend(); ++it) {
        base = base.ComposeTransforms((*it)->GetTransformToParent());
        cache[*it] = base;
    }
    return cache.find(object) != cache.end() ? cache[object] : base;
}

void append_shape(nifly::NifFile& file, nifly::NiShape& shape,
                  const nifly::MatTransform& transform,
                  const nifly::MatTransform& parent_transform,
                  std::string_view parent_node_name,
                  NifMeshData& output) {
    auto* geometry = shape.GetGeomData();
    if (!geometry || geometry->vertices.empty()) return;

    output.name = shape.name.get();
    output.parent_node_name = parent_node_name;
    file.GetTextureSlot(&shape, output.diffuse_texture_path, 0);
    if (const auto* alpha = file.GetAlphaProperty(&shape)) {
        output.alpha_blend = (alpha->flags & 0x0001U) != 0;
        output.alpha_test = (alpha->flags & 0x0200U) != 0;
        output.alpha_threshold = alpha->threshold;
    }
    output.vertices.reserve(geometry->vertices.size());
    output.parent_local_vertices.reserve(geometry->vertices.size());
    const auto parent_inverse = parent_transform.InverseTransform();
    for (const auto& vertex : geometry->vertices) {
        const auto world_vertex = transform.ApplyTransform(vertex);
        output.vertices.push_back(to_godot(world_vertex));
        output.parent_local_vertices.push_back(to_godot(parent_inverse.ApplyTransform(world_vertex)));
    }

    // Normals and UVs must match the vertex count for the consumer's parallel arrays. A
    // present-but-wrong-length array is padded or truncated; an absent one stays empty.
    if (!geometry->normals.empty()) {
        output.normals.reserve(geometry->vertices.size());
        output.parent_local_normals.reserve(geometry->vertices.size());
        for (std::size_t i = 0; i < geometry->vertices.size(); ++i) {
            const nifly::Vector3 normal = i < geometry->normals.size() ? geometry->normals[i]
                                                                       : nifly::Vector3(0.0f, 0.0f, 1.0f);
            const auto world_normal = transform.ApplyTransformToDir(normal);
            output.normals.push_back(to_godot(world_normal));
            output.parent_local_normals.push_back(to_godot(parent_inverse.ApplyTransformToDir(world_normal)));
        }
    }

    if (!geometry->uvSets.empty() && !geometry->uvSets.front().empty()) {
        const auto& uvs = geometry->uvSets.front();
        output.uvs.reserve(geometry->vertices.size());
        for (std::size_t i = 0; i < geometry->vertices.size(); ++i)
            output.uvs.push_back(i < uvs.size() ? std::array<float, 2>{uvs[i].u, uvs[i].v}
                                                : std::array<float, 2>{0.0f, 0.0f});
    }

    std::vector<nifly::Triangle> triangles;
    geometry->GetTriangles(triangles);
    output.indices.reserve(triangles.size() * 3);
    const auto vertex_count = geometry->vertices.size();
    for (const auto& triangle : triangles) {
        // A triangle that refers past the vertex array is dropped whole.
        if (triangle.p1 >= vertex_count || triangle.p2 >= vertex_count || triangle.p3 >= vertex_count) continue;
        output.indices.push_back(triangle.p1);
        output.indices.push_back(triangle.p2);
        output.indices.push_back(triangle.p3);
    }

    file.GetShapeBoneList(&shape, output.bone_names);
    if (!output.bone_names.empty()) {
        struct Influence { float weight = 0.0f; int32_t bone = 0; };
        std::vector<std::array<Influence, 4>> influences(output.vertices.size());
        for (uint32_t bone_index = 0; bone_index < output.bone_names.size(); ++bone_index) {
            std::unordered_map<uint16_t, float> weights;
            file.GetShapeBoneWeights(&shape, bone_index, weights);
            for (const auto& [vertex_index, weight] : weights) {
                if (vertex_index >= influences.size() || weight <= 0.0f) continue;
                auto& slots = influences[vertex_index];
                for (std::size_t slot = 0; slot < slots.size(); ++slot) {
                    if (weight <= slots[slot].weight) continue;
                    for (std::size_t move = slots.size() - 1; move > slot; --move)
                        slots[move] = slots[move - 1];
                    slots[slot] = {weight, static_cast<int32_t>(bone_index)};
                    break;
                }
            }
        }
        output.bone_indices.reserve(output.vertices.size() * 4);
        output.bone_weights.reserve(output.vertices.size() * 4);
        for (const auto& slots : influences) {
            float total = 0.0f;
            for (const auto& slot : slots) total += slot.weight;
            for (const auto& slot : slots) {
                output.bone_indices.push_back(slot.bone);
                output.bone_weights.push_back(total > 0.0f ? slot.weight / total : 0.0f);
            }
        }
    }
}

// Depth-first, pre-order traversal with an explicit stack (children are visited in
// order), so a deep chain in a malformed NIF cannot overflow the stack.
void visit_scene(nifly::NifFile& file, nifly::NiAVObject* root, bool has_editor_markers,
                 std::vector<NifMeshData>& meshes) {
    struct Frame {
        nifly::NiAVObject* object;
        nifly::MatTransform parent_transform;
        std::string parent_node_name;
    };
    nifly::MatTransform identity;
    identity.Clear();
    std::unordered_set<const nifly::NiAVObject*> visited;
    std::vector<Frame> stack;
    stack.push_back({root, identity, {}});
    while (!stack.empty()) {
        Frame frame = std::move(stack.back());
        stack.pop_back();
        auto* object = frame.object;
        if (!object || !visited.insert(object).second) continue;
        const auto world_transform = frame.parent_transform.ComposeTransforms(object->transform);

        if (auto* shape = dynamic_cast<nifly::NiShape*>(object)) {
            NifMeshData mesh;
            append_shape(file, *shape, world_transform, frame.parent_transform, frame.parent_node_name, mesh);
            mesh.editor_marker = has_editor_markers && is_editor_marker_geometry(mesh.name);
            if (mesh.vertices.size() >= 3 && mesh.indices.size() >= 3)
                meshes.push_back(std::move(mesh));
        }

        if (auto* node = dynamic_cast<nifly::NiNode*>(object)) {
            const std::string node_name = node->name.get();
            const auto first_child = stack.size();
            for (const auto& child_ref : node->childRefs) {
                if (child_ref.IsEmpty()) continue;
                auto* child = file.GetHeader().GetBlock<nifly::NiAVObject>(child_ref.index);
                if (child) stack.push_back({child, world_transform, node_name});
            }
            std::reverse(stack.begin() + static_cast<std::ptrdiff_t>(first_child), stack.end());
        }
    }
}

// Linear sample of a float key group, clamped at both ends.
float sample_keys(const nifly::NiAnimationKeyGroup<float>& group, float time) {
    const auto count = group.GetNumKeys();
    if (count == 0) return 0.0f;
    auto first = group.GetKey(0);
    if (time <= first.time || count == 1) return first.value;
    for (uint32_t i = 1; i < count; ++i) {
        const auto next = group.GetKey(static_cast<int>(i));
        if (time <= next.time) {
            const auto previous = group.GetKey(static_cast<int>(i - 1));
            const float span = next.time - previous.time;
            if (span <= 0.0f) return next.value;
            return previous.value + (next.value - previous.value) * ((time - previous.time) / span);
        }
    }
    return group.GetKey(static_cast<int>(count - 1)).value;
}

// Converts separate X/Y/Z Euler key groups (XYZ_ROTATION_KEY, where quaternionKeys is
// empty) into quaternion keys at the union of the key times. The rotation is
// Rz * Ry * Rx (X applied first), the order Gamebryo uses. Returns false when the
// data holds no Euler keys.
bool euler_rotation_keys(const nifly::NiKeyframeData& data, std::vector<std::array<float, 5>>& out) {
    if (!data.quaternionKeys.empty()) return false;
    const nifly::NiAnimationKeyGroup<float>* groups[3] = {&data.xRotations, &data.yRotations, &data.zRotations};
    std::vector<float> times;
    for (const auto* group : groups)
        for (uint32_t i = 0; i < group->GetNumKeys(); ++i) times.push_back(group->GetKey(static_cast<int>(i)).time);
    if (times.empty()) return false;
    std::sort(times.begin(), times.end());
    times.erase(std::unique(times.begin(), times.end()), times.end());
    struct Q { float w, x, y, z; };
    const auto multiply = [](const Q& a, const Q& b) {
        return Q{a.w * b.w - a.x * b.x - a.y * b.y - a.z * b.z,
                 a.w * b.x + a.x * b.w + a.y * b.z - a.z * b.y,
                 a.w * b.y - a.x * b.z + a.y * b.w + a.z * b.x,
                 a.w * b.z + a.x * b.y - a.y * b.x + a.z * b.w};
    };
    for (const float time : times) {
        const float half_x = sample_keys(data.xRotations, time) * 0.5f;
        const float half_y = sample_keys(data.yRotations, time) * 0.5f;
        const float half_z = sample_keys(data.zRotations, time) * 0.5f;
        const Q qx{std::cos(half_x), std::sin(half_x), 0.0f, 0.0f};
        const Q qy{std::cos(half_y), 0.0f, std::sin(half_y), 0.0f};
        const Q qz{std::cos(half_z), 0.0f, 0.0f, std::sin(half_z)};
        const Q q = multiply(qz, multiply(qy, qx));
        const auto value = to_godot(nifly::Quaternion(q.w, q.x, q.y, q.z));
        out.push_back({time, value[0], value[1], value[2], value[3]});
    }
    return true;
}

void copy_transform(const nifly::MatTransform& source, std::array<float, 3>& translation,
                    std::array<float, 9>& rotation_rows, float& scale) {
    translation = to_godot(source.translation);
    for (std::size_t row = 0; row < 3; ++row)
        for (std::size_t column = 0; column < 3; ++column)
            rotation_rows[row * 3 + column] = source.rotation[row][column];
    scale = source.scale;
}

std::array<float, 3> havok_point_to_game_units(const nifly::Vector3& value) {
    const auto converted = to_godot(value);
    return {converted[0] * kHavokToGameUnits,
            converted[1] * kHavokToGameUnits,
            converted[2] * kHavokToGameUnits};
}

void append_physics(nifly::NifFile& file, NifAssetData& result, const ParentMap& parents,
                    GlobalTransforms& global_transforms) {
    auto& header = file.GetHeader();
    const auto block_count = header.GetNumBlocks();
    std::unordered_map<uint32_t, std::string> body_node_names;

    for (uint32_t block_index = 0; block_index < block_count; ++block_index) {
        auto* collision = header.GetBlock<nifly::bhkNiCollisionObject>(block_index);
        if (!collision) continue;
        auto* body = header.GetBlock<nifly::bhkRigidBody>(collision->bodyRef);
        auto* target = header.GetBlock<nifly::NiAVObject>(collision->targetRef);
        if (!body || !target || target->name.get().empty()) continue;

        const auto node_transform = global_transform(parents, target, global_transforms);

        NifPhysicsBodyData output;
        output.block_index = collision->bodyRef.index;
        output.node_name = target->name.get();
        copy_transform(node_transform, output.node_global_translation,
                       output.node_global_rotation_rows, output.node_global_scale);
        output.havok_translation = havok_point_to_game_units(
            {body->translation.x, body->translation.y, body->translation.z});
        output.havok_rotation = {
            body->rotation.x, body->rotation.z, -body->rotation.y, body->rotation.w
        };
        output.mass = body->mass;
        output.linear_damping = body->linearDamping;
        output.angular_damping = body->angularDamping;
        output.gravity_factor = body->gravityFactor;
        output.friction = body->friction;
        output.restitution = body->restitution;
        output.collision_layer = body->collisionFilter.layer;

        if (auto* capsule = header.GetBlock<nifly::bhkCapsuleShape>(body->shapeRef)) {
            output.shape.type = "capsule";
            output.shape.point1 = havok_point_to_game_units(capsule->point1);
            output.shape.point2 = havok_point_to_game_units(capsule->point2);
            output.shape.radius1 = capsule->radius1 * kHavokToGameUnits;
            output.shape.radius2 = capsule->radius2 * kHavokToGameUnits;
        } else if (auto* vertices = header.GetBlock<nifly::bhkConvexVerticesShape>(body->shapeRef)) {
            output.shape.type = "convex_vertices";
            output.shape.vertices.reserve(vertices->verts.size());
            for (const auto& vertex : vertices->verts)
                output.shape.vertices.push_back(havok_point_to_game_units({vertex.x, vertex.y, vertex.z}));
        } else if (auto* sphere = header.GetBlock<nifly::bhkSphereShape>(body->shapeRef)) {
            output.shape.type = "sphere";
            output.shape.radius1 = sphere->radius * kHavokToGameUnits;
        } else {
            continue;
        }
        body_node_names[output.block_index] = output.node_name;
        result.physics_bodies.push_back(std::move(output));
    }

    for (uint32_t block_index = 0; block_index < block_count; ++block_index) {
        auto* ragdoll = header.GetBlock<nifly::bhkRagdollConstraint>(block_index);
        if (!ragdoll || ragdoll->entityRefs.GetSize() < 2) continue;
        const auto body_a = ragdoll->entityRefs.GetBlockRef(0);
        const auto body_b = ragdoll->entityRefs.GetBlockRef(1);
        const auto node_a = body_node_names.find(body_a);
        const auto node_b = body_node_names.find(body_b);
        if (node_a == body_node_names.end() || node_b == body_node_names.end()) continue;

        const auto& desc = ragdoll->ragdoll;
        NifPhysicsConstraintData output;
        output.type = "ragdoll";
        output.body_a_node_name = node_a->second;
        output.body_b_node_name = node_b->second;
        output.pivot_a = havok_point_to_game_units({desc.pivotA.x, desc.pivotA.y, desc.pivotA.z});
        output.pivot_b = havok_point_to_game_units({desc.pivotB.x, desc.pivotB.y, desc.pivotB.z});
        output.twist_axis_a = havok_point_to_game_units({desc.twistA.x, desc.twistA.y, desc.twistA.z});
        output.plane_axis_a = havok_point_to_game_units({desc.planeA.x, desc.planeA.y, desc.planeA.z});
        output.cone_max_angle = desc.coneMaxAngle;
        output.plane_min_angle = desc.planeMinAngle;
        output.plane_max_angle = desc.planeMaxAngle;
        output.twist_min_angle = desc.twistMinAngle;
        output.twist_max_angle = desc.twistMaxAngle;
        output.max_friction = desc.maxFriction;
        result.physics_constraints.push_back(std::move(output));
    }

    // A limited hinge (the bucket hung on the end of its rope): the axis in the first body, a direction perpendicular to
    // it that marks angle zero, and the angle limits around the axis.
    for (uint32_t block_index = 0; block_index < block_count; ++block_index) {
        auto* hinge = header.GetBlock<nifly::bhkLimitedHingeConstraint>(block_index);
        if (!hinge || hinge->entityRefs.GetSize() < 2) continue;
        const auto node_a = body_node_names.find(hinge->entityRefs.GetBlockRef(0));
        const auto node_b = body_node_names.find(hinge->entityRefs.GetBlockRef(1));
        if (node_a == body_node_names.end() || node_b == body_node_names.end()) continue;

        const auto& desc = hinge->limitedHinge;
        NifPhysicsConstraintData output;
        output.type = "limited_hinge";
        output.body_a_node_name = node_a->second;
        output.body_b_node_name = node_b->second;
        output.pivot_a = havok_point_to_game_units({desc.pivotA.x, desc.pivotA.y, desc.pivotA.z});
        output.pivot_b = havok_point_to_game_units({desc.pivotB.x, desc.pivotB.y, desc.pivotB.z});
        output.twist_axis_a = havok_point_to_game_units({desc.axleA.x, desc.axleA.y, desc.axleA.z});
        output.plane_axis_a = havok_point_to_game_units({desc.axleInA1.x, desc.axleInA1.y, desc.axleInA1.z});
        output.plane_min_angle = desc.minAngle;
        output.plane_max_angle = desc.maxAngle;
        output.max_friction = desc.maxFriction;
        result.physics_constraints.push_back(std::move(output));
    }
}

// Uniform cubic B-spline with clamped (open) knots, as Gamebryo's NiBSplineBasis evaluates it: `x` runs over [0, n - 3]
// and the curve passes through the first and last control point.
std::array<float, 4> bspline_sample(const std::vector<std::array<float, 4>>& points, float x) {
    constexpr int degree = 3;
    const int count = static_cast<int>(points.size());
    const auto knot = [count](int index) { return static_cast<float>(std::clamp(index - degree, 0, count - degree)); };
    x = std::clamp(x, 0.0f, static_cast<float>(count - degree));
    const int span = std::min(static_cast<int>(std::floor(x)) + degree, count - 1);
    float basis[degree + 1];
    float left[degree + 1];
    float right[degree + 1];
    basis[0] = 1.0f;
    for (int j = 1; j <= degree; ++j) {
        left[j] = x - knot(span + 1 - j);
        right[j] = knot(span + j) - x;
        float saved = 0.0f;
        for (int r = 0; r < j; ++r) {
            const float denominator = right[r + 1] + left[j - r];
            const float temp = denominator != 0.0f ? basis[r] / denominator : 0.0f;
            basis[r] = saved + right[r + 1] * temp;
            saved = left[j - r] * temp;
        }
        basis[j] = saved;
    }
    std::array<float, 4> result{};
    for (int k = 0; k <= degree; ++k)
        for (std::size_t component = 0; component < 4; ++component)
            result[component] += basis[k] * points[static_cast<std::size_t>(span - degree + k)][component];
    return result;
}

// Decodes one channel of a NiBSplineTransformInterpolator into control points. `components` is 3 (translation),
// 4 (rotation, stored w,x,y,z) or 1 (scale). Compressed interpolators keep int16 control points that map to
// bias + value / 32767 * multiplier. Returns false when the channel has no spline data.
bool bspline_control_points(nifly::NiBSplineData& data,
                            std::uint32_t control_count, std::uint32_t offset, std::size_t components, float bias,
                            float multiplier, bool compressed, std::vector<std::array<float, 4>>& out) {
    constexpr std::uint32_t kNoOffset = 0xFFFFFFFFu;
    if (offset == kNoOffset || control_count < 4) return false;
    const std::size_t available = compressed ? data.shortControlPoints.size() : data.floatControlPoints.size();
    if (static_cast<std::size_t>(offset) + static_cast<std::size_t>(control_count) * components > available) return false;
    out.assign(control_count, {});
    for (std::uint32_t point = 0; point < control_count; ++point) {
        for (std::size_t component = 0; component < components; ++component) {
            const std::size_t index = static_cast<std::size_t>(offset) + point * components + component;
            out[point][component] = compressed
                ? bias + static_cast<float>(data.shortControlPoints[index]) / 32767.0f * multiplier
                : data.floatControlPoints[index];
        }
    }
    return true;
}

NifAssetData decode_nif(const std::vector<std::uint8_t>& bytes, bool geometry_only) {
    nifly::NifFile file;
    load_nif_file(bytes, file);

    NifAssetData result;
    GlobalTransforms global_transforms;
    const ParentMap parents = geometry_only ? ParentMap{} : build_parent_map(file);
    if (!geometry_only) {
        for (auto* node : file.GetNodes()) {
            NifNodeData output;
            output.name = node->name.get();
            if (const auto parent = parents.find(node); parent != parents.end())
                output.parent_name = parent->second->name.get();
            for (const auto& extra_data_ref : node->extraDataRefs) {
                const auto* extra_data = file.GetHeader().GetBlock<nifly::NiStringExtraData>(extra_data_ref);
                if (!extra_data || extra_data->name.get() != "Prn") continue;
                output.parent_reference_node = extra_data->stringData.get();
                break;
            }
            output.translation = to_godot(node->transform.translation);
            for (std::size_t row = 0; row < 3; ++row)
                for (std::size_t column = 0; column < 3; ++column)
                    output.rotation_rows[row * 3 + column] = node->transform.rotation[row][column];
            output.scale = node->transform.scale;
            copy_transform(global_transform(parents, node, global_transforms), output.global_translation,
                           output.global_rotation_rows, output.global_scale);
            result.nodes.push_back(std::move(output));
        }
    }

    for (uint32_t block_index = 0; block_index < file.GetHeader().GetNumBlocks(); ++block_index) {
        auto* sequence = file.GetHeader().GetBlock<nifly::NiControllerSequence>(block_index);
        if (!sequence) continue;
        NifAnimationData animation;
        animation.name = sequence->name.get();
        animation.start_time = sequence->startTime;
        animation.stop_time = sequence->stopTime;
        animation.cycle_type = static_cast<std::uint32_t>(sequence->cycleType);
        if (auto* text_keys = file.GetHeader().GetBlock<nifly::NiTextKeyExtraData>(sequence->textKeyRef)) {
            for (const auto& key : text_keys->textKeys) animation.text_keys.emplace_back(key.time, key.value.get());
        }
        for (const auto& link : sequence->controlledBlocks) {
            if (auto* spline = file.GetHeader().GetBlock<nifly::NiBSplineTransformInterpolator>(link.interpolatorRef)) {
                NifAnimationTrackData track;
                track.node_name = link.nodeName.get();
                if (track.node_name.empty())
                    track.node_name = nif_string_palette_entry(file.GetHeader(), link.stringPaletteRef, link.nodeNameOffset);
                if (track.node_name.empty())
                    track.node_name = nif_string_palette_entry(file.GetHeader(), sequence->stringPaletteRef, link.nodeNameOffset);
                if (track.node_name.empty()) track.node_name = link.targetName.get();
                auto* spline_data = file.GetHeader().GetBlock<nifly::NiBSplineData>(spline->splineDataRef);
                const auto* basis_data = file.GetHeader().GetBlock<nifly::NiBSplineBasisData>(spline->basisDataRef);
                if (track.node_name.empty() || !spline_data || !basis_data) continue;
                const auto* compressed = dynamic_cast<const nifly::NiBSplineCompTransformInterpolator*>(spline);
                const bool is_compressed = compressed != nullptr;
                const std::uint32_t control_count = basis_data->numControlPoints;
                const float start = spline->startTime;
                const float stop = spline->stopTime > spline->startTime ? spline->stopTime : sequence->stopTime;
                const float duration = std::max(stop - start, 0.0f);
                const std::size_t key_count = std::max<std::size_t>(2, static_cast<std::size_t>(std::ceil(duration * 30.0f)) + 1);
                const auto key_time = [&](std::size_t index) {
                    return start + duration * static_cast<float>(index) / static_cast<float>(key_count - 1);
                };
                const auto curve_x = [&](std::size_t index) {
                    return static_cast<float>(index) / static_cast<float>(key_count - 1) * static_cast<float>(control_count - 3);
                };
                std::vector<std::array<float, 4>> points;
                if (bspline_control_points(*spline_data, control_count, spline->translationOffset, 3,
                                           compressed ? compressed->translationBias : 0.0f,
                                           compressed ? compressed->translationMultiplier : 0.0f, is_compressed, points)) {
                    for (std::size_t index = 0; index < key_count; ++index) {
                        const auto value = bspline_sample(points, curve_x(index));
                        const auto converted = to_godot(nifly::Vector3(value[0], value[1], value[2]));
                        track.translations.push_back({key_time(index), converted[0], converted[1], converted[2]});
                    }
                } else if (std::abs(spline->translation.x) < 1.0e30f && std::abs(spline->translation.y) < 1.0e30f &&
                           std::abs(spline->translation.z) < 1.0e30f) {
                    const auto converted = to_godot(spline->translation);
                    track.translations.push_back({start, converted[0], converted[1], converted[2]});
                    if (stop > start) track.translations.push_back({stop, converted[0], converted[1], converted[2]});
                }
                if (bspline_control_points(*spline_data, control_count, spline->rotationOffset, 4,
                                           compressed ? compressed->rotationBias : 0.0f,
                                           compressed ? compressed->rotationMultiplier : 0.0f, is_compressed, points)) {
                    for (std::size_t index = 0; index < key_count; ++index) {
                        auto value = bspline_sample(points, curve_x(index));
                        const float length = std::sqrt(value[0] * value[0] + value[1] * value[1] + value[2] * value[2] + value[3] * value[3]);
                        if (length > 0.0f)
                            for (auto& component : value) component /= length;
                        // Stored as w,x,y,z.
                        const auto converted = to_godot(nifly::Quaternion(value[0], value[1], value[2], value[3]));
                        track.rotations.push_back({key_time(index), converted[0], converted[1], converted[2], converted[3]});
                    }
                } else {
                    const auto& value = spline->rotation;
                    if (std::abs(value.w) < 1.0e30f && std::abs(value.x) < 1.0e30f && std::abs(value.y) < 1.0e30f &&
                        std::abs(value.z) < 1.0e30f) {
                        const auto converted = to_godot(value);
                        track.rotations.push_back({start, converted[0], converted[1], converted[2], converted[3]});
                        if (stop > start) track.rotations.push_back({stop, converted[0], converted[1], converted[2], converted[3]});
                    }
                }
                if (bspline_control_points(*spline_data, control_count, spline->scaleOffset, 1,
                                           compressed ? compressed->scaleBias : 0.0f,
                                           compressed ? compressed->scaleMultiplier : 0.0f, is_compressed, points)) {
                    for (std::size_t index = 0; index < key_count; ++index)
                        track.scales.push_back({key_time(index), bspline_sample(points, curve_x(index))[0]});
                } else if (std::abs(spline->scale) < 1.0e30f && spline->scale > 0.0f) {
                    track.scales.push_back({start, spline->scale});
                    if (stop > start) track.scales.push_back({stop, spline->scale});
                }
                if (!track.translations.empty() || !track.rotations.empty() || !track.scales.empty())
                    animation.tracks.push_back(std::move(track));
                continue;
            }
            auto* interpolator = file.GetHeader().GetBlock<nifly::NiTransformInterpolator>(link.interpolatorRef);
            if (!interpolator) continue;
            auto* transform_data = file.GetHeader().GetBlock<nifly::NiTransformData>(interpolator->dataRef);
            NifAnimationTrackData track;
            track.node_name = link.nodeName.get();
            if (track.node_name.empty())
                track.node_name = nif_string_palette_entry(file.GetHeader(), link.stringPaletteRef, link.nodeNameOffset);
            if (track.node_name.empty())
                track.node_name = nif_string_palette_entry(file.GetHeader(), sequence->stringPaletteRef, link.nodeNameOffset);
            if (track.node_name.empty()) track.node_name = link.targetName.get();
            if (track.node_name.empty()) continue;
            const auto add_constant_times = [&](float first, float last, auto append) {
                append(first);
                if (last > first) append(last);
            };
            if (transform_data && transform_data->translations.GetNumKeys() > 0) {
                for (uint32_t key_index = 0; key_index < transform_data->translations.GetNumKeys(); ++key_index) {
                    const auto key = transform_data->translations.GetKey(static_cast<int>(key_index));
                    const auto value = to_godot(key.value);
                    track.translations.push_back({key.time, value[0], value[1], value[2]});
                }
            } else {
                const auto& value = interpolator->translation;
                if (std::abs(value.x) < 1.0e30f && std::abs(value.y) < 1.0e30f && std::abs(value.z) < 1.0e30f) {
                    const auto converted = to_godot(value);
                    add_constant_times(sequence->startTime, sequence->stopTime, [&](float time) {
                        track.translations.push_back({time, converted[0], converted[1], converted[2]});
                    });
                }
            }
            if (transform_data && !transform_data->quaternionKeys.empty()) {
                for (const auto& key : transform_data->quaternionKeys) {
                    const auto value = to_godot(key.value);
                    track.rotations.push_back({key.time, value[0], value[1], value[2], value[3]});
                }
            } else if (transform_data && euler_rotation_keys(*transform_data, track.rotations)) {
                // XYZ_ROTATION_KEY data was converted to quaternion keys.
            } else {
                const auto& value = interpolator->rotation;
                if (std::abs(value.w) < 1.0e30f && std::abs(value.x) < 1.0e30f &&
                    std::abs(value.y) < 1.0e30f && std::abs(value.z) < 1.0e30f) {
                    const auto converted = to_godot(value);
                    add_constant_times(sequence->startTime, sequence->stopTime, [&](float time) {
                        track.rotations.push_back({time, converted[0], converted[1], converted[2], converted[3]});
                    });
                }
            }
            if (transform_data && transform_data->scales.GetNumKeys() > 0) {
                for (uint32_t key_index = 0; key_index < transform_data->scales.GetNumKeys(); ++key_index) {
                    const auto key = transform_data->scales.GetKey(static_cast<int>(key_index));
                    track.scales.push_back({key.time, key.value});
                }
            } else if (std::abs(interpolator->scale) < 1.0e30f && interpolator->scale > 0.0f) {
                add_constant_times(sequence->startTime, sequence->stopTime, [&](float time) {
                    track.scales.push_back({time, interpolator->scale});
                });
            }
            if (!track.translations.empty() || !track.rotations.empty() || !track.scales.empty())
                animation.tracks.push_back(std::move(track));
        }
        if (!animation.tracks.empty()) result.animations.push_back(std::move(animation));
    }

    auto* root = file.GetRootNode();
    if (!root) {
        // KF files carry animation sequences without a scene root or geometry.
        if (result.animations.empty()) throw std::runtime_error("NIF has no NiNode root");
        return result;
    }
    // Gamebryo NIFs (including Oblivion's) use BSXFlags bit 1 to mark render geometry as collidable.
    // Older NIFs predate this flag; keep their previous generated-collision behavior.
    result.collision_enabled = file.GetHeader().GetVersion().File() < nifly::NiFileVersion::V10_0_1_0
        || root_has_havok_flag(file, *root);
    visit_scene(file, root, root_has_editor_marker_flag(file, *root), result.meshes);
    if (!geometry_only) append_physics(file, result, parents, global_transforms);
    return result;
}

} // namespace

void load_nif_file(const std::vector<std::uint8_t>& bytes, nifly::NifFile& file) {
    if (bytes.empty()) throw std::runtime_error("NIF asset is empty");
    MemoryStreambuf buffer(bytes.data(), bytes.size());
    std::istream input(&buffer);
    const int load_status = file.Load(input);
    if (load_status != 0 || !file.IsValid())
        throw std::runtime_error("nifly could not load the NIF (status " + std::to_string(load_status) + ")");
}

std::string nif_string_palette_entry(const nifly::NiHeader& header,
                                     const nifly::NiBlockRef<nifly::NiStringPalette>& palette_ref,
                                     std::uint32_t offset) {
    const auto* palette = header.GetBlock<nifly::NiStringPalette>(palette_ref);
    if (!palette || offset >= palette->palette.length()) return {};
    const auto& data = palette->palette.get();
    const auto end = data.find('\0', offset);
    return data.substr(offset, end == std::string::npos ? std::string::npos : end - offset);
}

std::vector<NifMeshData> decode_nif_meshes(const std::vector<std::uint8_t>& bytes) {
    return decode_nif(bytes, true).meshes;
}

NifAssetData decode_nif_asset(const std::vector<std::uint8_t>& bytes) {
    return decode_nif(bytes, false);
}

} // namespace oblivion
