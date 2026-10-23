#pragma once

#include <cstdint>
#include <functional>
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

// The children of an idle node (0: the roots) in sibling order, as the database keeps them.
using IdleChildren = std::function<const std::vector<const IdleRecord*>&(std::uint32_t parent_form_id)>;

// The idle PickIdle plays: walks the idle tree in sibling order from the roots. A node whose conditions
// do not hold is skipped with everything below it. A folder (no .kf) whose subtree yields an idle gives that
// idle, otherwise the walk goes on with its next sibling; the first animation node whose conditions hold wins.
// The choice is deterministic: the same state of the quests and the same actor always give the same idle.
// Returns null when nothing matches. Conditions the host cannot answer count as false and are named in `unanswered`.
const IdleRecord* select_idle(const IdleChildren& children, ScriptHost& host,
                              std::vector<std::string>* unanswered = nullptr);

} // namespace oblivion
