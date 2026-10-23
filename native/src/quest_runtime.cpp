#include "oblivion/quest_runtime.hpp"

#include <algorithm>

namespace oblivion {

ConditionOperator condition_operator(std::uint8_t code) {
    switch (code & 0xF0) {
    case 0x00: return ConditionOperator::Equal;
    case 0x20: return ConditionOperator::NotEqual;
    case 0x40: return ConditionOperator::Greater;
    case 0x60: return ConditionOperator::GreaterEqual;
    case 0x80: return ConditionOperator::Less;
    case 0xA0: return ConditionOperator::LessEqual;
    default: return ConditionOperator::Equal;
    }
}

bool condition_joins_next(std::uint8_t code) {
    return (code & 0x01) != 0;
}

bool evaluate_conditions(const std::vector<QuestCondition>& conditions, ScriptHost& host,
                         std::vector<std::string>* unimplemented) {
    bool all = true;
    std::size_t index = 0;
    while (index < conditions.size()) {
        // One disjunction: conditions linked by OR, ending at the first one that does not join the next.
        bool any = false;
        bool joined = false;
        do {
            const auto& condition = conditions[index];
            const auto value = host.call_condition(condition.function_index, condition.parameter1, condition.parameter2);
            bool holds = false;
            // "Use global": the comparison value is a GLOB record, which the host has to know.
            std::optional<double> comparison = static_cast<double>(condition.comparison);
            if (condition.comparison_is_global) comparison = host.global_value(condition.comparison_global_form_id);
            if (value && comparison) {
                const double right = *comparison;
                switch (condition_operator(condition.operator_code)) {
                case ConditionOperator::Equal: holds = *value == right; break;
                case ConditionOperator::NotEqual: holds = *value != right; break;
                case ConditionOperator::Greater: holds = *value > right; break;
                case ConditionOperator::GreaterEqual: holds = *value >= right; break;
                case ConditionOperator::Less: holds = *value < right; break;
                case ConditionOperator::LessEqual: holds = *value <= right; break;
                }
            } else if (unimplemented) {
                const auto name = value ? "global " + std::to_string(condition.comparison_global_form_id)
                                        : "condition " + std::to_string(condition.function_index);
                if (std::find(unimplemented->begin(), unimplemented->end(), name) == unimplemented->end())
                    unimplemented->push_back(name);
            }
            any = any || holds;
            joined = condition_joins_next(condition.operator_code);
            ++index;
        } while (joined && index < conditions.size());
        all = all && any;
    }
    return all;
}

const AiPackageRecord* select_package(const std::vector<const AiPackageRecord*>& packages, ScriptHost& host,
                                      std::vector<std::string>* unanswered) {
    for (const auto* package : packages) {
        if (!package) continue;
        if (evaluate_conditions(package->conditions, host, unanswered)) return package;
    }
    return nullptr;
}

namespace {

constexpr int kMaxIdleDepth = 16;  // a folder cycle in broken data must end

const IdleRecord* walk_idles(const IdleChildren& children, std::uint32_t parent, ScriptHost& host,
                             std::vector<std::string>* unanswered, int depth) {
    if (depth > kMaxIdleDepth) return nullptr;
    for (const auto* idle : children(parent)) {
        if (!idle || idle->form_id == parent) continue;
        if (!evaluate_conditions(idle->conditions, host, unanswered)) continue;
        if (!idle->is_folder()) return idle;
        if (const auto* found = walk_idles(children, idle->form_id, host, unanswered, depth + 1)) return found;
    }
    return nullptr;
}

} // namespace

const IdleRecord* select_idle(const IdleChildren& children, ScriptHost& host, std::vector<std::string>* unanswered) {
    if (!children) return nullptr;
    return walk_idles(children, 0, host, unanswered, 0);
}

} // namespace oblivion
