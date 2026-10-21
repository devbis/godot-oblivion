/*
 * NIF geometry bridge built on nifly, Copyright (C) 2020-2026 ousnius and
 * contributors. nifly is GPL-3.0; its full license is in extern/nifly/LICENSE.
 * This file converts parsed static geometry into engine-neutral arrays.
 */
#include "oblivion/nif_mesh.hpp"

#include <memory>
#include <cmath>
#include <set>
#include <sstream>
#include <stdexcept>
#include <unordered_set>

#include <Geometry.hpp>
#include <Animation.hpp>
#include <NifFile.hpp>
#include <Nodes.hpp>
#include <Skin.hpp>

namespace oblivion {
namespace {

std::array<float, 3> to_godot(const nifly::Vector3& value) {
    return {value.x, value.z, -value.y};
}

std::array<float, 4> to_godot(const nifly::Quaternion& value) {
    // NIF Z-up vectors map to Godot Y-up as (x, z, -y). The same basis
    // conjugation remaps the vector part of a unit quaternion.
    return {value.x, value.z, -value.y, value.w};
}

std::string palette_string(const nifly::NiHeader& header,
                           const nifly::NiBlockRef<nifly::NiStringPalette>& palette_ref,
                           uint32_t offset) {
    const auto* palette = header.GetBlock<nifly::NiStringPalette>(palette_ref);
    if (!palette || offset >= palette->palette.length()) return {};
    const auto& data = palette->palette.get();
    const auto end = data.find('\0', offset);
    return data.substr(offset, end == std::string::npos ? std::string::npos : end - offset);
}

void append_shape(nifly::NifFile& file, nifly::NiShape& shape,
                  const nifly::MatTransform& transform,
                  NifMeshData& output) {
    auto* geometry = shape.GetGeomData();
    if (!geometry || geometry->vertices.empty()) return;

    output.name = shape.name.get();
    file.GetTextureSlot(&shape, output.diffuse_texture_path, 0);
    if (const auto* alpha = file.GetAlphaProperty(&shape)) {
        output.alpha_blend = (alpha->flags & 0x0001U) != 0;
        output.alpha_test = (alpha->flags & 0x0200U) != 0;
        output.alpha_threshold = alpha->threshold;
    }
    output.vertices.reserve(geometry->vertices.size());
    for (const auto& vertex : geometry->vertices)
        output.vertices.push_back(to_godot(transform.ApplyTransform(vertex)));

    if (geometry->normals.size() == geometry->vertices.size()) {
        output.normals.reserve(geometry->normals.size());
        for (const auto& normal : geometry->normals)
            output.normals.push_back(to_godot(transform.ApplyTransformToDir(normal)));
    }

    if (!geometry->uvSets.empty() && geometry->uvSets.front().size() == geometry->vertices.size()) {
        output.uvs.reserve(geometry->uvSets.front().size());
        for (const auto& uv : geometry->uvSets.front()) output.uvs.push_back({uv.u, uv.v});
    }

    std::vector<nifly::Triangle> triangles;
    geometry->GetTriangles(triangles);
    output.indices.reserve(triangles.size() * 3);
    for (const auto& triangle : triangles) {
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

void visit_node(nifly::NifFile& file, nifly::NiAVObject* object,
                const nifly::MatTransform& parent_transform,
                std::unordered_set<const nifly::NiAVObject*>& visited,
                std::vector<NifMeshData>& meshes) {
    if (!object || !visited.insert(object).second) return;
    const auto world_transform = parent_transform.ComposeTransforms(object->transform);

    if (auto* shape = dynamic_cast<nifly::NiShape*>(object)) {
        NifMeshData mesh;
        append_shape(file, *shape, world_transform, mesh);
        if (mesh.vertices.size() >= 3 && mesh.indices.size() >= 3)
            meshes.push_back(std::move(mesh));
    }

    if (auto* node = dynamic_cast<nifly::NiNode*>(object)) {
        for (const auto& child_ref : node->childRefs) {
            if (child_ref.IsEmpty()) continue;
            auto* child = file.GetHeader().GetBlock<nifly::NiAVObject>(child_ref.index);
            visit_node(file, child, world_transform, visited, meshes);
        }
    }
}

} // namespace

std::vector<NifMeshData> decode_nif_meshes(const std::vector<std::uint8_t>& bytes) {
    return decode_nif_asset(bytes).meshes;
}

NifAssetData decode_nif_asset(const std::vector<std::uint8_t>& bytes) {
    if (bytes.empty()) throw std::runtime_error("NIF asset is empty");
    const std::string buffer(reinterpret_cast<const char*>(bytes.data()), bytes.size());
    std::istringstream input(buffer, std::ios::binary | std::ios::in);
    nifly::NifFile file;
    const int load_status = file.Load(input);
    if (load_status != 0 || !file.IsValid())
        throw std::runtime_error("nifly could not load the NIF (status " + std::to_string(load_status) + ")");

    NifAssetData result;
    for (auto* node : file.GetNodes()) {
        NifNodeData output;
        output.name = node->name.get();
        if (const auto* parent = file.GetParentNode(node)) output.parent_name = parent->name.get();
        output.translation = to_godot(node->transform.translation);
        for (std::size_t row = 0; row < 3; ++row)
            for (std::size_t column = 0; column < 3; ++column)
                output.rotation_rows[row * 3 + column] = node->transform.rotation[row][column];
        output.scale = node->transform.scale;
        result.nodes.push_back(std::move(output));
    }

    for (uint32_t block_index = 0; block_index < file.GetHeader().GetNumBlocks(); ++block_index) {
        auto* sequence = file.GetHeader().GetBlock<nifly::NiControllerSequence>(block_index);
        if (!sequence) continue;
        NifAnimationData animation;
        animation.name = sequence->name.get();
        animation.start_time = sequence->startTime;
        animation.stop_time = sequence->stopTime;
        for (const auto& link : sequence->controlledBlocks) {
            auto* interpolator = file.GetHeader().GetBlock<nifly::NiTransformInterpolator>(link.interpolatorRef);
            if (!interpolator) continue;
            auto* transform_data = file.GetHeader().GetBlock<nifly::NiTransformData>(interpolator->dataRef);
            NifAnimationTrackData track;
            track.node_name = link.nodeName.get();
            if (track.node_name.empty())
                track.node_name = palette_string(file.GetHeader(), link.stringPaletteRef, link.nodeNameOffset);
            if (track.node_name.empty())
                track.node_name = palette_string(file.GetHeader(), sequence->stringPaletteRef, link.nodeNameOffset);
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
    nifly::MatTransform identity;
    identity.Clear();
    std::unordered_set<const nifly::NiAVObject*> visited;
    visit_node(file, root, identity, visited, result.meshes);
    return result;
}

} // namespace oblivion
