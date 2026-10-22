#include "oblivion/quest_driver.hpp"

#include <cctype>

#include "oblivion/quest_runtime.hpp"
#include "oblivion/script_interpreter.hpp"

namespace oblivion {
namespace {

constexpr int kMaxStageDepth = 8;  // stage results may set stages; this bounds the chain

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
        const auto command = lower(name);
        const auto quest_name = lower(driver_.quest_.editor_id);
        if (command == "getstage" && !arguments.empty() && arguments[0].is_text && lower(arguments[0].text) == quest_name)
            return ScriptValue::from_number(driver_.stage_);
        if (command == "setstage" && arguments.size() >= 2 && arguments[0].is_text && lower(arguments[0].text) == quest_name) {
            flush_variables();
            driver_.append_stage_runs(static_cast<unsigned>(arguments[1].number), tick_, distance_, depth_ + 1);
            return ScriptValue::from_number(0.0);
        }
        if (command == "getsecondspassed") return ScriptValue::from_number(seconds_);
        if (command == "getdistance") {
            const auto from = target && target->is_text ? target->text : std::string("player");
            const auto to = !arguments.empty() && arguments[0].is_text ? arguments[0].text : std::string();
            if (distance_) {
                if (const auto value = distance_(from, to)) return ScriptValue::from_number(*value);
            }
            tick_.unanswered.push_back("getdistance");
            return ScriptValue::from_number(0.0);
        }
        // Everything else is a request for the world: recorded and answered with 0.
        ScriptAction action;
        action.command = std::string(name);
        if (target) action.target = target->text;
        action.arguments = arguments;
        tick_.actions.push_back(std::move(action));
        return ScriptValue::from_number(0.0);
    }

    // Writes the GameMode variables into the quest's state, so a stage run sees them.
    void flush_variables() {
        if (!interpreter) return;
        const auto prefix = lower(driver_.quest_.editor_id) + ".";
        for (const auto& [key, value] : interpreter->variables()) {
            if (value.is_text) continue;
            const auto state_key = key.find('.') == std::string::npos ? prefix + key : key;
            if (state_key.compare(0, prefix.size(), prefix) == 0) driver_.state_.variables[state_key] = value.number;
        }
    }

private:
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
    append_stage_runs(stage, tick, distance, 0);
    tick.stage = stage_;
    return tick;
}

namespace {

// Answers the conditions of a package from the driver's state: GetStage of this quest, and quest variables.
class DriverConditionHost final : public ScriptHost {
public:
    DriverConditionHost(const QuestRecord& quest, const ScriptRecord& script, const QuestState& state, unsigned stage,
                        const DialogueContext* dialogue = nullptr)
        : quest_(quest.form_id), quest_name_(lower(quest.editor_id)), script_(script), state_(state), stage_(stage),
          dialogue_(dialogue) {}

    std::optional<ScriptValue> call_command(std::string_view, const ScriptValue*, const std::vector<ScriptValue>&) override {
        return std::nullopt;
    }

    std::optional<double> call_condition(std::uint16_t function_index, std::uint32_t parameter1, std::uint32_t parameter2) override {
        constexpr std::uint16_t kGetStage = 58;
        constexpr std::uint16_t kGetQuestVariable = 79;
        if (function_index == kGetStage && parameter1 == quest_) return static_cast<double>(stage_);
        if (dialogue_) {
            constexpr std::uint16_t kGetIsID = 72;
            constexpr std::uint16_t kGetIsRace = 69;
            constexpr std::uint16_t kGetIsSex = 70;  // param 0 male, 1 female
            if (function_index == kGetIsID)
                return (parameter1 == dialogue_->speaker_base || parameter1 == dialogue_->listener_base) ? 1.0 : 0.0;
            if (function_index == kGetIsRace) return parameter1 == dialogue_->listener_race ? 1.0 : 0.0;
            if (function_index == kGetIsSex) return (parameter1 != 0) == dialogue_->listener_female ? 1.0 : 0.0;
        }
        if (function_index == kGetQuestVariable && parameter1 == quest_) {
            for (const auto& variable : script_.variables) {
                if (variable.index != parameter2) continue;
                const auto found = state_.variables.find(quest_name_ + "." + lower(variable.name));
                return found == state_.variables.end() ? 0.0 : found->second;
            }
            return 0.0;
        }
        return std::nullopt;
    }

private:
    std::uint32_t quest_;
    std::string quest_name_;
    const ScriptRecord& script_;
    const QuestState& state_;
    unsigned stage_;
    const DialogueContext* dialogue_;
};

} // namespace

const AiPackageRecord* QuestDriver::select_package(const std::vector<const AiPackageRecord*>& packages) const {
    DriverConditionHost host(quest_, script_, state_, stage_);
    return oblivion::select_package(packages, host);
}

TopicRun QuestDriver::run_topic(const DialogTopic& topic, const DialogueContext& context, const DistanceFunction& distance) {
    TopicRun run;
    DriverConditionHost conditions(quest_, script_, state_, stage_, &context);
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

void QuestDriver::append_stage_runs(unsigned stage, QuestTick& tick, const DistanceFunction& distance, int depth) {
    if (depth > kMaxStageDepth) {
        tick.parse_errors.push_back("stage chain deeper than " + std::to_string(kMaxStageDepth));
        return;
    }
    stage_ = stage;
    tick.stage_changes.push_back(std::to_string(stage));
    for (const auto& run : run_quest_stage(quest_, stage, lookup_, &script_, state_)) {
        for (const auto& error : run.parse_errors) tick.parse_errors.push_back(error);
        for (const auto& action : run.actions) {
            tick.actions.push_back(action);
            // A stage result that sets a stage is followed through as well.
            if (lower(action.command) == "setstage" && action.arguments.size() >= 2 && action.arguments[0].is_text
                && lower(action.arguments[0].text) == lower(quest_.editor_id))
                append_stage_runs(static_cast<unsigned>(action.arguments[1].number), tick, distance, depth + 1);
        }
    }
}

} // namespace oblivion
