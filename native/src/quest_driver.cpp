#include "oblivion/quest_driver.hpp"

#include <algorithm>
#include <cctype>

#include "oblivion/quest_runtime.hpp"
#include "oblivion/script_interpreter.hpp"

namespace oblivion {
namespace {

constexpr int kMaxStageDepth = 8;  // stage results may set stages; this bounds the chain

// A distance the world cannot give counts as far away, so a condition that waits for the player to be near stays false.
constexpr double kUnknownDistance = 1.0e9;

// The distance the scene gives between two names. When it cannot, the question is recorded and the distance counts as far away.
double distance_or_far(const DistanceFunction& distance, std::string_view from, std::string_view to, QuestTick& tick) {
    if (distance) {
        if (const auto value = distance(from, to)) return *value;
    }
    tick.unanswered.push_back("getdistance");
    return kUnknownDistance;
}

// The player's reference: the listener of a SayTo and the target of `GetIsID` for the player.
constexpr std::uint32_t kPlayerReference = 0x14;

// A rough length of a spoken line, until the voice files' durations are read: about 14 characters a second.
double speech_seconds(const std::string& text) {
    return std::max(1.0, static_cast<double>(text.size()) / 14.0);
}

// Writes "name.variable" into another quest of the world, or into the actor a reference stands for. Ignored otherwise.
void write_foreign_variable(QuestWorld* world, const std::string& key, double value) {
    if (!world) return;
    const auto dot = key.find('.');
    if (dot == std::string::npos) return;
    const auto name = key.substr(0, dot);
    if (auto* other = world->find(name)) other->state().variables[key] = value;
    else world->set_actor_variable(name, key.substr(dot + 1), value);
}

std::string lower(std::string_view text) {
    std::string result(text);
    for (auto& c : result) c = static_cast<char>(std::tolower(static_cast<unsigned char>(c)));
    return result;
}

} // namespace

// Answers the commands of GameMode and of stage results for one tick.
class QuestTickHost final : public ScriptHost {
public:
    QuestTickHost(QuestDriver& driver, QuestTick& tick, double seconds, const DistanceFunction& distance, int depth)
        : driver_(driver), tick_(tick), seconds_(seconds), distance_(distance), depth_(depth) {}

    ScriptInterpreter* interpreter = nullptr;  // set by the driver; its variables are flushed before nested stages

    std::optional<ScriptValue> call_command(std::string_view name, const ScriptValue* target,
                                            const std::vector<ScriptValue>& arguments) override {
        // `Quest.variable` with no arguments reads that quest's variable.
        if (target && target->is_text && arguments.empty()) {
            if (const auto* quest = find_quest(target->text)) {
                if (const auto value = quest->variable(name)) return ScriptValue::from_number(*value);
            }
        }
        const auto command = lower(name);
        if (command == "getstage" && !arguments.empty() && arguments[0].is_text) {
            if (const auto* quest = find_quest(arguments[0].text)) return ScriptValue::from_number(quest->stage());
        }
        if (command == "getstagedone" && arguments.size() >= 2 && arguments[0].is_text) {
            if (const auto* quest = find_quest(arguments[0].text))
                return ScriptValue::from_number(quest->has_entered(static_cast<unsigned>(arguments[1].number)) ? 1.0 : 0.0);
        }
        if (command == "setstage" && arguments.size() >= 2 && arguments[0].is_text && find_quest(arguments[0].text)) {
            flush_variables();
            const auto stage = static_cast<unsigned>(arguments[1].number);
            if (lower(arguments[0].text) == lower(driver_.quest_.editor_id)) driver_.enter_stage(stage, tick_, distance_, depth_ + 1);
            else driver_.world_->set_stage(arguments[0].text, stage, tick_, distance_, depth_ + 1);
            reload_variables();
            return ScriptValue::from_number(0.0);
        }
        if (command == "startquest" && !arguments.empty() && arguments[0].is_text && driver_.world_ && driver_.world_->find(arguments[0].text)) {
            flush_variables();
            driver_.world_->begin(arguments[0].text, tick_, distance_, depth_ + 1);
            reload_variables();
            return ScriptValue::from_number(0.0);
        }
        if (command == "getsecondspassed") return ScriptValue::from_number(seconds_);
        if (command == "getdistance") {
            const auto from = target && target->is_text ? target->text : std::string("player");
            const auto to = !arguments.empty() && arguments[0].is_text ? arguments[0].text : std::string();
            return ScriptValue::from_number(distance_or_far(distance_, from, to, tick_));
        }
        if (driver_.world_ && driver_.world_->answer()) {
            if (auto value = driver_.world_->answer()(name, target, arguments)) return value;
        }
        // Everything else is a request for the world: recorded and answered with 0.
        ScriptAction action;
        action.command = std::string(name);
        if (target) action.target = target->text;
        action.arguments = arguments;
        tick_.actions.push_back(std::move(action));
        return ScriptValue::from_number(0.0);
    }

    // Writes the GameMode variables into the quest's state (and other quests' variables into theirs), so a stage run sees them.
    void flush_variables() {
        if (!interpreter) return;
        const auto prefix = lower(driver_.quest_.editor_id) + ".";
        for (const auto& [key, value] : interpreter->variables()) {
            if (value.is_text) continue;
            if (key.find('.') == std::string::npos) driver_.state_.variables[prefix + key] = value.number;
            else if (key.compare(0, prefix.size(), prefix) == 0) driver_.state_.variables[key] = value.number;
            else write_foreign_variable(driver_.world_, key, value.number);
        }
    }

    // Reads this quest's variables back into the interpreter after a nested stage ran: the stage may have set them,
    // and the GameMode that continues must see the new values rather than the ones it had before the stage.
    void reload_variables() {
        if (!interpreter) return;
        const auto prefix = lower(driver_.quest_.editor_id) + ".";
        for (const auto& declaration : driver_.script_.variables) {
            const auto found = driver_.state_.variables.find(prefix + lower(declaration.name));
            if (found != driver_.state_.variables.end()) interpreter->set_variable(declaration.name, ScriptValue::from_number(found->second));
        }
    }

private:
    // The quest a name refers to: this quest, or another quest of the same world.
    QuestDriver* find_quest(std::string_view editor_id) {
        if (lower(editor_id) == lower(driver_.quest_.editor_id)) return &driver_;
        return driver_.world_ ? driver_.world_->find(editor_id) : nullptr;
    }

    QuestDriver& driver_;
    QuestTick& tick_;
    double seconds_;
    const DistanceFunction& distance_;
    int depth_;
};

QuestDriver::QuestDriver(const QuestRecord& quest, const ScriptRecord& script, ScriptCommandLookup lookup)
    : quest_(quest), script_(script), lookup_(std::move(lookup)), ast_(parse_script(script.source, lookup_)) {}

QuestTick QuestDriver::start(unsigned stage, const DistanceFunction& distance) {
    QuestTick tick;
    enter_stage(stage, tick, distance, 0);
    tick.stage = stage_;
    return tick;
}

namespace {

// Answers the conditions of a package or topic from the quest's state and from the other quests of its world.
class DriverConditionHost final : public ScriptHost {
public:
    DriverConditionHost(const QuestDriver& self, QuestWorld* world, const DialogueContext* dialogue = nullptr)
        : self_(self), world_(world), dialogue_(dialogue) {}

    std::optional<ScriptValue> call_command(std::string_view, const ScriptValue*, const std::vector<ScriptValue>&) override {
        return std::nullopt;
    }

    std::optional<double> call_condition(std::uint16_t function_index, std::uint32_t parameter1, std::uint32_t parameter2) override {
        constexpr std::uint16_t kGetStage = 58;
        constexpr std::uint16_t kGetStageDone = 59;
        constexpr std::uint16_t kGetQuestVariable = 79;
        if (function_index == kGetStage || function_index == kGetStageDone || function_index == kGetQuestVariable) {
            const auto* quest = find_quest(parameter1);
            if (!quest) return std::nullopt;
            if (function_index == kGetStage) return static_cast<double>(quest->stage());
            if (function_index == kGetStageDone) return quest->has_entered(parameter2) ? 1.0 : 0.0;
            return quest->variable_at(parameter2);
        }
        if (dialogue_) {
            constexpr std::uint16_t kGetIsID = 72;
            constexpr std::uint16_t kGetIsRace = 69;
            constexpr std::uint16_t kGetIsSex = 70;  // param 0 male, 1 female
            if (function_index == kGetIsID)
                return (parameter1 == dialogue_->speaker_base || parameter1 == dialogue_->listener_base) ? 1.0 : 0.0;
            if (function_index == kGetIsRace) return parameter1 == dialogue_->listener_race ? 1.0 : 0.0;
            if (function_index == kGetIsSex) return (parameter1 != 0) == dialogue_->listener_female ? 1.0 : 0.0;
        }
        return std::nullopt;
    }

private:
    // This quest, or a quest of the same world with that form ID.
    const QuestDriver* find_quest(std::uint32_t form_id) const {
        if (self_.quest().form_id == form_id) return &self_;
        return world_ ? world_->find_form(form_id) : nullptr;
    }

    const QuestDriver& self_;
    QuestWorld* world_;
    const DialogueContext* dialogue_;
};

} // namespace

const AiPackageRecord* QuestDriver::select_package(const std::vector<const AiPackageRecord*>& packages) const {
    DriverConditionHost host(*this, world_);
    return oblivion::select_package(packages, host);
}

std::optional<double> QuestDriver::variable(std::string_view name) const {
    const auto wanted = lower(name);
    for (const auto& declaration : script_.variables) {
        if (lower(declaration.name) != wanted) continue;
        const auto found = state_.variables.find(lower(quest_.editor_id) + "." + wanted);
        return found == state_.variables.end() ? 0.0 : found->second;
    }
    return std::nullopt;
}

double QuestDriver::variable_at(std::uint32_t index) const {
    for (const auto& variable : script_.variables) {
        if (variable.index != index) continue;
        const auto found = state_.variables.find(lower(quest_.editor_id) + "." + lower(variable.name));
        return found == state_.variables.end() ? 0.0 : found->second;
    }
    return 0.0;
}

TopicRun QuestDriver::run_topic(const DialogTopic& topic, const DialogueContext& context, const DistanceFunction& distance) {
    TopicRun run;
    DriverConditionHost conditions(*this, world_, &context);
    for (const auto& reply : topic.responses) {
        if (!evaluate_conditions(reply.conditions, conditions)) continue;
        run.reply = &reply;
        break;
    }
    if (!run.reply) {
        run.tick.stage = stage_;
        return run;
    }
    const auto fragment = parse_fragment(run.reply->result_source, lookup_);
    for (const auto& diagnostic : fragment.diagnostics)
        run.tick.parse_errors.push_back("line " + std::to_string(diagnostic.line) + ": " + diagnostic.message);
    const ScriptAst no_script;
    ScriptInterpreter interpreter(no_script);
    QuestTickHost host(*this, run.tick, 0.0, distance, 0);
    host.interpreter = &interpreter;
    interpreter.run_body(fragment.statements, host);
    host.flush_variables();
    run.tick.stage = stage_;
    return run;
}

QuestTick QuestDriver::run_actor_event(const ScriptRecord& actor_script, std::string_view event, std::string_view detail,
                                       const DistanceFunction& distance) {
    QuestTick tick;
    const auto actor_ast = parse_script(actor_script.source, lookup_);
    for (const auto& diagnostic : actor_ast.diagnostics)
        tick.parse_errors.push_back("line " + std::to_string(diagnostic.line) + ": " + diagnostic.message);
    ScriptInterpreter interpreter(actor_ast);
    QuestTickHost host(*this, tick, 0.0, distance, 0);
    host.interpreter = &interpreter;
    const auto result = interpreter.run_event(event, detail, host);
    host.flush_variables();
    for (const auto& name : result.unimplemented) tick.unanswered.push_back(name);
    tick.stage = stage_;
    return tick;
}

QuestTick QuestDriver::tick(double seconds_passed, const DistanceFunction& distance) {
    QuestTick tick;
    ScriptInterpreter interpreter(ast_);
    // The script's declared variables hold the quest's values, which persist across ticks.
    const auto prefix = lower(quest_.editor_id) + ".";
    for (const auto& declaration : script_.variables) {
        const auto found = state_.variables.find(prefix + lower(declaration.name));
        if (found != state_.variables.end()) interpreter.set_variable(declaration.name, ScriptValue::from_number(found->second));
    }
    for (const auto& [key, value] : state_.variables)
        if (key.compare(0, prefix.size(), prefix) == 0) interpreter.set_variable(key, ScriptValue::from_number(value));

    QuestTickHost host(*this, tick, seconds_passed, distance, 0);
    host.interpreter = &interpreter;
    const auto result = interpreter.run("gamemode", host);
    host.flush_variables();
    for (const auto& name : result.unimplemented) tick.unanswered.push_back(name);
    tick.stage = stage_;
    return tick;
}

void QuestDriver::enter_stage(unsigned stage, QuestTick& tick, const DistanceFunction& distance, int depth) {
    if (depth > kMaxStageDepth) {
        tick.parse_errors.push_back("stage chain deeper than " + std::to_string(kMaxStageDepth));
        return;
    }
    stage_ = stage;
    entered_.insert(stage);
    tick.stage_changes.push_back(std::to_string(stage));
    const ForeignVariableReader read_foreign = [this](std::string_view quest, std::string_view variable) -> std::optional<double> {
        const auto* other = world_ ? world_->find(quest) : nullptr;
        return other ? other->variable(variable) : std::nullopt;
    };
    for (const auto& run : run_quest_stage(quest_, stage, lookup_, &script_, state_, read_foreign)) {
        for (const auto& error : run.parse_errors) tick.parse_errors.push_back(error);
        for (const auto& [key, value] : run.foreign_writes) write_foreign_variable(world_, key, value);
        for (const auto& action : run.actions) {
            tick.actions.push_back(action);
            if (action.arguments.empty() || !action.arguments[0].is_text) continue;
            const auto command = lower(action.command);
            // A stage result that sets a stage, here or in another quest, is followed through as well.
            if (command == "setstage" && action.arguments.size() >= 2) {
                const auto next = static_cast<unsigned>(action.arguments[1].number);
                if (lower(action.arguments[0].text) == lower(quest_.editor_id)) enter_stage(next, tick, distance, depth + 1);
                else if (world_) world_->set_stage(action.arguments[0].text, next, tick, distance, depth + 1);
            } else if (command == "startquest" && world_) {
                world_->begin(action.arguments[0].text, tick, distance, depth + 1);
            }
        }
    }
}

QuestWorld::QuestWorld(ScriptCommandLookup lookup) : lookup_(std::move(lookup)) {}

QuestDriver& QuestWorld::add(const QuestRecord& quest, const ScriptRecord& script) {
    drivers_.push_back(std::make_unique<QuestDriver>(quest, script, lookup_));
    drivers_.back()->attach(this);
    return *drivers_.back();
}

QuestDriver* QuestWorld::find(std::string_view editor_id) {
    const auto wanted = lower(editor_id);
    for (const auto& driver : drivers_)
        if (lower(driver->quest().editor_id) == wanted) return driver.get();
    return nullptr;
}

QuestDriver* QuestWorld::find_form(std::uint32_t form_id) {
    for (const auto& driver : drivers_)
        if (driver->quest().form_id == form_id) return driver.get();
    return nullptr;
}

QuestTick QuestWorld::start(std::string_view editor_id, unsigned stage, const DistanceFunction& distance) {
    QuestTick tick;
    auto* driver = find(editor_id);
    if (!driver) {
        tick.parse_errors.push_back("unknown quest " + std::string(editor_id));
        return tick;
    }
    started_.insert(driver);
    driver->enter_stage(stage, tick, distance, 0);
    tick.stage = driver->stage();
    return tick;
}

namespace {

void append_tick(QuestTick& into, const QuestTick& from) {
    into.stage_changes.insert(into.stage_changes.end(), from.stage_changes.begin(), from.stage_changes.end());
    into.actions.insert(into.actions.end(), from.actions.begin(), from.actions.end());
    into.unanswered.insert(into.unanswered.end(), from.unanswered.begin(), from.unanswered.end());
    into.parse_errors.insert(into.parse_errors.end(), from.parse_errors.begin(), from.parse_errors.end());
}

} // namespace

QuestTick QuestWorld::tick(double seconds_passed, const DistanceFunction& distance) {
    QuestTick result;
    for (const auto& driver : drivers_) {
        if (started_.count(driver.get()) == 0) continue;
        append_tick(result, driver->tick(seconds_passed, distance));
    }
    for (const auto& actor : actors_) run_actor_game_mode(*actor, result, seconds_passed, distance);
    return result;
}

void QuestWorld::add_actor(std::uint32_t form_id, const ScriptRecord& script) {
    auto actor = std::make_unique<ActorState>();
    actor->form_id = form_id;
    actor->ast = parse_script(script.source, lookup_);
    actors_.push_back(std::move(actor));
}

void QuestWorld::set_reference_base(std::string_view reference, std::uint32_t base) {
    reference_bases_[lower(reference)] = base;
}

bool QuestWorld::set_actor_variable(std::string_view reference, std::string_view variable, double value) {
    const auto base = reference_base(reference);
    if (!base) return false;
    for (const auto& actor : actors_) {
        if (actor->form_id != *base) continue;
        actor->variables[lower(variable)] = value;
        actor->pending[lower(variable)] = value;
        return true;
    }
    return false;
}

std::optional<std::uint32_t> QuestWorld::reference_base(std::string_view reference) const {
    const auto found = reference_bases_.find(lower(reference));
    if (found == reference_bases_.end()) return std::nullopt;
    return found->second;
}

double QuestWorld::say(std::string_view topic_editor_id, std::uint32_t speaker, std::uint32_t listener, QuestTick& tick,
                       const DistanceFunction& distance) {
    const auto* topic = find_topic_ ? find_topic_(topic_editor_id) : nullptr;
    if (!topic) {
        tick.unanswered.push_back("sayto");
        return 0.0;
    }
    QuestDriver* quest = nullptr;
    for (const auto quest_form : topic->quests)
        if ((quest = find_form(quest_form))) break;
    if (!quest) {
        tick.parse_errors.push_back("topic " + std::string(topic_editor_id) + " belongs to no quest in the world");
        return 0.0;
    }
    DialogueContext context;
    context.speaker_base = speaker;
    context.listener_base = listener;
    context.listener_race = listener_race_;
    context.listener_female = listener_female_;
    const auto run = quest->run_topic(*topic, context, distance);
    append_tick(tick, run.tick);
    if (!run.reply) return 0.0;
    // The line is recorded as spoken, so the scene can show it.
    ScriptAction speech;
    speech.command = "speech";
    speech.target = std::string(topic_editor_id);
    speech.arguments.push_back(ScriptValue::from_text(run.reply->text));
    tick.actions.push_back(std::move(speech));
    return speech_seconds(run.reply->text);
}

namespace {

// Answers the commands of an actor's GameMode: quest stages and variables through the world, SayTo through the
// world's topics, and distances from the scene. Other commands go to the world's answers, or are recorded.
class ActorTickHost final : public ScriptHost {
public:
    ActorTickHost(QuestWorld& world, std::uint32_t speaker, QuestTick& tick, double seconds, const DistanceFunction& distance,
                  std::function<void()> take_writes)
        : world_(world), speaker_(speaker), tick_(tick), seconds_(seconds), distance_(distance),
          take_writes_(std::move(take_writes)) {}

    std::optional<ScriptValue> call_command(std::string_view name, const ScriptValue* target,
                                            const std::vector<ScriptValue>& arguments) override {
        // `Quest.variable` with no arguments reads that quest's variable.
        if (target && target->is_text && arguments.empty()) {
            if (const auto* quest = world_.find(target->text)) {
                if (const auto value = quest->variable(name)) return ScriptValue::from_number(*value);
            }
        }
        const auto command = lower(name);
        const auto* quest = !arguments.empty() && arguments[0].is_text ? world_.find(arguments[0].text) : nullptr;
        if (command == "getsecondspassed") return ScriptValue::from_number(seconds_);
        if (command == "getstage" && quest) return ScriptValue::from_number(quest->stage());
        if (command == "getstagedone" && quest && arguments.size() >= 2)
            return ScriptValue::from_number(quest->has_entered(static_cast<unsigned>(arguments[1].number)) ? 1.0 : 0.0);
        if (command == "setstage" && quest && arguments.size() >= 2) {
            world_.set_stage(arguments[0].text, static_cast<unsigned>(arguments[1].number), tick_, distance_, 0);
            take_writes_();
            return ScriptValue::from_number(0.0);
        }
        if (command == "startquest" && quest) {
            world_.begin(arguments[0].text, tick_, distance_, 0);
            take_writes_();
            return ScriptValue::from_number(0.0);
        }
        if (command == "sayto" && arguments.size() >= 2 && arguments[1].is_text) {
            const auto seconds = world_.say(arguments[1].text, speaker_, listener_of(arguments[0]), tick_, distance_);
            take_writes_();
            return ScriptValue::from_number(seconds);
        }
        // `Say topic` has no listener: the line is for the player, as the game's subtitles show it.
        if (command == "say" && !arguments.empty() && arguments[0].is_text) {
            const auto seconds = world_.say(arguments[0].text, speaker_, kPlayerReference, tick_, distance_);
            take_writes_();
            return ScriptValue::from_number(seconds);
        }
        if (command == "getdistance") {
            const auto from = target && target->is_text ? target->text : std::string("player");
            const auto to = !arguments.empty() && arguments[0].is_text ? arguments[0].text : std::string();
            return ScriptValue::from_number(distance_or_far(distance_, from, to, tick_));
        }
        if (world_.answer()) {
            if (auto value = world_.answer()(name, target, arguments)) return value;
        }
        ScriptAction action;
        action.command = std::string(name);
        if (target) action.target = target->text;
        action.arguments = arguments;
        tick_.actions.push_back(std::move(action));
        return ScriptValue::from_number(0.0);
    }

private:
    // The listener a SayTo names: the player, or the NPC base of the named reference (0 when it is not known).
    std::uint32_t listener_of(const ScriptValue& value) const {
        if (!value.is_text) return 0;
        if (lower(value.text) == "player") return kPlayerReference;
        return world_.reference_base(value.text).value_or(0);
    }

    QuestWorld& world_;
    std::uint32_t speaker_;
    QuestTick& tick_;
    double seconds_;
    const DistanceFunction& distance_;
    std::function<void()> take_writes_;
};

} // namespace

void QuestWorld::run_actor_game_mode(ActorState& actor, QuestTick& tick, double seconds_passed, const DistanceFunction& distance) {
    ScriptInterpreter interpreter(actor.ast);
    actor.pending.clear();
    for (const auto& [key, value] : actor.variables) interpreter.set_variable(key, ScriptValue::from_number(value));
    // Writes that other scripts made during this run (a stage the actor's SayTo set) replace what the run holds.
    const auto take_writes = [&actor, &interpreter] {
        for (const auto& [key, value] : actor.pending) interpreter.set_variable(key, ScriptValue::from_number(value));
        actor.pending.clear();
    };
    ActorTickHost host(*this, actor.form_id, tick, seconds_passed, distance, take_writes);
    interpreter.run("gamemode", host);
    for (const auto& [key, value] : interpreter.variables()) {
        if (value.is_text) continue;
        if (key.find('.') != std::string::npos) write_foreign_variable(this, key, value.number);
        else if (actor.pending.count(key) == 0) actor.variables[key] = value.number;
    }
    for (const auto& [key, value] : actor.pending) actor.variables[key] = value;
    actor.pending.clear();
}

void QuestWorld::set_stage(std::string_view editor_id, unsigned stage, QuestTick& tick, const DistanceFunction& distance, int depth) {
    auto* driver = find(editor_id);
    if (!driver) return;
    started_.insert(driver);
    driver->enter_stage(stage, tick, distance, depth);
}

void QuestWorld::begin(std::string_view editor_id, QuestTick& tick, const DistanceFunction& distance, int depth) {
    auto* driver = find(editor_id);
    if (!driver || !started_.insert(driver).second) return;
    driver->enter_stage(0, tick, distance, depth);
}

std::optional<ScriptValue> answer_fresh_player(std::string_view command, const ScriptValue* target,
                                               const std::vector<ScriptValue>& arguments) {
    if ((command != "getav" && command != "getbaseav") || !target || !target->is_text || lower(target->text) != "player")
        return std::nullopt;
    if (arguments.empty() || !arguments[0].is_text) return std::nullopt;
    const auto value = lower(arguments[0].text);
    if (value == "health" || value == "magicka" || value == "fatigue") return ScriptValue::from_number(100.0);
    return std::nullopt;
}

} // namespace oblivion
