#include "oblivion/game_data.hpp"
#include "oblivion/nif_mesh.hpp"
#include "oblivion/script_lexer.hpp"
#include "oblivion/command_table.hpp"
#include "oblivion/quest_runtime.hpp"
#include "oblivion/quest_driver.hpp"
#include "oblivion/quest_runtime.hpp"
#include "oblivion/quest_stage.hpp"
#include "oblivion/script_interpreter.hpp"
#include "oblivion/script_parser.hpp"

#include <cctype>
#include <iomanip>
#include <iostream>
#include <algorithm>
#include <array>
#include <fstream>
#include <limits>
#include <map>
#include <sstream>
#include <string>
#include <unordered_map>

#include <Animation.hpp>
#include <Geometry.hpp>
#include <NifFile.hpp>
#include <Nodes.hpp>

namespace {

// Collects every command call (name and argument count) in a statement tree.
std::string lower_name(std::string text) {
    for (auto& c : text) c = static_cast<char>(std::tolower(static_cast<unsigned char>(c)));
    return text;
}

void collect_calls(const oblivion::ScriptExpr& expr, std::vector<const oblivion::ScriptExpr*>& calls) {
    if (expr.kind == oblivion::ScriptExprKind::Call) calls.push_back(&expr);
    for (const auto& child : expr.children) collect_calls(child, calls);
}

void collect_calls(const std::vector<oblivion::ScriptStmt>& statements, std::vector<const oblivion::ScriptExpr*>& calls);

void collect_calls(const oblivion::ScriptStmt& statement, std::vector<const oblivion::ScriptExpr*>& calls) {
    for (const auto& child : statement.children) collect_calls(child, calls);
    for (const auto& branch : statement.branches) {
        collect_calls(branch.condition, calls);
        collect_calls(branch.body, calls);
    }
    collect_calls(statement.else_body, calls);
}

void collect_calls(const std::vector<oblivion::ScriptStmt>& statements, std::vector<const oblivion::ScriptExpr*>& calls) {
    for (const auto& statement : statements) collect_calls(statement, calls);
}

void usage(const char* executable) {
    std::cerr << "Usage: " << executable << " <Oblivion Data directory> [cell EDID | --cell-actors cell EDID | --find-editor-id EDID | --list-editor-ids prefix | --gmst-prefix prefix | --script EDID | --check-scripts | --parse-scripts | --asset path | --extract asset output | --nif-summary path ... | --rig-summary path ... | --kf-summary path ... | --list-assets prefix]\n";
}

// Prints what driver ticks did, and totals the commands they asked for and the functions they could not answer.
class TickReport {
public:
    void add(const oblivion::QuestTick& tick, const std::string& when) {
        for (const auto& action : tick.actions) ++commands_[action.command];
        for (const auto& name : tick.unanswered)
            if (std::find(unanswered_.begin(), unanswered_.end(), name) == unanswered_.end()) unanswered_.push_back(name);
        for (const auto& error : tick.parse_errors) std::cout << when << " parse " << error << '\n';
        if (!tick.stage_changes.empty()) {
            std::cout << when << " stages:";
            for (const auto& change : tick.stage_changes) std::cout << ' ' << change;
            std::cout << '\n';
        }
    }

    void print_totals() const {
        std::cout << "commands:";
        for (const auto& [command, count] : commands_) std::cout << ' ' << command << 'x' << count;
        std::cout << "\nunanswered:";
        for (const auto& name : unanswered_) std::cout << ' ' << name;
        std::cout << '\n';
    }

private:
    std::map<std::string, std::size_t> commands_;
    std::vector<std::string> unanswered_;
};

}

int main(int argc, char** argv) {
    const std::string_view mode = argc > 2 ? std::string_view(argv[2]) : std::string_view{};
    const bool extract_asset = argc == 5 && mode == "--extract";
    const bool inspect_nif = argc >= 4 && mode == "--nif-summary";
    const bool inspect_rig = argc >= 4 && mode == "--rig-summary";
    const bool inspect_kf = argc >= 4 && mode == "--kf-summary";
    const bool single_argument_mode = argc == 4 && (mode == "--asset" || mode == "--list-assets" || mode == "--parse-scripts"
        || mode == "--cell-actors" || mode == "--find-editor-id" || mode == "--list-editor-ids"
        || mode == "--gmst-prefix" || mode == "--script" || mode == "--check-scripts" || mode == "--parse-scripts" || mode == "--commands" || mode == "--check-arity" || mode == "--quest" || mode == "--survey-conditions");
    const bool list_assets = argc == 4 && mode == "--list-assets";
    const bool inspect_actors = argc == 4 && mode == "--cell-actors";
    const bool lookup_editor_id = argc == 4 && mode == "--find-editor-id";
    const bool list_editor_ids = argc == 4 && mode == "--list-editor-ids";
    const bool list_game_settings = argc == 4 && mode == "--gmst-prefix";
    const bool show_script = argc == 4 && mode == "--script";
    const bool show_commands = argc == 4 && mode == "--commands";
    const bool check_arity = argc == 4 && mode == "--check-arity";
    const bool run_script = (argc == 5 || argc == 6) && mode == "--run-script";
    const bool show_quest = (argc == 4 || argc == 5) && mode == "--quest";
    const bool show_source = argc == 5;
    const bool run_stage = argc == 6 && mode == "--run-stage";
    const bool tick_quest = argc == 7 && mode == "--tick-quest";
    const bool tick_world = argc >= 7 && mode == "--tick-world";
    const bool show_topics = argc == 4 && mode == "--topics";
    const bool grep_sources = argc == 4 && mode == "--grep-sources";
    const bool show_packages = (argc == 4 || argc == 5) && mode == "--packages";
    const bool package_done = argc == 8 && mode == "--package-done";
    const bool run_topic = argc >= 10 && mode == "--run-topic";
    const bool survey_conditions = argc == 3 && mode == "--survey-conditions";
    const bool find_placed = argc == 5 && mode == "--find-placed";
    const bool check_scripts = argc == 3 && mode == "--check-scripts";
    const bool parse_scripts = argc == 4 && mode == "--parse-scripts";
    // A bare cell EDID is the only form that takes a single argument without a mode flag.
    const bool valid_arity = argc == 2 || argc == 3 || extract_asset || inspect_nif || inspect_rig
        || inspect_kf || single_argument_mode || run_script || run_stage || survey_conditions || find_placed || show_quest || tick_quest || tick_world || show_topics || grep_sources || show_packages || package_done || run_topic;
    if (argc < 2 || argc > 20 || !valid_arity) {
        usage(argv[0]);
        return 2;
    }
    try {
        oblivion::GameData data;
        data.open(argv[1], oblivion::GameData::LoadProfile::Full, &std::clog);
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
        if (survey_conditions) {
            // Histogram of the condition header byte and of the functions used across all quests.
            std::map<unsigned, std::size_t> operators;
            std::map<unsigned, std::size_t> functions;
            std::size_t total = 0;
            for (const auto& [form_id, quest] : data.quests()) {
                for (const auto& stage : quest.stages)
                    for (const auto& entry : stage.entries)
                        for (const auto& condition : entry.conditions) {
                            ++total;
                            ++operators[condition.operator_code];
                            ++functions[condition.function_index];
                        }
            }
            std::cout << "conditions=" << total << "\noperator bytes:";
            for (const auto& [code, count] : operators) std::cout << " 0x" << std::hex << code << std::dec << "x" << count;
            std::cout << "\nfunctions:";
            for (const auto& [function, count] : functions) std::cout << ' ' << function << 'x' << count;
            std::cout << '\n';
            return 0;
        }
        if (parse_scripts) {
            const auto lookup = oblivion::make_command_lookup(oblivion::load_command_table(argv[3], ".godot/openob/cache"));
            std::size_t scripts_with_errors = 0;
            std::size_t shown = 0;
            for (const auto& [form_id, script] : data.scripts()) {
                const auto ast = oblivion::parse_script(script.source, lookup);
                if (ast.diagnostics.empty()) continue;
                ++scripts_with_errors;
                for (const auto& diagnostic : ast.diagnostics) {
                    ++shown;
                    std::cout << script.editor_id << " line " << diagnostic.line << ": " << diagnostic.message << '\n';
                }
            }
            std::cout << "scripts=" << data.scripts().size() << " scripts_with_diagnostics=" << scripts_with_errors << '\n';
            return 0;
        }
        if (check_scripts) {
            std::size_t total_tokens = 0;
            std::size_t scripts_with_errors = 0;
            for (const auto& [form_id, script] : data.scripts()) {
                const auto tokens = oblivion::tokenize_script(script.source);
                total_tokens += tokens.size();
                bool reported = false;
                for (const auto& token : tokens) {
                    if (token.kind != oblivion::ScriptTokenKind::Error) continue;
                    if (!reported && scripts_with_errors < 20)
                        std::cout << script.editor_id << " line " << token.line << ": " << token.text << '\n';
                    reported = true;
                }
                if (reported) ++scripts_with_errors;
            }
            std::cout << "scripts=" << data.scripts().size() << " tokens=" << total_tokens
                      << " scripts_with_lexical_errors=" << scripts_with_errors << '\n';
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
            if (show_quest) {
                // Prints the subrecords of a quest as read, to confirm their layout against the master.
                const auto* quest = data.find_quest(argv[3]);
                if (!quest) throw std::runtime_error("quest not found: " + std::string(argv[3]));
                std::cout << quest->editor_id << " form=" << std::hex << std::setw(8) << std::setfill('0') << quest->form_id
                          << std::dec << " script=" << std::hex << quest->script_form_id << std::dec
                          << " flags=" << static_cast<unsigned>(quest->flags) << " priority=" << static_cast<unsigned>(quest->priority)
                          << " stages=" << quest->stages.size() << '\n';
                if (const auto* type = data.find_record_type(quest->script_form_id)) std::cout << "script record type " << *type << '\n';
                if (const auto* quest_script = data.find_script(quest->script_form_id)) {
                    std::cout << "quest script " << quest_script->editor_id << " variables:";
                    for (const auto& variable : quest_script->variables) std::cout << ' ' << variable.index << '=' << variable.name;
                    std::cout << '\n';
                }
                for (const auto& stage : quest->stages) {
                    std::cout << "stage " << stage.index << '\n';
                    for (const auto& entry : stage.entries) {
                        std::cout << "  entry" << (entry.completes ? " completes" : "") << '\n';
                        for (const auto& condition : entry.conditions)
                            std::cout << "    if op=" << static_cast<unsigned>(condition.operator_code) << " " << condition.comparison
                                      << " function=" << condition.function_index << " opcode=" << std::hex
                                      << (0x1000u + condition.function_index) << std::dec << " param=" << std::hex
                                      << condition.parameter1 << " param2=" << condition.parameter2 << std::dec << '\n';
                        if (!entry.log_text.empty()) std::cout << "    log: " << entry.log_text << '\n';
                        if (!entry.result_source.empty()) {
                            std::cout << "    result: " << entry.result_source.size() << " bytes of source, "
                                      << entry.result_references.size() << " references\n";
                            if (show_source) {
                                std::istringstream lines(entry.result_source);
                                std::string line;
                                while (std::getline(lines, line)) std::cout << "      | " << line << '\n';
                            }
                        }
                    }
                }
                return 0;
            }
            if (find_placed) {
                // Placed references in a cell whose name matches, including ones without a model (markers).
                // A cell name, or `*` for every cell.
                const std::string wanted_cell = argv[3];
                for (const auto& cell : data.cells()) {
                    if (wanted_cell != "*" && cell.editor_id != wanted_cell) continue;
                    for (const auto& reference : cell.references) {
                        if (reference.reference_name != argv[4]) continue;
                        std::cout << cell.editor_id << " " << std::hex << std::setw(8) << std::setfill('0') << reference.form_id
                                  << std::dec << " type=" << reference.record_type << " name=" << reference.reference_name
                                  << " script=" << (reference.script_form_id ? [&] {
                                         const auto* script = data.find_script(reference.script_form_id);
                                         return (script ? script->editor_id : std::string("?")) + "@" + std::to_string(0);
                                     }() : std::string("none"))
                                  << " pos=" << reference.position[0] << ',' << reference.position[1] << ',' << reference.position[2] << '\n';
                    }
                }
                return 0;
            }
            if (run_topic) {
                // Speaks a topic as the NPC, to a listener of the given race (hex form) and sex, with the quest in
                // a stage and the given quest variables (name=value). Prints the reply and what its result did.
                const auto* quest = data.find_quest(argv[3]);
                if (!quest) throw std::runtime_error("quest not found: " + std::string(argv[3]));
                const auto* quest_script = data.find_script(quest->script_form_id);
                if (!quest_script) throw std::runtime_error("quest has no script");
                const oblivion::DialogTopic* topic = nullptr;
                for (const auto& [topic_id, candidate] : data.topics())
                    if (lower_name(candidate.editor_id) == lower_name(argv[4])) topic = &candidate;
                if (!topic) throw std::runtime_error("topic not found: " + std::string(argv[4]));
                const auto speaker = data.find_form_id_by_editor_id(argv[5]);
                const auto* speaker_npc = data.find_npc_base(speaker);
                if (!speaker_npc) throw std::runtime_error("speaker not found: " + std::string(argv[5]));
                const auto lookup = oblivion::make_command_lookup(oblivion::load_command_table(argv[9], ".godot/openob/cache"));
                oblivion::QuestDriver driver(*quest, *quest_script, lookup);
                driver.start(static_cast<unsigned>(std::stoul(argv[8])));
                for (int index = 10; index < argc; ++index) {
                    const std::string pair = argv[index];
                    const auto equals = pair.find('=');
                    if (equals == std::string::npos) throw std::runtime_error("expected name=value: " + pair);
                    driver.state().variables[lower_name(quest->editor_id) + "." + lower_name(pair.substr(0, equals))] = std::stod(pair.substr(equals + 1));
                }
                oblivion::DialogueContext context;
                context.speaker_base = speaker;
                context.listener_base = 0;
                context.listener_race = static_cast<std::uint32_t>(std::stoul(argv[6], nullptr, 16));
                context.listener_female = std::string(argv[7]) == "female";
                const auto run = driver.run_topic(*topic, context);
                if (!run.reply) {
                    std::cout << "no reply of " << topic->editor_id << " holds\n";
                    return 0;
                }
                std::cout << "reply: " << run.reply->text << '\n';
                std::cout << "stage now " << run.tick.stage << "; stage changes:";
                for (const auto& change : run.tick.stage_changes) std::cout << ' ' << change;
                std::cout << "\nactions:";
                for (const auto& action : run.tick.actions) std::cout << ' ' << action.command;
                std::cout << "\nunanswered:";
                for (const auto& name : run.tick.unanswered) std::cout << ' ' << name;
                std::cout << '\n';
                return 0;
            }
            if (package_done) {
                // Runs OnPackageDone of an NPC's script for one package, with the quest at a stage: prints the
                // stage changes and the quest's actions, so a package's end can be checked against the data.
                const auto* quest = data.find_quest(argv[3]);
                if (!quest) throw std::runtime_error("quest not found: " + std::string(argv[3]));
                const auto npc_id = data.find_form_id_by_editor_id(argv[5]);
                const auto* npc = data.find_npc_base(npc_id);
                const auto* actor_script = npc ? data.find_script(npc->script_form_id) : nullptr;
                if (!actor_script) throw std::runtime_error("NPC has no script: " + std::string(argv[5]));
                const auto* quest_script = data.find_script(quest->script_form_id);
                if (!quest_script) throw std::runtime_error("quest has no script");
                const auto lookup = oblivion::make_command_lookup(oblivion::load_command_table(argv[7], ".godot/openob/cache"));
                oblivion::QuestDriver driver(*quest, *quest_script, lookup);
                driver.start(static_cast<unsigned>(std::stoul(argv[4])));
                const auto tick = driver.run_actor_event(*actor_script, "OnPackageDone", argv[6]);
                std::cout << "stage now " << tick.stage << "; stage changes:";
                for (const auto& change : tick.stage_changes) std::cout << ' ' << change;
                std::cout << "\nactions:";
                for (const auto& action : tick.actions) std::cout << ' ' << action.command;
                std::cout << "\nunanswered:";
                for (const auto& name : tick.unanswered) std::cout << ' ' << name;
                std::cout << '\n';
                return 0;
            }
            if (show_packages) {
                // With a stage, also prints the package EvaluatePackage picks when Charactergen is in that stage.
                class StageAnswerHost final : public oblivion::ScriptHost {
                public:
                    std::uint32_t quest = 0;
                    double stage = 0;
                    std::optional<oblivion::ScriptValue> call_command(std::string_view, const oblivion::ScriptValue*,
                                                                      const std::vector<oblivion::ScriptValue>&) override {
                        return std::nullopt;
                    }
                    std::optional<double> call_condition(std::uint16_t function_index, std::uint32_t parameter1, std::uint32_t) override {
                        if (function_index == 58 && parameter1 == quest) return stage;
                        return std::nullopt;
                    }
                };
                // AI packages of an NPC base record, in the order of its PKID list.
                const auto npc_id = data.find_form_id_by_editor_id(argv[3]);
                const auto* npc = data.find_npc_base(npc_id);
                if (!npc) throw std::runtime_error("NPC not found: " + std::string(argv[3]));
                const auto* npc_script = data.find_script(npc->script_form_id);
                std::vector<const oblivion::AiPackageRecord*> ordered;
                for (const auto package_id : npc->ai_package_form_ids)
                    if (const auto* package = data.find_ai_package(package_id)) ordered.push_back(package);
                if (argc == 5) {
                    const auto* quest = data.find_quest("CharacterGen");
                    StageAnswerHost host;
                    host.quest = quest ? quest->form_id : 0;
                    host.stage = std::stod(argv[4]);
                    const auto* chosen = oblivion::select_package(ordered, host);
                    std::cout << "stage " << argv[4] << ": evp picks " << (chosen ? chosen->editor_id : std::string("nothing")) << '\n';
                }
                std::cout << argv[3] << " form=" << std::hex << npc_id << std::dec << " script=" << (npc_script ? npc_script->editor_id : std::string("none"))
                          << " packages=" << npc->ai_package_form_ids.size() << '\n';
                for (const auto package_id : npc->ai_package_form_ids) {
                    const auto* package = data.find_ai_package(package_id);
                    if (!package) {
                        std::cout << "  " << std::hex << package_id << std::dec << " missing\n";
                        continue;
                    }
                    // PLDT names a placed reference (a marker), so look it up among the cells.
                    std::string location_name = "?";
                    for (const auto& cell : data.cells()) {
                        for (const auto& reference : cell.references)
                            if (reference.form_id == package->location_form_id) location_name = reference.reference_name + "@" + cell.editor_id;
                        if (location_name != "?") break;
                    }
                    std::cout << "  " << package->editor_id << " form=" << std::hex << package_id << std::dec
                              << " type=" << static_cast<unsigned>(package->package_type) << " flags=0x" << std::hex << package->flags << std::dec
                              << " location_type=" << package->location_type << " location=" << location_name
                              << " radius=" << package->location_radius << '\n';
                    for (const auto& condition : package->conditions)
                        std::cout << "    if op=" << static_cast<unsigned>(condition.operator_code) << ' ' << condition.comparison
                                  << " function=" << condition.function_index << " param=" << std::hex << condition.parameter1
                                  << std::dec << " param2=" << condition.parameter2 << '\n';
                }
                return 0;
            }
            if (grep_sources) {
                // Finds a text in every source of the master: scripts, quest stage results and reply results.
                const std::string needle = lower_name(argv[3]);
                const auto report = [&](const std::string& where, const std::string& text) {
                    std::istringstream lines(text);
                    std::string line;
                    std::size_t number = 0;
                    while (std::getline(lines, line)) {
                        ++number;
                        if (lower_name(line).find(needle) != std::string::npos) std::cout << where << " line " << number << ": " << line << '\n';
                    }
                };
                for (const auto& [form_id, script] : data.scripts()) report("script " + script.editor_id, script.source);
                for (const auto& [form_id, quest] : data.quests())
                    for (const auto& stage : quest.stages)
                        for (const auto& entry : stage.entries) report("quest " + quest.editor_id + " stage " + std::to_string(stage.index), entry.result_source);
                for (const auto& [topic_id, topic] : data.topics())
                    for (const auto& response : topic.responses) report("reply of " + topic.editor_id, response.result_source);
                return 0;
            }
            if (show_topics) {
                // Dialogue topics of a quest with their replies, conditions and result scripts.
                // `*` shows the replies of every quest; otherwise only the named quest's replies.
                const bool every_quest = std::string(argv[3]) == "*";
                const auto* quest = every_quest ? nullptr : data.find_quest(argv[3]);
                if (!every_quest && !quest) throw std::runtime_error("quest not found: " + std::string(argv[3]));
                const std::uint32_t wanted_quest = quest ? quest->form_id : 0;
                std::size_t topics_shown = 0;
                // Generic topics (GREETING, HELLO) carry replies of many quests: only the named quest's replies are shown.
                for (const auto& [topic_id, topic] : data.topics()) {
                    std::size_t own = 0;
                    for (const auto& response : topic.responses)
                        if (every_quest || response.quest == wanted_quest) ++own;
                    if (own == 0) continue;
                    ++topics_shown;
                    std::cout << "topic " << topic.editor_id << " (" << topic.name << ") form=" << std::hex << topic_id << std::dec
                              << " replies=" << own << '\n';
                    for (const auto& response : topic.responses) {
                        if (!every_quest && response.quest != wanted_quest) continue;
                        std::cout << "  reply: " << response.text << " [flags=0x" << std::hex << int(response.flags) << std::dec << "]\n";
                        for (const auto& condition : response.conditions)
                            std::cout << "    if op=" << static_cast<unsigned>(condition.operator_code) << ' ' << condition.comparison
                                      << " function=" << condition.function_index << " param=" << std::hex << condition.parameter1
                                      << std::dec << " param2=" << condition.parameter2 << '\n';
                        if (!response.topic_links.empty()) {
                            std::cout << "    leads to:";
                            for (const auto link : response.topic_links) std::cout << ' ' << std::hex << link << std::dec;
                            std::cout << '\n';
                        }
                        if (!response.result_source.empty()) {
                            std::istringstream lines(response.result_source);
                            std::string line;
                            while (std::getline(lines, line)) std::cout << "    | " << line << '\n';
                        }
                    }
                }
                std::cout << "topics=" << topics_shown << '\n';
                return 0;
            }
            if (tick_quest) {
                // Runs the quest driver for N ticks of D seconds with no world answers: distances are unknown
                // and every world command is only recorded. Shows the stages the quest reaches and what stops it.
                const auto* quest = data.find_quest(argv[3]);
                if (!quest) throw std::runtime_error("quest not found: " + std::string(argv[3]));
                const auto* quest_script = data.find_script(quest->script_form_id);
                if (!quest_script) throw std::runtime_error("quest has no script");
                const auto ticks = std::stoi(argv[4]);
                const auto seconds = std::stod(argv[5]);
                const auto lookup = oblivion::make_command_lookup(oblivion::load_command_table(argv[6], ".godot/openob/cache"));
                oblivion::QuestDriver driver(*quest, *quest_script, lookup);
                TickReport report;
                report.add(driver.start(0), "start");
                for (int tick_index = 1; tick_index <= ticks; ++tick_index) {
                    const auto tick = driver.tick(seconds);
                    report.add(tick, "tick " + std::to_string(tick_index));
                }
                std::cout << "final stage " << driver.stage() << "; ";
                report.print_totals();
                return 0;
            }
            if (tick_world) {
                // Runs the quests named EDID:STAGE together, each started at its stage. Every quest with a script is
                // registered, so a stage that sets or starts another quest reaches it. Distances are unknown, as in --tick-quest.
                const auto ticks = std::stoi(argv[3]);
                const auto seconds = std::stod(argv[4]);
                const auto lookup = oblivion::make_command_lookup(oblivion::load_command_table(argv[5], ".godot/openob/cache"));
                oblivion::QuestWorld world(lookup);
                world.set_answer(oblivion::answer_fresh_player);
                world.set_topic_finder([&data](std::string_view editor_id) { return data.find_topic_by_editor_id(editor_id); });
                // The player is an Argonian man here; the game's character creation decides the real one.
                world.set_listener(data.find_form_id_by_editor_id("Argonian"), false);
                for (const auto& [form_id, quest] : data.quests())
                    if (const auto* quest_script = data.find_script(quest.script_form_id)) world.add(quest, *quest_script);
                if (const auto* valen = data.find_npc_base(data.find_form_id_by_editor_id("ValenDreth")))
                    if (const auto* valen_script = data.find_script(valen->script_form_id))
                        world.add_actor(valen->form_id, *valen_script);
                TickReport report;
                std::vector<std::string> named;
                for (int index = 6; index < argc; ++index) {
                    const std::string spec = argv[index];
                    const auto colon = spec.find(':');
                    if (colon == std::string::npos) throw std::runtime_error("expected EDID:STAGE, got " + spec);
                    named.push_back(spec.substr(0, colon));
                    report.add(world.start(named.back(), static_cast<unsigned>(std::stoul(spec.substr(colon + 1)))), spec);
                }
                for (int tick_index = 1; tick_index <= ticks; ++tick_index)
                    report.add(world.tick(seconds), "tick " + std::to_string(tick_index));
                for (const auto& name : named) {
                    const auto* driver = world.find(name);
                    std::cout << name << " stage " << (driver ? driver->stage() : 0) << '\n';
                }
                report.print_totals();
                return 0;
            }
            if (run_stage) {
                // Runs one stage of a quest with the core stage runner and prints what each entry asked for.
                const auto* quest = data.find_quest(argv[3]);
                if (!quest) throw std::runtime_error("quest not found: " + std::string(argv[3]));
                const auto stage_index = static_cast<unsigned>(std::stoul(argv[4]));
                const auto commands = oblivion::load_command_table(argv[5], ".godot/openob/cache");
                const auto lookup = oblivion::make_command_lookup(commands);
                // Condition functions are opcodes minus 0x1000; name them from the table.
                const auto name_of = [&](const std::string& missing) {
                    for (const auto& command : commands)
                        if (missing == "condition " + std::to_string(command.opcode - 0x1000u)) return command.name;
                    return missing;
                };
                oblivion::QuestState state;
                const auto* quest_script = data.find_script(quest->script_form_id);
                const auto runs = oblivion::run_quest_stage(*quest, stage_index, lookup, quest_script, state);
                if (runs.empty()) throw std::runtime_error("stage not found: " + std::string(argv[4]));
                for (const auto& run : runs) {
                    if (!run.conditions_hold) {
                        std::cout << "entry skipped: conditions false";
                        if (!run.missing_conditions.empty()) {
                            std::cout << " (not implemented:";
                            for (const auto& missing : run.missing_conditions) std::cout << ' ' << name_of(missing);
                            std::cout << ')';
                        }
                        std::cout << '\n';
                        continue;
                    }
                    std::cout << "entry" << (run.completes ? " (completes)" : "") << '\n';
                    if (!run.log_text.empty()) std::cout << "  log: " << run.log_text << '\n';
                    for (const auto& error : run.parse_errors) std::cout << "  parse " << error << '\n';
                    for (const auto& action : run.actions) {
                        std::cout << "  ";
                        if (!action.target.empty()) std::cout << action.target << '.';
                        std::cout << action.command << '(';
                        for (std::size_t i = 0; i < action.arguments.size(); ++i) {
                            if (i) std::cout << ", ";
                            if (action.arguments[i].is_text) std::cout << '"' << action.arguments[i].text << '"';
                            else std::cout << action.arguments[i].number;
                        }
                        std::cout << ")\n";
                    }
                }
                return 0;
            }
            if (run_script) {
                // Runs one event with a host that implements no commands: the trace shows the path
                // taken, and the list shows every command the script needs from the game.
                class NothingImplementedHost final : public oblivion::ScriptHost {
                public:
                    std::optional<oblivion::ScriptValue> call_command(std::string_view, const oblivion::ScriptValue*,
                                                                      const std::vector<oblivion::ScriptValue>&) override {
                        return std::nullopt;
                    }
                };
                const auto* record = data.find_script(argv[3]);
                if (!record) throw std::runtime_error("script not found: " + std::string(argv[3]));
                const auto lookup = oblivion::make_command_lookup(oblivion::load_command_table(argv[4], ".godot/openob/cache"));
                const auto ast = oblivion::parse_script(record->source, lookup);
                for (const auto& diagnostic : ast.diagnostics)
                    std::cout << "parse line " << diagnostic.line << ": " << diagnostic.message << '\n';
                const std::string event = argc == 6 ? argv[5] : "GameMode";
                NothingImplementedHost host;
                oblivion::ScriptInterpreter interpreter(ast);
                const auto result = interpreter.run(event, host);
                if (!result.found_block) {
                    std::cout << "no block named " << event << '\n';
                    return 1;
                }
                for (const auto& line : result.trace) std::cout << line << '\n';
                std::cout << "unimplemented:";
                for (const auto& name : result.unimplemented) std::cout << ' ' << name;
                std::cout << "\nreturned=" << (result.returned ? "yes" : "no")
                          << " step_limit_hit=" << (result.step_limit_hit ? "yes" : "no") << '\n';
                return 0;
            }
            if (check_arity) {
                // Compares the argument counts the parser inferred with the executable's command table.
                const auto commands = oblivion::load_command_table(argv[3], ".godot/openob/cache");
                const auto lookup = oblivion::make_command_lookup(commands);
                std::size_t calls = 0, unknown = 0, mismatched = 0, shown = 0;
                for (const auto& [form_id, script] : data.scripts()) {
                    const auto ast = oblivion::parse_script(script.source, lookup);
                    std::vector<const oblivion::ScriptExpr*> found;
                    for (const auto& block : ast.blocks) collect_calls(block.body, found);
                    for (const auto* call : found) {
                        ++calls;
                        const auto signature = lookup(call->text);
                        if (!signature) {
                            ++unknown;
                            continue;
                        }
                        const auto given = call->children.size();
                        if (given >= signature->required_arguments && given <= signature->max_arguments) continue;
                        ++mismatched;
                        if (shown++ < 30)
                            std::cout << script.editor_id << " line " << call->line << ": " << call->text << " given " << given
                                      << ", expects " << signature->required_arguments << ".." << signature->max_arguments << '\n';
                    }
                }
                std::cout << "calls=" << calls << " unknown_commands=" << unknown << " arity_mismatches=" << mismatched << '\n';
                return 0;
            }
            if (show_commands) {
                // The table is read from the executable once and then kept under the project cache.
                const auto commands = oblivion::load_command_table(argv[3], ".godot/openob/cache");
                std::cout << commands.size() << " commands";
                if (!commands.empty())
                    std::cout << ", opcodes " << std::hex << commands.front().opcode << ".." << commands.back().opcode << std::dec;
                std::cout << '\n';
                for (std::size_t index = 0; index < commands.size() && index < 8; ++index) {
                    const auto& command = commands[index];
                    std::cout << std::hex << command.opcode << std::dec << ' ' << command.name << " (" << command.short_name << ")"
                              << (command.needs_parent ? " parent" : "");
                    for (const auto& parameter : command.parameters)
                        std::cout << ' ' << parameter.type_name << (parameter.optional ? "?" : "");
                    std::cout << '\n';
                }
                return 0;
            }
            if (show_script) {
                const auto* script = data.find_script(argv[3]);
                if (!script) throw std::runtime_error("script not found: " + std::string(argv[3]));
                std::cout << script->editor_id << " form=" << std::hex << std::setw(8) << std::setfill('0')
                          << script->form_id << std::dec << " type=" << script->type << " flags=" << script->flags
                          << " variables=" << script->variable_count << " compiled_size=" << script->compiled_size
                          << " referenced=" << script->referenced_form_ids.size() << '\n';
                for (const auto& variable : script->variables)
                    std::cout << "  var " << variable.index << " type=" << variable.type << " name=" << variable.name << '\n';
                for (const auto form_id : script->referenced_form_ids)
                    std::cout << "  ref " << std::hex << std::setw(8) << std::setfill('0') << form_id << std::dec << '\n';
                const auto tokens = oblivion::tokenize_script(script->source);
                std::size_t lexical_errors = 0;
                for (const auto& token : tokens)
                    if (token.kind == oblivion::ScriptTokenKind::Error) {
                        if (lexical_errors == 0) std::cout << "  first lexical error: line " << token.line << ": " << token.text << '\n';
                        ++lexical_errors;
                    }
                std::cout << "  tokens=" << tokens.size() << " lexical_errors=" << lexical_errors << '\n';
                std::cout << "--- source ---\n" << script->source << "\n--- end ---\n";
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
                    nifly::NifFile file;
                    oblivion::load_nif_file(source, file);
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
                    nifly::NifFile file;
                    oblivion::load_nif_file(bytes, file);
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
                    nifly::NifFile file;
                    oblivion::load_nif_file(bytes, file);
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
                                node_name = oblivion::nif_string_palette_entry(file.GetHeader(), link.stringPaletteRef, link.nodeNameOffset);
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
