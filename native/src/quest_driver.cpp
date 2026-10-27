#include "oblivion/quest_driver.hpp"

#include <algorithm>
#include <cctype>
#include <cmath>
#include <limits>

#include "oblivion/quest_runtime.hpp"
#include "oblivion/script_interpreter.hpp"

namespace oblivion {
namespace {

constexpr int kMaxStageDepth = 8;  // stage results may set stages; this bounds the chain

// Oblivion.exe's default iSpeakSoundLipDistance is 750 game units. SayTo is only attempted inside that range;
// the voice itself is still positional audio and may be heard farther away.
constexpr double kSayToMaxDistanceGameUnits = 750.0;

// A distance the world cannot give counts as far away, so a condition that waits for the player to be near stays false.
constexpr double kUnknownDistance = 1.0e9;

bool say_to_in_range(const DistanceFunction& distance, std::string_view speaker_reference,
                     std::string_view listener_reference) {
    // Without scene positions (for example in offline inspection), retain the existing behavior. A live scene can
    // answer both references, and an unknown reference is treated as out of range.
    if (!distance || speaker_reference.empty() || listener_reference.empty()) return true;
    const auto separation = distance(speaker_reference, listener_reference);
    return separation && *separation <= kSayToMaxDistanceGameUnits;
}

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

// A script number as a stage index. A number that is no stage (negative, not finite, too large) is refused, rather
// than converted with undefined behavior.
bool stage_number(double value, unsigned& stage) {
    if (!(value >= 0.0) || value > static_cast<double>(std::numeric_limits<unsigned>::max())) return false;
    stage = static_cast<unsigned>(value);
    return true;
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

// Records a SetStage or StartQuest as an action before it takes effect, the way a stage result's chain does
// (QuestDriver::enter_stage records the action, then follows it). A script that runs in GameMode, a topic or an actor
// event therefore leaves its actions in the same order as the same commands in a stage result: the command, then
// what it caused.
void record_quest_action(QuestTick& tick, std::string_view command, const std::vector<ScriptValue>& arguments) {
    ScriptAction action;
    action.command = std::string(command);
    action.arguments = arguments;
    tick.actions.push_back(std::move(action));
}

} // namespace

// Answers the commands of GameMode and of stage results for one tick.
class QuestTickHost final : public ScriptHost {
public:
    QuestTickHost(QuestDriver& driver, QuestTick& tick, double seconds, const DistanceFunction& distance, int depth,
                  bool sync_quest_variables = true)
        : driver_(driver), tick_(tick), seconds_(seconds), distance_(distance), depth_(depth),
          sync_quest_variables_(sync_quest_variables) {}

    ScriptInterpreter* interpreter = nullptr;  // set by the driver; its variables are flushed before nested stages
    std::uint32_t self_base = 0;               // the actor an unqualified PickIdle is for (speaker, or the script's NPC)

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
            if (const auto* quest = find_quest(arguments[0].text)) {
                unsigned stage = 0;
                return ScriptValue::from_number(stage_number(arguments[1].number, stage) && quest->has_entered(stage) ? 1.0 : 0.0);
            }
        }
        if (command == "setstage" && arguments.size() >= 2 && arguments[0].is_text && find_quest(arguments[0].text)) {
            unsigned stage = 0;
            if (!stage_number(arguments[1].number, stage)) {
                tick_.parse_errors.push_back("SetStage with a stage that is not a valid number");
                return ScriptValue::from_number(0.0);
            }
            flush_variables();
            record_quest_action(tick_, name, arguments);
            if (lower(arguments[0].text) == driver_.lower_editor_id_) driver_.enter_stage(stage, tick_, distance_, depth_ + 1);
            else driver_.world_->set_stage(arguments[0].text, stage, tick_, distance_, depth_ + 1);
            reload_variables();
            return ScriptValue::from_number(0.0);
        }
        if (command == "startquest" && !arguments.empty() && arguments[0].is_text && driver_.world_ && driver_.world_->find(arguments[0].text)) {
            flush_variables();
            record_quest_action(tick_, name, arguments);
            driver_.world_->begin(arguments[0].text, tick_, distance_, depth_ + 1);
            reload_variables();
            return ScriptValue::from_number(0.0);
        }
        if (command == "getsecondspassed") return ScriptValue::from_number(seconds_);
        if (command == "pickidle" && driver_.world_) {
            // The idle depends on the quest variables the script has just set (characterGen.uniqueIdle).
            flush_variables();
            driver_.world_->pick_idle(target && target->is_text ? std::string_view(target->text) : std::string_view(), self_base, tick_);
            return ScriptValue::from_number(0.0);
        }
        if (command == "sayto" && driver_.world_ && arguments.size() >= 2
            && arguments[0].is_text && arguments[1].is_text) {
            flush_variables();
            const auto speaker = target && target->is_text
                ? driver_.world_->reference_base(target->text).value_or(self_base) : self_base;
            const auto listener = lower(arguments[0].text) == "player" ? kPlayerReference
                : driver_.world_->reference_base(arguments[0].text).value_or(0);
            const auto speaker_reference = target && target->is_text ? std::string_view(target->text) : std::string_view();
            const auto seconds = say_to_in_range(distance_, speaker_reference, arguments[0].text)
                ? driver_.world_->say(arguments[1].text, speaker, listener, tick_, distance_, depth_ + 1,
                                      speaker_reference)
                : 0.0;
            reload_variables();
            return ScriptValue::from_number(seconds);
        }
        if (command == "say" && driver_.world_ && !arguments.empty() && arguments[0].is_text) {
            flush_variables();
            const auto speaker = target && target->is_text
                ? driver_.world_->reference_base(target->text).value_or(self_base) : self_base;
            const auto speaker_reference = target && target->is_text ? std::string_view(target->text) : std::string_view();
            const auto seconds = driver_.world_->say(arguments[0].text, speaker, kPlayerReference, tick_, distance_, depth_ + 1,
                                                     speaker_reference);
            reload_variables();
            return ScriptValue::from_number(seconds);
        }
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

    void variable_written(std::string_view name, const ScriptValue& value) override {
        if (value.is_text) return;
        const auto key = lower(name);
        written_.insert(key);
        if (!sync_quest_variables_ || !interpreter) return;
        const auto& prefix = driver_.prefix_;
        if (key.compare(0, prefix.size(), prefix) == 0) {
            const auto alias = key.substr(prefix.size());
            if (is_declared_variable(alias))
                interpreter->set_variable(alias, value);
        } else if (key.find('.') == std::string::npos && is_declared_variable(key)) {
            interpreter->set_variable(prefix + key, value);
        }
    }

    // Loads the quest's variables into the interpreter, by bare name and as "quest.name", and marks the script's
    // short and long variables as integers. Used before a run, so that a bare `bDone` reads the quest's value.
    void load_variables() {
        if (!interpreter) return;
        for (const auto& declaration : driver_.ast_.declarations) {
            if (declaration.type != "short" && declaration.type != "long" && declaration.type != "int") continue;
            const auto key = lower(declaration.name);
            interpreter->declare_integer(key);
            interpreter->declare_integer(driver_.prefix_ + key);
        }
        reload_variables();
        for (const auto& [key, value] : driver_.state_.variables)
            if (key.compare(0, driver_.prefix_.size(), driver_.prefix_) == 0) interpreter->set_variable(key, ScriptValue::from_number(value));
    }

    // Writes the variables the run has set since the last flush into the quest's state (and other quests'
    // variables into theirs), so a stage run sees them. A variable the run only read is not written back, so a
    // stale copy cannot overwrite a change another script made meanwhile. An actor's bare variables are its own
    // and stay out of the quest; only `quest.name` writes leave an actor's script.
    void flush_variables() {
        if (!interpreter) return;
        const auto& prefix = driver_.prefix_;
        const auto& variables = interpreter->variables();
        for (const auto& key : written_) {
            const auto found = variables.find(key);
            if (found == variables.end() || found->second.is_text) continue;
            const auto value = found->second.number;
            if (key.find('.') == std::string::npos) {
                if (sync_quest_variables_) driver_.state_.variables[prefix + key] = value;
            } else if (key.compare(0, prefix.size(), prefix) == 0) {
                driver_.state_.variables[key] = value;
            } else {
                write_foreign_variable(driver_.world_, key, value);
            }
        }
        written_.clear();
    }

    // Reads the variables back into the interpreter after a nested stage ran: the stage may have set this quest's
    // variables or those of other quests, and the script that continues must see the new values rather than the
    // ones it held before the stage.
    void reload_variables() {
        if (!interpreter) return;
        const auto& prefix = driver_.prefix_;
        for (const auto& declaration : driver_.script_.variables) {
            const auto key = lower(declaration.name);
            const auto found = driver_.state_.variables.find(prefix + key);
            const auto value = ScriptValue::from_number(found == driver_.state_.variables.end() ? 0.0 : found->second);
            if (sync_quest_variables_) interpreter->set_variable(key, value);
            interpreter->set_variable(prefix + key, value);
        }
        // Another quest's variable the script has set holds a copy: take the current value.
        if (!driver_.world_) return;
        for (const auto& [key, held] : interpreter->variables()) {
            const auto dot = key.find('.');
            if (held.is_text || dot == std::string::npos || key.compare(0, prefix.size(), prefix) == 0) continue;
            if (const auto* other = driver_.world_->find(key.substr(0, dot)))
                if (const auto current = other->variable(key.substr(dot + 1)))
                    interpreter->set_variable(key, ScriptValue::from_number(*current));
        }
    }

private:
    // The quest a name refers to: this quest, or another quest of the same world.
    QuestDriver* find_quest(std::string_view editor_id) {
        if (lower(editor_id) == driver_.lower_editor_id_) return &driver_;
        return driver_.world_ ? driver_.world_->find(editor_id) : nullptr;
    }

    QuestDriver& driver_;
    QuestTick& tick_;
    double seconds_;
    const DistanceFunction& distance_;
    int depth_;
    bool sync_quest_variables_;
    std::set<std::string> written_;  // lowercase names `set` has assigned since the last flush

    bool is_declared_variable(std::string_view name) const {
        return std::any_of(driver_.script_.variables.begin(), driver_.script_.variables.end(),
                           [name](const auto& declaration) { return lower(declaration.name) == name; });
    }
};

QuestDriver::QuestDriver(const QuestRecord& quest, const ScriptRecord& script, ScriptCommandLookup lookup)
    : quest_(quest), script_(script), lookup_(std::move(lookup)), ast_(parse_script(script.source, lookup_)),
      lower_editor_id_(lower(quest.editor_id)), prefix_(lower_editor_id_ + ".") {}

CachedScript& ScriptCache::get(const ScriptRecord& script, const ScriptCommandLookup& lookup) {
    const auto key = std::to_string(script.form_id) + ":" + script.editor_id;
    auto& entry = entries_[key];
    if (!entry || entry->source != script.source) {
        entry = std::make_unique<CachedScript>();
        entry->source = script.source;
        entry->ast = parse_script(script.source, lookup);
    }
    return *entry;
}

ScriptCache& QuestDriver::script_cache() { return world_ ? world_->script_cache() : own_scripts_; }

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
    DriverConditionHost(const QuestDriver* self, QuestWorld* world, const DialogueContext* dialogue = nullptr)
        : self_(self), world_(world), dialogue_(dialogue) {}

    std::optional<ScriptValue> call_command(std::string_view, const ScriptValue*, const std::vector<ScriptValue>&) override {
        return std::nullopt;
    }

    std::optional<double> call_condition(std::uint16_t function_index, std::uint32_t parameter1, std::uint32_t parameter2) override {
        return call_condition(function_index, parameter1, parameter2, 0);
    }

    std::optional<double> call_condition(std::uint16_t function_index, std::uint32_t parameter1,
                                         std::uint32_t parameter2, std::uint32_t run_on) override {
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
            constexpr std::uint16_t kMenuMode = 36;
            constexpr std::uint16_t kGetQuestRunning = 56;
            constexpr std::uint16_t kGetIsCurrentPackage = 161;
            if (dialogue_->for_idle) {
                if (function_index == kMenuMode) return 0.0;
                if (function_index == kGetIsCurrentPackage) return parameter1 == dialogue_->current_package ? 1.0 : 0.0;
                if (function_index == kGetQuestRunning) {
                    const auto* quest = find_quest(parameter1);
                    return quest && world_ && world_->is_started(quest) ? 1.0 : 0.0;
                }
            }
            constexpr std::uint16_t kGetIsID = 72;
            constexpr std::uint16_t kGetIsRace = 69;
            constexpr std::uint16_t kGetIsSex = 70;  // param 0 male, 1 female
            if (function_index == kGetIsID || function_index == kGetIsRace || function_index == kGetIsSex) {
                if (run_on > 1) return std::nullopt;
                const bool is_listener = run_on == 1;
                const auto actor_base = is_listener ? dialogue_->listener_base : dialogue_->speaker_base;
                const auto actor_race = is_listener ? dialogue_->listener_race : dialogue_->speaker_race;
                const bool actor_female = is_listener ? dialogue_->listener_female : dialogue_->speaker_female;
                if (function_index == kGetIsID) return parameter1 == actor_base ? 1.0 : 0.0;
                if (function_index == kGetIsRace) return parameter1 == actor_race ? 1.0 : 0.0;
                return (parameter1 != 0) == actor_female ? 1.0 : 0.0;
            }
        }
        return std::nullopt;
    }

    std::optional<double> global_value(std::uint32_t form_id) override {
        if (world_ && world_->global_value()) return world_->global_value()(form_id);
        return std::nullopt;
    }

private:
    // This quest, or a quest of the same world with that form ID.
    const QuestDriver* find_quest(std::uint32_t form_id) const {
        if (self_ && self_->quest().form_id == form_id) return self_;
        return world_ ? world_->find_form(form_id) : nullptr;
    }

    const QuestDriver* self_;
    QuestWorld* world_;
    const DialogueContext* dialogue_;
};

} // namespace

const AiPackageRecord* QuestDriver::select_package(const std::vector<const AiPackageRecord*>& packages) const {
    DriverConditionHost host(this, world_);
    return oblivion::select_package(packages, host);
}

std::optional<double> QuestDriver::variable(std::string_view name) const {
    const auto wanted = lower(name);
    for (const auto& declaration : script_.variables) {
        if (lower(declaration.name) != wanted) continue;
        const auto found = state_.variables.find(prefix_ + wanted);
        return found == state_.variables.end() ? 0.0 : found->second;
    }
    return std::nullopt;
}

double QuestDriver::variable_at(std::uint32_t index) const {
    for (const auto& variable : script_.variables) {
        if (variable.index != index) continue;
        const auto found = state_.variables.find(prefix_ + lower(variable.name));
        return found == state_.variables.end() ? 0.0 : found->second;
    }
    return 0.0;
}

TopicRun QuestDriver::run_topic(const DialogTopic& topic, const DialogueContext& context, const DistanceFunction& distance,
                                int depth) {
    const auto* reply = find_topic_reply(topic, context);
    if (!reply) {
        TopicRun empty;
        empty.tick.stage = stage_;
        return empty;
    }
    return run_topic_reply(*reply, context, distance, depth);
}

bool QuestDriver::topic_reply_conditions_hold(const DialogResponse& reply, const DialogueContext& context) const {
    if (reply.quest != quest_.form_id) return false;
    DriverConditionHost conditions(this, world_, &context);
    return evaluate_conditions(reply.conditions, conditions);
}

TopicRun QuestDriver::run_topic_reply(const DialogResponse& reply, const DialogueContext& context,
                                      const DistanceFunction& distance, int depth) {
    TopicRun run;
    std::optional<QuestWorld::RunGuard> guard;
    if (world_) guard.emplace(*world_);
    run.reply = &reply;
    if (reply.quest != quest_.form_id || !topic_reply_conditions_hold(reply, context)) {
        run.reply = nullptr;
        run.tick.stage = stage_;
        return run;
    }
    run.quest_editor_id = quest_.editor_id;
    const auto fragment = parse_fragment(reply.result_source, lookup_);
    for (const auto& diagnostic : fragment.diagnostics)
        run.tick.parse_errors.push_back("line " + std::to_string(diagnostic.line) + ": " + diagnostic.message);
    const ScriptAst no_script;
    ScriptInterpreter interpreter(no_script);
    interpreter.set_trace(false);
    QuestTickHost host(*this, run.tick, 0.0, distance, depth);
    host.self_base = context.speaker_base;
    host.interpreter = &interpreter;
    host.load_variables();
    interpreter.run_body(fragment.statements, host);
    host.flush_variables();
    run.tick.stage = stage_;
    return run;
}

const DialogResponse* QuestDriver::find_topic_reply(const DialogTopic& topic, const DialogueContext& context) const {
    for (const auto& reply : topic.responses) {
        // A DIAL may contain replies contributed by several quests. A SayTo
        // must evaluate only this quest's INFO records; otherwise an earlier
        // reply owned by another quest can mask the actor's matching line.
        if (!topic_reply_conditions_hold(reply, context)) continue;
        return &reply;
    }
    return nullptr;
}

QuestTick QuestDriver::run_actor_event(const ScriptRecord& actor_script, std::string_view event, std::string_view detail,
                                       const DistanceFunction& distance, std::uint32_t actor_base) {
    QuestTick tick;
    std::optional<QuestWorld::RunGuard> guard;
    if (world_) guard.emplace(*world_);
    // The script is parsed once, and its variables carry over from the events that ran before.
    auto& cached = script_cache().get(actor_script, lookup_);
    for (const auto& diagnostic : cached.ast.diagnostics)
        tick.parse_errors.push_back("line " + std::to_string(diagnostic.line) + ": " + diagnostic.message);
    ScriptInterpreter interpreter(cached.ast);
    interpreter.set_trace(false);
    for (const auto& [key, value] : cached.variables) interpreter.set_variable(key, ScriptValue::from_number(value));
    QuestTickHost host(*this, tick, 0.0, distance, 0, false);
    host.self_base = actor_base;
    host.interpreter = &interpreter;
    const auto result = interpreter.run_event(event, detail, host);
    tick.event_found = result.found_block;
    host.flush_variables();
    for (const auto& [key, value] : interpreter.variables())
        if (!value.is_text && key.find('.') == std::string::npos) cached.variables[key] = value.number;
    for (const auto& name : result.unimplemented) tick.unanswered.push_back(name);
    tick.stage = stage_;
    return tick;
}

QuestTick QuestDriver::tick(double seconds_passed, const DistanceFunction& distance) {
    QuestTick tick;
    std::optional<QuestWorld::RunGuard> guard;
    if (world_) guard.emplace(*world_);
    ScriptInterpreter interpreter(ast_);
    interpreter.set_trace(false);
    QuestTickHost host(*this, tick, seconds_passed, distance, 0);
    host.interpreter = &interpreter;
    // The script's declared variables hold the quest's values, which persist across ticks.
    host.load_variables();
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
    // Setting the stage the quest is already in does nothing: its results do not run again, so a package whose
    // OnPackageDone sets the stage does not restart its route every time.
    if (stage == stage_ && has_entered(stage)) return;
    // A stage whose results are running is not entered again from them (A:10 -> A:20 -> A:10): the chain ends
    // there, and the quest stays in the stage it reached.
    if (running_stages_.count(stage) != 0) {
        tick.parse_errors.push_back("stage " + std::to_string(stage) + " of " + quest_.editor_id + " sets itself again through its results");
        return;
    }
    // Nor does going back to a stage that was entered and is below the current one: an OnHit that sets stage 24 whose
    // results set 23 again ("make sure") would otherwise repeat both stages' results on every blow.
    if (has_entered(stage) && stage < stage_) return;
    if (tick.stage_entries >= kMaxStageEntriesPerTick) {
        if (tick.stage_entries == kMaxStageEntriesPerTick) {
            ++tick.stage_entries;  // reported once; later entries are refused silently
            tick.parse_errors.push_back("more than " + std::to_string(kMaxStageEntriesPerTick) + " stages entered in one tick");
        }
        return;
    }
    ++tick.stage_entries;
    struct Running {
        std::set<unsigned>& set;
        unsigned stage;
        ~Running() { set.erase(stage); }
    } running{running_stages_, stage};
    running_stages_.insert(stage);
    stage_ = stage;
    entered_.insert(stage);
    tick.stage_changes.push_back(std::to_string(stage));
    const ForeignVariableReader read_foreign = [this](std::string_view quest, std::string_view variable) -> std::optional<double> {
        const auto* other = world_ ? world_->find(quest) : nullptr;
        return other ? other->variable(variable) : std::nullopt;
    };
    // PickIdle in a result is answered when it runs, so it sees the variables set before it (uniqueIdle) and not the
    // ones set after it (reset to 0).
    PickIdleHook pick_idle;
    if (world_) {
        pick_idle = [this, &tick](const std::string& reference) {
            QuestTick picked;
            world_->pick_idle(reference, 0, picked);
            for (const auto& name : picked.unanswered)
                if (std::find(tick.unanswered.begin(), tick.unanswered.end(), name) == tick.unanswered.end())
                    tick.unanswered.push_back(name);
            return picked.actions.front();
        };
    }
    StageCommandValue command_value;
    if (world_) {
        command_value = [this, &distance](std::string_view name, const ScriptValue* target,
                               const std::vector<ScriptValue>& arguments) -> std::optional<ScriptValue> {
            const auto command = lower(name);
            if (command == "sayto" && target && target->is_text && arguments.size() >= 2
                && arguments[0].is_text && arguments[1].is_text) {
                if (!say_to_in_range(distance, target->text, arguments[0].text))
                    return ScriptValue::from_number(0.0);
                const auto speaker = world_->reference_base(target->text).value_or(0);
                const auto listener = lower(arguments[0].text) == "player" ? kPlayerReference
                    : world_->reference_base(arguments[0].text).value_or(0);
                return ScriptValue::from_number(world_->speech_duration(arguments[1].text, speaker, listener));
            }
            if (command == "say" && target && target->is_text && !arguments.empty() && arguments[0].is_text) {
                const auto speaker = world_->reference_base(target->text).value_or(0);
                return ScriptValue::from_number(world_->speech_duration(arguments[0].text, speaker, kPlayerReference));
            }
            return std::nullopt;
        };
    }
    for (const auto& run : run_quest_stage(quest_, stage, lookup_, &script_, state_, read_foreign, pick_idle, command_value)) {
        for (const auto& error : run.parse_errors) tick.parse_errors.push_back(error);
        for (const auto& [key, value] : run.foreign_writes) write_foreign_variable(world_, key, value);
        for (const auto& action : run.actions) {
            tick.actions.push_back(action);
            if (action.arguments.empty() || !action.arguments[0].is_text) continue;
            const auto command = lower(action.command);
            // A stage result that sets a stage, here or in another quest, is followed through as well.
            if (command == "setstage" && action.arguments.size() >= 2) {
                unsigned next = 0;
                if (!stage_number(action.arguments[1].number, next)) {
                    tick.parse_errors.push_back("SetStage with a stage that is not a valid number");
                    continue;
                }
                if (lower(action.arguments[0].text) == lower_editor_id_) enter_stage(next, tick, distance, depth + 1);
                else if (world_) world_->set_stage(action.arguments[0].text, next, tick, distance, depth + 1);
            } else if (command == "startquest" && world_) {
                world_->begin(action.arguments[0].text, tick, distance, depth + 1);
            } else if (command == "sayto" && world_ && !action.target.empty() && action.arguments.size() >= 2 && action.arguments[1].is_text) {
                // `Ref.SayTo listener Topic` in a stage result: the reference speaks the topic to the listener.
                const auto speaker = world_->reference_base(action.target).value_or(0);
                const auto listener = lower(action.arguments[0].text) == "player" ? kPlayerReference
                    : world_->reference_base(action.arguments[0].text).value_or(0);
                if (say_to_in_range(distance, action.target, action.arguments[0].text))
                    world_->say(action.arguments[1].text, speaker, listener, tick, distance, depth + 1, action.target);
            } else if (command == "say" && world_ && !action.target.empty()) {
                // `Ref.Say topic`: the reference speaks to the player, whose subtitles the scene shows (as in an actor's script).
                const auto speaker = world_->reference_base(action.target).value_or(0);
                world_->say(action.arguments[0].text, speaker, kPlayerReference, tick, distance, depth + 1, action.target);
            }
        }
    }
}

QuestWorld::QuestWorld(ScriptCommandLookup lookup) : lookup_(std::move(lookup)) {}

QuestDriver& QuestWorld::add(const QuestRecord& quest, const ScriptRecord& script) {
    drivers_.push_back(std::make_unique<QuestDriver>(quest, script, lookup_));
    drivers_.back()->attach(this);
    by_editor_id_.emplace(drivers_.back()->lower_editor_id(), drivers_.back().get());
    by_form_id_.emplace(quest.form_id, drivers_.back().get());
    return *drivers_.back();
}

QuestDriver* QuestWorld::find(std::string_view editor_id) {
    const auto found = by_editor_id_.find(lower(editor_id));
    return found == by_editor_id_.end() ? nullptr : found->second;
}

QuestDriver* QuestWorld::find_form(std::uint32_t form_id) {
    const auto found = by_form_id_.find(form_id);
    return found == by_form_id_.end() ? nullptr : found->second;
}

const QuestDriver* QuestWorld::find_form(std::uint32_t form_id) const {
    const auto found = by_form_id_.find(form_id);
    return found == by_form_id_.end() ? nullptr : found->second;
}

QuestTick QuestWorld::start(std::string_view editor_id, unsigned stage, const DistanceFunction& distance) {
    QuestTick tick;
    RunGuard guard(*this);
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
    into.stage_entries += from.stage_entries;
    into.stage_changes.insert(into.stage_changes.end(), from.stage_changes.begin(), from.stage_changes.end());
    into.actions.insert(into.actions.end(), from.actions.begin(), from.actions.end());
    into.unanswered.insert(into.unanswered.end(), from.unanswered.begin(), from.unanswered.end());
    into.parse_errors.insert(into.parse_errors.end(), from.parse_errors.begin(), from.parse_errors.end());
}

} // namespace

QuestTick QuestWorld::tick(double seconds_passed, const DistanceFunction& distance) {
    QuestTick result;
    RunGuard guard(*this);
    for (const auto& driver : drivers_) {
        if (started_.count(driver.get()) == 0) continue;
        append_tick(result, driver->tick(seconds_passed, distance));
    }
    for (const auto& actor : actors_) run_actor_game_mode(*actor, result, seconds_passed, distance);
    return result;
}

// Changes to the actors made while the world runs wait for the end of the outermost run: a callback of the
// scene (a distance, a speech length) may unload a cell in the middle of a tick, and the run is going through
// the actors and holds references to them.
void QuestWorld::run_or_defer(std::function<void()> change) {
    if (running_ > 0) pending_.push_back(std::move(change));
    else change();
}

void QuestWorld::apply_pending() {
    // A change may itself be deferred again by a nested run; take the batch first.
    auto batch = std::move(pending_);
    pending_.clear();
    for (auto& change : batch) change();
}

void QuestWorld::add_actor(std::uint32_t form_id, const ScriptRecord& script, std::string reference_name) {
    if (running_ > 0) {
        // The script record outlives the world's run, but copy what is needed to be safe.
        auto copy = std::make_shared<ScriptRecord>(script);
        run_or_defer([this, form_id, copy, name = std::move(reference_name)]() mutable { add_actor(form_id, *copy, std::move(name)); });
        return;
    }
    if (!reference_name.empty()) {
        const auto wanted = lower(reference_name);
        for (const auto& actor : actors_)
            if (lower(actor->reference_name) == wanted) return;
    }
    auto actor = std::make_unique<ActorState>();
    actor->form_id = form_id;
    actor->reference_name = std::move(reference_name);
    actor->ast = parse_script(script.source, lookup_);
    actors_.push_back(std::move(actor));
}

void QuestWorld::clear_actors() {
    run_or_defer([this] {
        actors_.clear();
        reference_bases_.clear();
        package_by_reference_.clear();
    });
}

void QuestWorld::set_reference_base(std::string_view reference, std::uint32_t base) {
    run_or_defer([this, key = lower(reference), base] { reference_bases_[key] = base; });
}

bool QuestWorld::set_actor_variable(std::string_view reference, std::string_view variable, double value) {
    const auto base = reference_base(reference);
    if (!base) return false;
    const auto wanted = lower(reference);
    for (const auto& actor : actors_) {
        const bool matches = actor->reference_name.empty()
            ? actor->form_id == *base
            : lower(actor->reference_name) == wanted;
        if (!matches) continue;
        actor->variables[lower(variable)] = value;
        actor->pending[lower(variable)] = value;
        return true;
    }
    return false;
}

bool QuestWorld::dialogue_topic_available(const DialogTopic& topic, const DialogueContext& context) const {
    for (const auto& response : topic.responses) {
        const auto* quest = find_form(response.quest);
        if (!quest || !is_started(quest)) continue;
        if (quest->topic_reply_conditions_hold(response, context)) return true;
    }
    return false;
}

const DialogResponse* QuestWorld::find_dialogue_topic_reply(const DialogTopic& topic,
                                                            const DialogueContext& context) const {
    for (const auto& response : topic.responses) {
        const auto* quest = find_form(response.quest);
        if (!quest || !is_started(quest)) continue;
        if (quest->topic_reply_conditions_hold(response, context)) return &response;
    }
    return nullptr;
}

TopicRun QuestWorld::run_dialogue_topic(const DialogTopic& topic, const DialogueContext& context,
                                        const DistanceFunction& distance, int depth) {
    RunGuard guard(*this);
    for (const auto& response : topic.responses) {
        auto* quest = find_form(response.quest);
        if (!quest || !is_started(quest) || !quest->topic_reply_conditions_hold(response, context)) continue;
        return quest->run_topic_reply(response, context, distance, depth);
    }
    TopicRun empty;
    return empty;
}

std::optional<std::uint32_t> QuestWorld::reference_base(std::string_view reference) const {
    const auto found = reference_bases_.find(lower(reference));
    if (found == reference_bases_.end()) return std::nullopt;
    return found->second;
}

double QuestWorld::say(std::string_view topic_editor_id, std::uint32_t speaker, std::uint32_t listener, QuestTick& tick,
                       const DistanceFunction& distance, int depth, std::string_view speaker_reference) {
    if (depth > kMaxStageDepth) {
        tick.parse_errors.push_back("SayTo chain deeper than " + std::to_string(kMaxStageDepth));
        return 0.0;
    }
    RunGuard guard(*this);
    const auto* topic = find_topic_ ? find_topic_(topic_editor_id) : nullptr;
    if (!topic) {
        tick.unanswered.push_back("sayto");
        return 0.0;
    }
    DialogueContext context;
    context.speaker_base = speaker;
    context.listener_base = listener;
    context.listener_race = listener_race_;
    context.listener_female = listener_female_;
    if (actor_traits_ && speaker != 0) {
        if (const auto traits = actor_traits_(speaker)) {
            context.speaker_race = traits->first;
            context.speaker_female = traits->second;
        }
    }
    const auto run = run_dialogue_topic(*topic, context, distance, depth);
    if (!run.reply) return 0.0;
    append_tick(tick, run.tick);
    // The line is recorded as spoken, so the scene can show it: its text, speaker, reply form and quest.
    ScriptAction speech;
    speech.command = "speech";
    speech.target = std::string(topic_editor_id);
    speech.arguments.push_back(ScriptValue::from_text(run.reply->text));
    speech.arguments.push_back(ScriptValue::from_number(static_cast<double>(speaker)));
    speech.arguments.push_back(ScriptValue::from_number(static_cast<double>(run.reply->form_id)));
    speech.arguments.push_back(ScriptValue::from_text(run.quest_editor_id));
    const DialogResponseLine* first_line = nullptr;
    for (const auto& candidate : run.reply->lines) {
        if (!first_line) first_line = &candidate;
        if (candidate.has_text) {
            first_line = &candidate;
            break;
        }
    }
    speech.arguments.push_back(ScriptValue::from_number(first_line ? first_line->emotion_type : 0));
    speech.arguments.push_back(ScriptValue::from_number(first_line ? first_line->emotion_value : 0));
    speech.arguments.push_back(ScriptValue::from_number(first_line ? first_line->number : 1));
    speech.arguments.push_back(ScriptValue::from_number(listener == kPlayerReference ? 1.0 : 0.0));
    speech.arguments.push_back(ScriptValue::from_text(std::string(speaker_reference)));
    tick.actions.push_back(std::move(speech));
    if (speech_length_) {
        if (const auto seconds = speech_length_(speaker, run.quest_editor_id, topic->editor_id,
                                                run.reply->form_id, first_line ? first_line->number : 1,
                                                first_line && first_line->has_text ? first_line->text : run.reply->text))
            return *seconds;
    }
    return speech_seconds(first_line && first_line->has_text ? first_line->text : run.reply->text);
}

double QuestWorld::speech_duration(std::string_view topic_editor_id, std::uint32_t speaker, std::uint32_t listener) const {
    const auto* topic = find_topic_ ? find_topic_(topic_editor_id) : nullptr;
    if (!topic) return 0.0;
    DialogueContext context;
    context.speaker_base = speaker;
    context.listener_base = listener;
    context.listener_race = listener_race_;
    context.listener_female = listener_female_;
    if (actor_traits_ && speaker != 0) {
        if (const auto traits = actor_traits_(speaker)) {
            context.speaker_race = traits->first;
            context.speaker_female = traits->second;
        }
    }
    for (const auto& response : topic->responses) {
        const auto* quest = find_form(response.quest);
        if (!quest || !is_started(quest) || !quest->topic_reply_conditions_hold(response, context)) continue;
        const DialogResponseLine* line = nullptr;
        for (const auto& candidate : response.lines) {
            if (!line) line = &candidate;
            if (candidate.has_text) {
                line = &candidate;
                break;
            }
        }
        const std::string_view text = line && line->has_text ? std::string_view(line->text) : std::string_view(response.text);
        if (speech_length_) {
            if (const auto seconds = speech_length_(speaker, quest->quest().editor_id, topic->editor_id,
                                                    response.form_id, line ? line->number : 1, text))
                return *seconds;
        }
        return speech_seconds(std::string(text));
    }
    return 0.0;
}

namespace {

// Answers the commands of an actor's GameMode: quest stages and variables through the world, SayTo through the
// world's topics, and distances from the scene. Other commands go to the world's answers, or are recorded.
class ActorTickHost final : public ScriptHost {
public:
    ActorTickHost(QuestWorld& world, std::uint32_t speaker, std::string speaker_reference, QuestTick& tick, double seconds,
                  const DistanceFunction& distance, std::function<void()> take_writes,
                  std::string action_reference = {})
        : world_(world), speaker_(speaker), speaker_reference_(std::move(speaker_reference)), tick_(tick), seconds_(seconds), distance_(distance),
          take_writes_(std::move(take_writes)), action_reference_(lower(action_reference)) {}

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
        if (command == "isactionref" && !arguments.empty() && arguments[0].is_text)
            return ScriptValue::from_number(lower(arguments[0].text) == action_reference_ ? 1.0 : 0.0);
        if (command == "getsecondspassed") return ScriptValue::from_number(seconds_);
        if (command == "getstage" && quest) return ScriptValue::from_number(quest->stage());
        if (command == "getstagedone" && quest && arguments.size() >= 2) {
            unsigned stage = 0;
            return ScriptValue::from_number(stage_number(arguments[1].number, stage) && quest->has_entered(stage) ? 1.0 : 0.0);
        }
        if (command == "setstage" && quest && arguments.size() >= 2) {
            unsigned stage = 0;
            if (!stage_number(arguments[1].number, stage)) {
                tick_.parse_errors.push_back("SetStage with a stage that is not a valid number");
                return ScriptValue::from_number(0.0);
            }
            record_quest_action(tick_, name, arguments);
            world_.set_stage(arguments[0].text, stage, tick_, distance_, 0);
            take_writes_();
            return ScriptValue::from_number(0.0);
        }
        if (command == "startquest" && quest) {
            record_quest_action(tick_, name, arguments);
            world_.begin(arguments[0].text, tick_, distance_, 0);
            take_writes_();
            return ScriptValue::from_number(0.0);
        }
        if (command == "pickidle") {
            world_.pick_idle(target && target->is_text ? std::string_view(target->text) : std::string_view(), speaker_, tick_);
            return ScriptValue::from_number(0.0);
        }
        if (command == "sayto" && arguments.size() >= 2 && arguments[1].is_text) {
            const auto seconds = say_to_in_range(distance_, speaker_reference_, arguments[0].text)
                ? world_.say(arguments[1].text, speaker_, listener_of(arguments[0]), tick_, distance_, 0,
                             speaker_reference_)
                : 0.0;
            take_writes_();
            return ScriptValue::from_number(seconds);
        }
        // `Say topic` has no listener: the line is for the player, as the game's subtitles show it.
        if (command == "say" && !arguments.empty() && arguments[0].is_text) {
            const auto seconds = world_.say(arguments[0].text, speaker_, kPlayerReference, tick_, distance_, 0,
                                            speaker_reference_);
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
    std::string speaker_reference_;
    QuestTick& tick_;
    double seconds_;
    const DistanceFunction& distance_;
    std::function<void()> take_writes_;
    std::string action_reference_;
};

} // namespace

void QuestWorld::set_actor_package(std::string_view reference, std::uint32_t package_form_id) {
    if (package_form_id == 0) package_by_reference_.erase(lower(reference));
    else package_by_reference_[lower(reference)] = package_form_id;
}

const IdleRecord* QuestWorld::pick_idle(std::string_view reference, std::uint32_t speaker_base, QuestTick& tick) {
    // The reference's base, or the actor that is speaking / running the script when no reference is named.
    std::uint32_t base = speaker_base;
    std::string name(reference);
    if (!reference.empty()) {
        if (const auto known = reference_base(reference)) base = *known;
        else if (lower(reference) != "player") base = 0;
    } else {
        for (const auto& [reference_name, reference_base_id] : reference_bases_)
            if (reference_base_id == speaker_base && speaker_base != 0) {
                name = reference_name;
                break;
            }
        for (const auto& actor : actors_)
            if (actor->form_id == speaker_base && !actor->reference_name.empty()) {
                name = actor->reference_name;
                break;
            }
    }
    const IdleRecord* chosen = nullptr;
    if (idle_children_) {
        DialogueContext context;
        context.speaker_base = base;
        context.listener_base = base;
        context.for_idle = true;
        if (const auto package = package_by_reference_.find(lower(name)); package != package_by_reference_.end())
            context.current_package = package->second;
        if (actor_traits_ && base != 0) {
            if (const auto traits = actor_traits_(base)) {
                context.speaker_race = traits->first;
                context.listener_race = traits->first;
                context.speaker_female = traits->second;
                context.listener_female = traits->second;
            }
        }
        DriverConditionHost host(nullptr, this, &context);
        // The tree is large and most of its nodes ask about things the scene cannot answer yet (combat, weapons, furniture,
        // random numbers). Those nodes count as not matching; they are not reported one by one.
        chosen = select_idle(idle_children_, host, nullptr);
    } else {
        tick.unanswered.push_back("pickidle");
    }
    ScriptAction action;
    action.command = "pickidle";
    action.target = name;
    action.arguments.push_back(ScriptValue::from_text(chosen ? chosen->animation_file : std::string()));
    action.arguments.push_back(ScriptValue::from_text(chosen ? chosen->editor_id : std::string()));
    action.arguments.push_back(ScriptValue::from_number(chosen ? static_cast<double>(chosen->form_id) : 0.0));
    action.arguments.push_back(ScriptValue::from_number(chosen ? static_cast<double>(chosen->group_flags) : 0.0));
    tick.actions.push_back(std::move(action));
    return chosen;
}

void QuestWorld::run_actor_game_mode(ActorState& actor, QuestTick& tick, double seconds_passed, const DistanceFunction& distance) {
    ScriptInterpreter interpreter(actor.ast);
    interpreter.set_trace(false);
    actor.pending.clear();
    for (const auto& [key, value] : actor.variables) interpreter.set_variable(key, ScriptValue::from_number(value));
    // Writes that other scripts made during this run (a stage the actor's SayTo set) replace what the run holds.
    const auto take_writes = [&actor, &interpreter] {
        for (const auto& [key, value] : actor.pending) interpreter.set_variable(key, ScriptValue::from_number(value));
        actor.pending.clear();
    };
    ActorTickHost host(*this, actor.form_id, actor.reference_name, tick, seconds_passed, distance, take_writes);
    interpreter.run("gamemode", host);
    for (const auto& [key, value] : interpreter.variables()) {
        if (value.is_text) continue;
        if (key.find('.') != std::string::npos) write_foreign_variable(this, key, value.number);
        else if (actor.pending.count(key) == 0) actor.variables[key] = value.number;
    }
    for (const auto& [key, value] : actor.pending) actor.variables[key] = value;
    actor.pending.clear();
}

QuestTick QuestWorld::run_object_event(const ScriptRecord& script, std::string_view event, std::string_view detail,
                                       const DistanceFunction& distance, std::string_view object_reference,
                                       std::string_view action_reference) {
    QuestTick tick;
    RunGuard guard(*this);
    // Parsed once; the variables the script's earlier events left are the ones this event starts with.
    auto& cached = scripts_.get(script, lookup_);
    for (const auto& diagnostic : cached.ast.diagnostics)
        tick.parse_errors.push_back("line " + std::to_string(diagnostic.line) + ": " + diagnostic.message);
    ScriptInterpreter interpreter(cached.ast);
    interpreter.set_trace(false);
    for (const auto& [key, value] : cached.variables) interpreter.set_variable(key, ScriptValue::from_number(value));
    const auto effective_action_reference = action_reference.empty() ? detail : action_reference;
    ActorTickHost host(*this, 0, {}, tick, 0.0, distance, [] {}, std::string(effective_action_reference));
    const auto object_target = ScriptValue::from_text(std::string(object_reference));
    interpreter.run_event(event, detail, host, object_reference.empty() ? nullptr : &object_target);
    for (const auto& [key, value] : interpreter.variables()) {
        if (value.is_text) continue;
        if (key.find('.') != std::string::npos) write_foreign_variable(this, key, value.number);
        else cached.variables[key] = value.number;
    }
    return tick;
}

void QuestWorld::set_stage(std::string_view editor_id, unsigned stage, QuestTick& tick, const DistanceFunction& distance, int depth) {
    RunGuard guard(*this);
    auto* driver = find(editor_id);
    if (!driver) return;
    started_.insert(driver);
    driver->enter_stage(stage, tick, distance, depth);
}

void QuestWorld::begin(std::string_view editor_id, QuestTick& tick, const DistanceFunction& distance, int depth) {
    RunGuard guard(*this);
    auto* driver = find(editor_id);
    if (!driver || !started_.insert(driver).second) return;
    driver->enter_stage(0, tick, distance, depth);
}

std::optional<ScriptValue> answer_player_actor_values(std::string_view command, const ScriptValue* target,
                                                      const std::vector<ScriptValue>& arguments,
                                                      const PlayerActorValueSnapshot& values) {
    if ((command != "getav" && command != "getbaseav") || !target || !target->is_text || lower(target->text) != "player")
        return std::nullopt;
    if (!values.available || arguments.empty() || !arguments[0].is_text) return std::nullopt;
    const auto value = lower(arguments[0].text);
    const bool base = command == "getbaseav";
    if (value == "health") return ScriptValue::from_number(base ? values.base_health : values.health);
    if (value == "magicka") return ScriptValue::from_number(base ? values.base_magicka : values.magicka);
    if (value == "fatigue") return ScriptValue::from_number(base ? values.base_fatigue : values.fatigue);
    return std::nullopt;
}

std::optional<ScriptValue> answer_fresh_player(std::string_view command, const ScriptValue* target,
                                               const std::vector<ScriptValue>& arguments) {
    return answer_player_actor_values(command, target, arguments, {});
}

} // namespace oblivion
