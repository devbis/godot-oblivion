#pragma once

#include <cstdint>
#include <string>
#include <vector>

#include "oblivion/script_interpreter.hpp"
#include "oblivion/esm4_database.hpp"
#include "oblivion/script_records.hpp"

namespace oblivion {

enum class ConditionOperator { Equal, NotEqual, Greater, GreaterEqual, Less, LessEqual };

// The CTDA operator byte: the high nibble is the operator (0x00 ==, 0x20 !=,
// 0x40 >, 0x60 >=, 0x80 <, 0xA0 <=); bit 0x01 joins the condition to the next one
// with OR. The mapping is consistent with the distribution in the master's quests.
ConditionOperator condition_operator(std::uint8_t code);
bool condition_joins_next(std::uint8_t code);

// Evaluates a CTDA list. Conditions are ANDed, except that a run of conditions
// joined by OR counts as one disjunction. Conditions whose function the host does
// not implement are false and are named in `unimplemented`, once each.
bool evaluate_conditions(const std::vector<QuestCondition>& conditions, ScriptHost& host,
                         std::vector<std::string>* unimplemented = nullptr);

// The package EvaluatePackage starts: the first package, in the actor's PKID order, whose
// conditions hold. Returns null when none holds. Unanswered conditions count as false.
const AiPackageRecord* select_package(const std::vector<const AiPackageRecord*>& packages, ScriptHost& host,
                                      std::vector<std::string>* unanswered = nullptr);

} // namespace oblivion
