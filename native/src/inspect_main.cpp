#include "oblivion/game_data.hpp"
#include "oblivion/nif_mesh.hpp"

#include <iomanip>
#include <iostream>
#include <algorithm>
#include <array>
#include <fstream>
#include <limits>
#include <sstream>
#include <unordered_map>

#include <Animation.hpp>
#include <Geometry.hpp>
#include <NifFile.hpp>
#include <Nodes.hpp>

namespace {

void usage(const char* executable) {
    std::cerr << "Usage: " << executable << " <Oblivion Data directory> [cell editor ID | --cell-actors cell ID | --find-editor-id EDID | --list-editor-ids prefix | --gmst-prefix prefix | --asset path | --extract asset output | --nif-summary path ... | --rig-summary path ... | --kf-summary path ... | --list-assets prefix]\n";
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

}

int main(int argc, char** argv) {
    const bool inspect_asset = argc == 4 && std::string_view(argv[2]) == "--asset";
    const bool extract_asset = argc == 5 && std::string_view(argv[2]) == "--extract";
    const bool inspect_nif = argc >= 4 && std::string_view(argv[2]) == "--nif-summary";
    const bool inspect_rig = argc >= 4 && std::string_view(argv[2]) == "--rig-summary";
    const bool inspect_kf = argc >= 4 && std::string_view(argv[2]) == "--kf-summary";
    const bool list_assets = argc == 4 && std::string_view(argv[2]) == "--list-assets";
    const bool inspect_actors = argc == 4 && std::string_view(argv[2]) == "--cell-actors";
    const bool lookup_editor_id = argc == 4 && std::string_view(argv[2]) == "--find-editor-id";
    const bool list_editor_ids = argc == 4 && std::string_view(argv[2]) == "--list-editor-ids";
    const bool list_game_settings = argc == 4 && std::string_view(argv[2]) == "--gmst-prefix";
    if (argc < 2 || argc > 20 || (argc > 2 && !inspect_asset && !inspect_nif && !inspect_rig && !inspect_kf && !extract_asset && !list_assets && !inspect_actors && !lookup_editor_id && !list_editor_ids && !list_game_settings && argc != 3)) {
        usage(argv[0]);
        return 2;
    }
    try {
        oblivion::GameData data;
        data.open(argv[1]);
        std::cout << "Loaded " << data.record_count() << " ESM records, " << data.cells().size()
                  << " cells, and " << data.archive_count() << " BSA archives.\n";
        if (extract_asset) {
            const auto asset = data.read_asset(argv[3]);
            std::ofstream output(argv[4], std::ios::binary);
            output.write(reinterpret_cast<const char*>(asset.data()), static_cast<std::streamsize>(asset.size()));
            if (!output) throw std::runtime_error("cannot write extracted asset");
            std::cout << "Extracted " << asset.size() << " bytes to " << argv[4] << ".\n";
            return 0;
        }
        if (argc >= 4) {
            if (lookup_editor_id) {
                const auto form_id = data.find_form_id_by_editor_id(argv[3]);
                if (form_id == 0) {
                    std::cerr << "Editor ID not found: " << argv[3] << '\n';
                    return 1;
                }
                const auto* type = data.find_record_type(form_id);
                const auto* model_path = data.find_item_model_path(form_id, false);
                const auto* female_model_path = data.find_item_model_path(form_id, true);
                std::cout << std::hex << std::setw(8) << std::setfill('0') << form_id << std::dec
                          << " type=" << (type ? *type : "?")
                          << " editor_id=" << argv[3]
                          << " male_model=" << (model_path ? *model_path : "")
                          << " female_model=" << (female_model_path ? *female_model_path : "") << '\n';
                return 0;
            }
            if (list_editor_ids) {
                for (const auto form_id : data.find_form_ids_by_editor_id_prefix(argv[3])) {
                    const auto* editor_id = data.find_editor_id(form_id);
                    const auto* type = data.find_record_type(form_id);
                    const auto* model_path = data.find_item_model_path(form_id, false);
                    const auto* female_model_path = data.find_item_model_path(form_id, true);
                    std::cout << std::hex << std::setw(8) << std::setfill('0') << form_id << std::dec
                              << " type=" << (type ? *type : "?")
                              << " editor_id=" << (editor_id ? *editor_id : "?")
                              << " male_model=" << (model_path ? *model_path : "")
                              << " female_model=" << (female_model_path ? *female_model_path : "") << '\n';
                }
                return 0;
            }
            if (list_game_settings) {
                for (const auto& [setting, value] : data.float_game_settings()) {
                    if (setting.starts_with(argv[3]))
                        std::cout << "GMST " << setting << " = " << value << '\n';
                }
                return 0;
            }
            if (list_assets) {
                std::size_t listed = 0;
                for (const auto& archive_path : data.archive_paths()) {
                    oblivion::BsaArchive archive;
                    archive.open(archive_path);
                    for (const auto& path : archive.list_paths(argv[3])) {
                        std::cout << path << '\n';
                        ++listed;
                    }
                }
                std::cerr << "Listed " << listed << " archived paths under prefix " << argv[3] << ".\n";
                return 0;
            }
            if (inspect_actors) {
                const auto* cell = data.find_cell(argv[3]);
                if (!cell) throw std::runtime_error("cell not found: " + std::string(argv[3]));
                for (const auto& reference : cell->references) {
                    if (reference.record_type != "ACHR" && reference.record_type != "ACRE") continue;
                    std::cout << std::hex << std::setw(8) << std::setfill('0') << reference.form_id
                              << " base=" << std::setw(8) << reference.base_form_id << std::dec
                              << " type=" << reference.record_type << " name=" << reference.reference_name
                              << " pos=" << reference.position[0] << ',' << reference.position[1] << ','
                              << reference.position[2] << " rot=" << reference.rotation[0] << ','
                              << reference.rotation[1] << ',' << reference.rotation[2];
                    if (const auto* npc = data.find_npc_base(reference.base_form_id)) {
                        std::cout << " npc=" << npc->editor_id << " full=" << npc->name
                                  << " race=" << std::hex << npc->race_form_id << std::dec
                                  << " female=" << ((npc->flags & 1) != 0)
                                  << " face=" << npc->face_symmetric.size() << '/' << npc->face_asymmetric.size()
                                  << " hair=" << std::hex << npc->hair_form_id
                                  << " outfit=" << npc->default_outfit_form_id << std::dec
                                  << " inventory=" << npc->inventory.size();
                        if (!npc->face_symmetric.empty()) {
                            const auto [minimum, maximum] = std::minmax_element(
                                npc->face_symmetric.begin(), npc->face_symmetric.end());
                            std::cout << " fggs_range=" << *minimum << ':' << *maximum
                                      << " fggs_first=" << npc->face_symmetric.front();
                        }
                        if (!npc->face_asymmetric.empty()) {
                            const auto [minimum, maximum] = std::minmax_element(
                                npc->face_asymmetric.begin(), npc->face_asymmetric.end());
                            std::cout << " fgga_range=" << *minimum << ':' << *maximum
                                      << " fgga_first=" << npc->face_asymmetric.front();
                        }
                        if (const auto* outfit = data.find_outfit(npc->default_outfit_form_id)) {
                            std::cout << " outfit_items=" << outfit->item_form_ids.size();
                            for (const auto item_id : outfit->item_form_ids) {
                                const auto* editor_id = data.find_editor_id(item_id);
                                const auto* item_type = data.find_record_type(item_id);
                                const auto* model_path = data.find_item_model_path(item_id, (npc->flags & 1) != 0);
                                std::cout << " [" << std::hex << item_id << std::dec << ':'
                                          << (item_type ? *item_type : "?") << ':'
                                          << (editor_id ? *editor_id : "?") << ':'
                                          << "slots=" << std::hex << data.find_item_biped_slots(item_id) << std::dec << ':'
                                          << (model_path ? *model_path : "") << ']';
                            }
                        }
                        std::cout << " items=";
                        for (const auto& item : npc->inventory) {
                            const auto* editor_id = data.find_editor_id(item.form_id);
                            const auto* item_type = data.find_record_type(item.form_id);
                            const auto* model_path = data.find_item_model_path(item.form_id, (npc->flags & 1) != 0);
                            std::cout << " [" << std::hex << item.form_id << std::dec << ':'
                                      << (item_type ? *item_type : "?") << ':'
                                      << (editor_id ? *editor_id : "?") << ':'
                                      << "slots=" << std::hex << data.find_item_biped_slots(item.form_id) << std::dec << ':'
                                      << (model_path ? *model_path : "") << ']';
                        }
                        std::cout << " ai_packages=";
                        for (const auto package_id : npc->ai_package_form_ids) {
                            const auto* package = data.find_ai_package(package_id);
                            if (!package) {
                                std::cout << " [" << std::hex << package_id << std::dec << ":missing]";
                                continue;
                            }
                            std::cout << " [" << std::hex << package->form_id << std::dec << ':'
                                      << package->editor_id << ":type=" << static_cast<int>(package->package_type)
                                      << ":flags=0x" << std::hex << package->flags << std::dec
                                      << ":loc=" << package->location_type << ':' << std::hex
                                      << package->location_form_id << std::dec
                                      << ":radius=" << package->location_radius << ']';
                        }
                    }
                    std::cout << '\n';
                }
                return 0;
            }
            if (inspect_nif) {
                for (int asset_index = 3; asset_index < argc; ++asset_index) {
                    const std::string asset_path = argv[asset_index];
                    const auto source = data.read_asset(asset_path);
                    const auto meshes = oblivion::decode_nif_meshes(source);
                    std::size_t vertex_count = 0;
                    std::size_t triangle_count = 0;
                    std::array<float, 3> bounds_min{std::numeric_limits<float>::max(), std::numeric_limits<float>::max(), std::numeric_limits<float>::max()};
                    std::array<float, 3> bounds_max{std::numeric_limits<float>::lowest(), std::numeric_limits<float>::lowest(), std::numeric_limits<float>::lowest()};
                    for (const auto& mesh : meshes) {
                        vertex_count += mesh.vertices.size();
                        triangle_count += mesh.indices.size() / 3;
                        for (const auto& vertex : mesh.vertices) {
                            for (std::size_t axis = 0; axis < 3; ++axis) {
                                bounds_min[axis] = std::min(bounds_min[axis], vertex[axis]);
                                bounds_max[axis] = std::max(bounds_max[axis], vertex[axis]);
                            }
                        }
                    }
                    std::cout << asset_path << ": decoded " << meshes.size() << " NIF meshes, " << vertex_count
                              << " vertices, " << triangle_count << " triangles, bounds=["
                              << bounds_min[0] << "," << bounds_min[1] << "," << bounds_min[2] << "]..["
                              << bounds_max[0] << "," << bounds_max[1] << "," << bounds_max[2] << "]\n";
                    for (const auto& mesh : meshes)
                        std::cout << "  " << mesh.name << ": " << mesh.vertices.size() << " vertices, "
                                  << mesh.indices.size() / 3 << " triangles, diffuse="
                                  << (mesh.diffuse_texture_path.empty() ? "(none)" : mesh.diffuse_texture_path)
                                  << '\n';
                    const std::string buffer(reinterpret_cast<const char*>(source.data()), source.size());
                    std::istringstream input(buffer, std::ios::binary | std::ios::in);
                    nifly::NifFile file;
                    const int load_status = file.Load(input);
                    if (load_status != 0 || !file.IsValid())
                        throw std::runtime_error("nifly could not reload NIF " + asset_path);
                    for (auto* shape : file.GetShapes()) {
                        std::vector<std::string> bones;
                        file.GetShapeBoneList(shape, bones);
                        if (bones.empty()) continue;
                        std::cout << "  skin " << shape->name.get() << ": " << bones.size() << " bones";
                        for (std::size_t bone_index = 0; bone_index < bones.size(); ++bone_index) {
                            std::unordered_map<uint16_t, float> weights;
                            file.GetShapeBoneWeights(shape, static_cast<uint32_t>(bone_index), weights);
                            std::cout << "\n    " << bones[bone_index] << " weighted_vertices=" << weights.size();
                        }
                        std::cout << '\n';
                    }
                }
                return 0;
            }
            if (inspect_rig) {
                for (int asset_index = 3; asset_index < argc; ++asset_index) {
                    const std::string asset_path = argv[asset_index];
                    const auto bytes = data.read_asset(asset_path);
                    const std::string buffer(reinterpret_cast<const char*>(bytes.data()), bytes.size());
                    std::istringstream input(buffer, std::ios::binary | std::ios::in);
                    nifly::NifFile file;
                    const int load_status = file.Load(input);
                    if (load_status != 0 || !file.IsValid())
                        throw std::runtime_error("nifly could not load rig NIF " + asset_path);
                    std::cout << asset_path << ": " << file.GetNodes().size() << " NiNodes, "
                              << file.GetShapes().size() << " shapes\n";
                    for (auto* node : file.GetNodes()) {
                        const auto* parent = file.GetParentNode(node);
                        const auto& translation = node->transform.translation;
                        std::cout << "  " << node->name.get() << " parent="
                                  << (parent ? parent->name.get() : "(root)")
                                  << " local=" << translation.x << ',' << translation.y << ',' << translation.z << '\n';
                    }
                    for (auto* shape : file.GetShapes()) {
                        std::vector<std::string> bones;
                        file.GetShapeBoneList(shape, bones);
                        std::cout << "  shape " << shape->name.get() << " skinned="
                                  << (shape->IsSkinned() ? "yes" : "no") << " bone_count=" << bones.size() << '\n';
                        nifly::MatTransform global_to_skin;
                        if (file.GetShapeTransformGlobalToSkin(shape, global_to_skin)) {
                            const auto& translation = global_to_skin.translation;
                            std::cout << "    global_to_skin=" << translation.x << ',' << translation.y << ','
                                      << translation.z << " scale=" << global_to_skin.scale << '\n';
                        }
                        for (std::size_t bone_index = 0; bone_index < std::min<std::size_t>(bones.size(), 3); ++bone_index) {
                            nifly::MatTransform skin_to_bone;
                            nifly::MatTransform bone_to_global;
                            if (!file.GetShapeTransformSkinToBone(shape, static_cast<uint32_t>(bone_index), skin_to_bone) ||
                                !file.GetNodeTransformToGlobal(bones[bone_index], bone_to_global)) continue;
                            const auto reconstructed = bone_to_global.ComposeTransforms(skin_to_bone).InverseTransform();
                            const auto& translation = reconstructed.translation;
                            std::cout << "    " << bones[bone_index] << " reconstructed_global_to_skin="
                                      << translation.x << ',' << translation.y << ',' << translation.z
                                      << " scale=" << reconstructed.scale << '\n';
                        }
                    }
                }
                return 0;
            }
            if (inspect_kf) {
                for (int asset_index = 3; asset_index < argc; ++asset_index) {
                    const std::string asset_path = argv[asset_index];
                    const auto bytes = data.read_asset(asset_path);
                    const std::string buffer(reinterpret_cast<const char*>(bytes.data()), bytes.size());
                    std::istringstream input(buffer, std::ios::binary | std::ios::in);
                    nifly::NifFile file;
                    const int load_status = file.Load(input);
                    if (load_status != 0 || !file.IsValid())
                        throw std::runtime_error("nifly could not load KF " + asset_path + " (status " + std::to_string(load_status) + ")");
                    std::cout << asset_path << ": " << file.GetHeader().GetNumBlocks() << " NIF blocks\n";
                    for (uint32_t block_index = 0; block_index < file.GetHeader().GetNumBlocks(); ++block_index) {
                        auto* sequence = file.GetHeader().GetBlock<nifly::NiControllerSequence>(block_index);
                        if (!sequence) continue;
                        std::cout << "  sequence " << sequence->name.get() << " [" << sequence->startTime
                                  << ".." << sequence->stopTime << "] links=" << sequence->controlledBlocks.size() << '\n';
                        for (const auto& link : sequence->controlledBlocks) {
                            auto* interpolator = file.GetHeader().GetBlock<nifly::NiTransformInterpolator>(link.interpolatorRef);
                            if (!interpolator) continue;
                            auto* transform_data = file.GetHeader().GetBlock<nifly::NiTransformData>(interpolator->dataRef);
                            std::string node_name = link.nodeName.get();
                            if (node_name.empty())
                                node_name = palette_string(file.GetHeader(), link.stringPaletteRef, link.nodeNameOffset);
                            std::cout << "    " << (node_name.empty() ? link.targetName.get() : node_name);
                            if (transform_data)
                                std::cout << " translation=" << transform_data->translations.GetNumKeys()
                                          << " quaternion=" << transform_data->quaternionKeys.size()
                                          << " xyz=" << transform_data->xRotations.GetNumKeys() << '/'
                                          << transform_data->yRotations.GetNumKeys() << '/'
                                          << transform_data->zRotations.GetNumKeys();
                            const auto& fallback_translation = interpolator->translation;
                            const auto& fallback_rotation = interpolator->rotation;
                            std::cout << " fallback=" << fallback_translation.x << ',' << fallback_translation.y << ','
                                      << fallback_translation.z << " q=" << fallback_rotation.w << ','
                                      << fallback_rotation.x << ',' << fallback_rotation.y << ',' << fallback_rotation.z
                                      << " s=" << interpolator->scale;
                            std::cout << '\n';
                        }
                    }
                }
                return 0;
            }
            const auto asset = data.read_asset(argv[3]);
            std::cout << "Read " << asset.size() << " bytes from " << argv[3] << ". Header:";
            for (std::size_t i = 0; i < std::min<std::size_t>(asset.size(), 16); ++i)
                std::cout << ' ' << std::hex << std::setw(2) << std::setfill('0')
                          << static_cast<unsigned>(asset[i]);
            std::cout << std::dec << '\n';
            return 0;
        }
        for (const auto& [setting, value] : data.float_game_settings()) {
            if (setting.starts_with("fMoveChar") || setting.starts_with("fJump"))
                std::cout << "GMST " << setting << " = " << value << '\n';
        }
        for (const auto& cell : data.cells()) {
            if (argc == 3 && cell.editor_id != argv[2]) continue;
            std::cout << std::hex << std::setw(8) << std::setfill('0') << cell.form_id << std::dec
                      << "  " << (cell.editor_id.empty() ? "(no editor ID)" : cell.editor_id)
                      << "  " << cell.display_name << "  refs=" << cell.references.size() << '\n';
            for (const auto& reference : cell.references) {
                if (reference.model_path.empty() && !reference.teleport_cell_id) continue;
                std::cout << "    ref " << std::hex << std::setw(8) << std::setfill('0')
                          << reference.form_id << " base=" << std::setw(8) << reference.base_form_id
                          << std::dec << " type=" << reference.record_type
                          << " name=" << reference.reference_name
                          << " base_edid=" << reference.base_editor_id
                          << " pos=" << reference.position[0] << ',' << reference.position[1]
                          << ',' << reference.position[2] << " rot=" << reference.rotation[0] << ','
                          << reference.rotation[1] << ',' << reference.rotation[2]
                          << " model=" << reference.model_path;
                if (reference.teleport_ref_id)
                    std::cout << " teleport_ref=" << std::hex << reference.teleport_ref_id
                              << " cell=" << reference.teleport_cell_id << std::dec
                              << " destination=" << reference.teleport_position[0] << ','
                              << reference.teleport_position[1] << ',' << reference.teleport_position[2];
                std::cout << '\n';
            }
        }
        if (argc == 3 && !data.find_cell(argv[2])) {
            std::cerr << "Cell not found: " << argv[2] << '\n';
            return 1;
        }
        return 0;
    } catch (const std::exception& error) {
        std::cerr << "oblivion-inspect: " << error.what() << '\n';
        return 1;
    }
}
