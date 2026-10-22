#pragma once

#include <cstddef>
#include <string>
#include <vector>

namespace oblivion {

enum class ScriptExprKind {
    Number,  // text holds the literal
    String,  // text holds the contents without quotes
    Name,    // a variable, reference, quest or other bare identifier
    Call,    // text is the command name; children are the arguments
    Member,  // children[0] is the target reference, children[1] is the Call
    Binary,  // text is the operator; children are the operands
    Unary,   // text is the operator; children[0] is the operand
};

struct ScriptExpr {
    ScriptExprKind kind = ScriptExprKind::Name;
    std::string text;
    std::size_t line = 0;
    std::vector<ScriptExpr> children;
};

struct ScriptStmt;

struct ScriptBranch {
    ScriptExpr condition;
    std::vector<ScriptStmt> body;
};

enum class ScriptStmtKind {
    Set,         // name is the variable, or ref.variable; value is children[0]
    If,          // branches holds if and elseif arms; else_body holds else
    Return,
    Expression,  // a command call used as a statement; value is children[0]
};

struct ScriptStmt {
    ScriptStmtKind kind = ScriptStmtKind::Expression;
    std::size_t line = 0;
    std::string name;
    std::vector<ScriptExpr> children;
    std::vector<ScriptBranch> branches;
    std::vector<ScriptStmt> else_body;
};

struct ScriptDeclaration {
    std::string type;
    std::string name;
    std::size_t line = 0;
};

struct ScriptBlock {
    std::string name;
    // Optional object the block is about, e.g. the player in `begin OnDeath player`.
    std::string target;
    std::size_t line = 0;
    std::vector<ScriptStmt> body;
};

struct ScriptDiagnostic {
    std::size_t line = 0;
    std::string message;
};

struct ScriptAst {
    std::string name;
    std::vector<ScriptDeclaration> declarations;
    std::vector<ScriptBlock> blocks;
    std::vector<ScriptDiagnostic> diagnostics;
};

} // namespace oblivion
