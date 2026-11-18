#include "oblivion/quest_runtime.hpp"

#include <algorithm>
#include <iomanip>
#include <sstream>
#include <unordered_set>

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

namespace {

std::string condition_function_name(std::uint16_t function_index) {
    switch (function_index) {
    case 1: return "GetDistance";
    case 45: return "GetDetected";
    case 56: return "GetQuestRunning";
    case 58: return "GetStage";
    case 59: return "GetStageDone";
    case 60: return "GetInCell";
    case 69: return "GetIsRace";
    case 70: return "GetIsSex";
    case 72: return "GetIsID";
    case 79: return "GetQuestVariable";
    case 130: return "GetPCIsRace";
    case 131: return "GetPCIsSex";
    case 161: return "GetIsCurrentPackage";
    case 224: return "GetIsPlayerBirthsign";
    default: return "condition";
    }
}

std::string condition_operator_name(ConditionOperator operation) {
    switch (operation) {
    case ConditionOperator::Equal: return "==";
    case ConditionOperator::NotEqual: return "!=";
    case ConditionOperator::Greater: return ">";
    case ConditionOperator::GreaterEqual: return ">=";
    case ConditionOperator::Less: return "<";
    case ConditionOperator::LessEqual: return "<=";
    }
    return "?";
}

std::string failed_condition_detail(const QuestCondition& condition, const std::optional<double>& value,
                                   const std::optional<double>& comparison) {
    std::ostringstream detail;
    const auto name = condition_function_name(condition.function_index);
    detail << name << '[' << condition.function_index << ']';
    detail << "(p1=0x" << std::hex << std::setw(8) << std::setfill('0') << condition.parameter1
           << ", p2=" << std::dec << condition.parameter2 << ", runOn=" << condition.run_on << ") returned ";
    if (value) detail << std::setprecision(5) << std::defaultfloat << *value;
    else detail << "<unavailable>";
    detail << ", expected " << condition_operator_name(condition_operator(condition.operator_code)) << ' ';
    if (condition.comparison_is_global) {
        detail << "GLOB 0x" << std::hex << condition.comparison_global_form_id;
        detail << std::dec << "=";
        if (comparison) detail << std::setprecision(5) << std::defaultfloat << *comparison;
        else detail << "<unavailable>";
    } else {
        detail << std::dec << std::setprecision(5) << std::defaultfloat << condition.comparison;
    }
    return detail.str();
}

std::string failed_condition_key(const QuestCondition& condition) {
    std::ostringstream key;
    key << condition.function_index << ':' << condition.parameter1 << ':' << condition.parameter2 << ':'
        << condition.run_on << ':' << static_cast<unsigned>(condition.operator_code);
    if (condition.comparison_is_global) key << ":g" << condition.comparison_global_form_id;
    else key << ":v" << std::setprecision(5) << std::defaultfloat << condition.comparison;
    return key.str();
}

} // namespace

bool evaluate_conditions(const std::vector<QuestCondition>& conditions, ScriptHost& host,
                         std::vector<std::string>* unimplemented, ConditionEvaluation* evaluation) {
    ConditionEvaluation details;
    bool all = true;
    std::size_t index = 0;
    while (index < conditions.size()) {
        // One disjunction: conditions linked by OR, ending at the first one that does not join the next.
        bool any = false;
        bool joined = false;
        std::vector<std::string> failed_alternatives;
        std::vector<std::string> failed_keys;
        do {
            const auto& condition = conditions[index];
            const auto value = host.call_condition(condition.function_index, condition.parameter1, condition.parameter2,
                                                   condition.run_on);
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
            if (!holds && evaluation) {
                failed_alternatives.push_back(failed_condition_detail(condition, value, comparison));
                failed_keys.push_back(failed_condition_key(condition));
            }
            any = any || holds;
            joined = condition_joins_next(condition.operator_code);
            ++index;
        } while (joined && index < conditions.size());
        ++details.groups_total;
        if (any) {
            ++details.groups_passed;
        } else {
            all = false;
            if (evaluation) {
                std::ostringstream group;
                group << '[';
                for (std::size_t failure_index = 0; failure_index < failed_alternatives.size(); ++failure_index) {
                    if (failure_index > 0) group << " OR ";
                    group << failed_alternatives[failure_index];
                }
                group << ']';
                details.failed_groups.push_back(group.str());
                std::ostringstream key;
                for (std::size_t failure_index = 0; failure_index < failed_keys.size(); ++failure_index) {
                    if (failure_index > 0) key << '|';
                    key << failed_keys[failure_index];
                }
                details.failure_keys.push_back(key.str());
            }
        }
    }
    if (evaluation) *evaluation = std::move(details);
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

// `visited` holds the folders already walked: their conditions do not change during one pick, so a folder reached
// again (through a cycle or a second parent) finds nothing new, and the walk stays linear in broken data.
const IdleRecord* walk_idles(const IdleChildren& children, std::uint32_t parent, ScriptHost& host,
                             std::vector<std::string>* unanswered, int depth, std::unordered_set<std::uint32_t>& visited) {
    if (depth > kMaxIdleDepth || !visited.insert(parent).second) return nullptr;
    for (const auto* idle : children(parent)) {
        if (!idle || idle->form_id == parent) continue;
        if (!evaluate_conditions(idle->conditions, host, unanswered)) continue;
        if (!idle->is_folder()) return idle;
        if (const auto* found = walk_idles(children, idle->form_id, host, unanswered, depth + 1, visited)) return found;
    }
    return nullptr;
}

} // namespace

const IdleRecord* select_idle(const IdleChildren& children, ScriptHost& host, std::vector<std::string>* unanswered) {
    if (!children) return nullptr;
    std::unordered_set<std::uint32_t> visited;
    return walk_idles(children, 0, host, unanswered, 0, visited);
}

} // namespace oblivion
