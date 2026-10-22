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
            if (value) {
                switch (condition_operator(condition.operator_code)) {
                case ConditionOperator::Equal: holds = *value == condition.comparison; break;
                case ConditionOperator::NotEqual: holds = *value != condition.comparison; break;
                case ConditionOperator::Greater: holds = *value > condition.comparison; break;
                case ConditionOperator::GreaterEqual: holds = *value >= condition.comparison; break;
                case ConditionOperator::Less: holds = *value < condition.comparison; break;
                case ConditionOperator::LessEqual: holds = *value <= condition.comparison; break;
                }
            } else if (unimplemented) {
                const auto name = "condition " + std::to_string(condition.function_index);
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

} // namespace oblivion
