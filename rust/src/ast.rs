//! AST 节点定义与形状串序列化 —— 对齐 `python/stope/ast.py`。
//!
//! `shape_prog` / `shape_stmt` / `shape_expr` 是**测试用**序列化，严格照抄
//! `cpp/test/test_common.hpp` 的同名函数。两点容易踩：
//!
//! * 失败路径返回 [`Expr::Err`]（line 恒为 -1），形状串打成 `Err(L-1)`；
//! * `IfStmt` 的 else 是 `Option`，其余块内 prog 永远是空 `Prog` 而不是 `None`。

use crate::utf::{esc, fmt_bytes, fmt_g};
use crate::token::{TokenType, type_name};

pub const K_DEFAULT_MAX_DEPTH: i32 = 256;

/// 10 档优先级，与 C++ 的 `OpPrecedence` 同序同值。
pub mod precedence {
    pub const LOWEST: i32 = 0;
    pub const OR: i32 = 1;
    pub const AND: i32 = 2;
    pub const EQUALS: i32 = 3;
    pub const LESS_GREATER: i32 = 4;
    pub const ADD_SUB: i32 = 5;
    pub const MUL_DIV: i32 = 6;
    pub const POW: i32 = 7;
    pub const PREFIX: i32 = 8;
    pub const PAREN: i32 = 9;
}

/// 二元运算符 → 优先级；调用 `()`、取元素 `[]` 也是二元形式，优先级最高。
pub fn binop_prec(t: TokenType) -> i32 {
    match t {
        TokenType::Or => precedence::OR,
        TokenType::And => precedence::AND,
        TokenType::EQ | TokenType::NE => precedence::EQUALS,
        TokenType::LT | TokenType::LE | TokenType::GT | TokenType::GE => precedence::LESS_GREATER,
        TokenType::Add | TokenType::Sub => precedence::ADD_SUB,
        TokenType::Mul | TokenType::Div | TokenType::IDiv | TokenType::Mod => precedence::MUL_DIV,
        TokenType::Pow => precedence::POW,
        TokenType::LParen | TokenType::LBrack => precedence::PAREN,
        _ => precedence::LOWEST,
    }
}

/// 二元运算符的显示文本（错误信息与 `to_str` 用）。
pub fn binop_literal(op: TokenType) -> &'static str {
    match op {
        TokenType::Or => "||",
        TokenType::And => "&&",
        TokenType::EQ => "==",
        TokenType::NE => "!=",
        TokenType::LT => "<",
        TokenType::LE => "<=",
        TokenType::GT => ">",
        TokenType::GE => ">=",
        TokenType::Add => "+",
        TokenType::Sub => "-",
        TokenType::Mul => "*",
        TokenType::Div => "/",
        TokenType::IDiv => "idiv",
        TokenType::Mod => "%",
        TokenType::Pow => "^",
        _ => "?",
    }
}

// ================================ 表达式 ================================

#[derive(Debug, Clone)]
pub enum Expr {
    /// 解析失败路径的裸节点（形状串 `Err(L行号)`，line 通常为 -1）。
    Err(i32),
    Null(i32),
    Bool(i32, bool),
    Int(i32, i64),
    Float(i32, f64),
    BinArr(i32, std::rc::Rc<Vec<u8>>),
    Str(i32, String),
    Ident(i32, String),
    Argc(i32),
    Args { line: i32, key_expr: Option<Box<Expr>> },
    UnaryOp { line: i32, op: TokenType, expr: Box<Expr> },
    BinaryOp { line: i32, op: TokenType, left: Box<Expr>, right: Box<Expr> },
    Call { line: i32, callee: Box<Expr>, args: Vec<Expr> },
    At { line: i32, container: Box<Expr>, key_exprs: Vec<Expr> },
    CustomOpcode { line: i32, opcode_name: String, args: Vec<Expr> },
}

impl Expr {
    pub fn line(&self) -> i32 {
        match self {
            Expr::Err(l) => *l,
            Expr::Null(l) => *l,
            Expr::Bool(l, _) => *l,
            Expr::Int(l, _) => *l,
            Expr::Float(l, _) => *l,
            Expr::BinArr(l, _) => *l,
            Expr::Str(l, _) => *l,
            Expr::Ident(l, _) => *l,
            Expr::Argc(l) => *l,
            Expr::Args { line, .. } => *line,
            Expr::UnaryOp { line, .. } => *line,
            Expr::BinaryOp { line, .. } => *line,
            Expr::Call { line, .. } => *line,
            Expr::At { line, .. } => *line,
            Expr::CustomOpcode { line, .. } => *line,
        }
    }
}

// ================================ 语句 ================================

#[derive(Debug, Clone)]
pub struct Prog {
    pub line: i32,
    pub stmts: Vec<Stmt>,
}

impl Default for Prog {
    fn default() -> Self {
        Prog { line: -1, stmts: Vec::new() }
    }
}

impl Prog {
    pub fn new(line: i32) -> Self {
        Prog { line, stmts: Vec::new() }
    }
}

#[derive(Debug, Clone)]
pub struct IfStmtElif {
    pub line: i32,
    pub cond: Box<Expr>,
    pub prog: Prog,
}

#[derive(Debug, Clone)]
pub enum Stmt {
    ExprStmt { line: i32, expr: Box<Expr> },
    Let { line: i32, has_assign: bool, idents: Vec<String>, expr: Option<Box<Expr>> },
    Return { line: i32, exprs: Vec<Expr> },
    Export { line: i32, idents: Vec<String> },
    Block { line: i32, prog: Prog },
    If {
        line: i32,
        cond: Box<Expr>,
        first_prog: Prog,
        elifs: Vec<IfStmtElif>,
        else_prog: Option<Prog>,
    },
    While { line: i32, cond: Option<Box<Expr>>, prog: Prog },
    Assign { line: i32, left: Box<Expr>, right: Box<Expr> },
    Break(i32),
    Continue(i32),
}

impl Stmt {
    pub fn line(&self) -> i32 {
        match self {
            Stmt::ExprStmt { line, .. } => *line,
            Stmt::Let { line, .. } => *line,
            Stmt::Return { line, .. } => *line,
            Stmt::Export { line, .. } => *line,
            Stmt::Block { line, .. } => *line,
            Stmt::If { line, .. } => *line,
            Stmt::While { line, .. } => *line,
            Stmt::Assign { line, .. } => *line,
            Stmt::Break(l) => *l,
            Stmt::Continue(l) => *l,
        }
    }
}

// ================================ 序列化：测试用 ================================
// 严格照抄 cpp/test/test_common.hpp 的 shapeExpr / shapeStmt / shapeProg。

pub fn shape_prog(p: &Prog) -> String {
    p.stmts.iter().map(shape_stmt).collect::<Vec<_>>().join(" ; ")
}

pub fn shape_stmt(s: &Stmt) -> String {
    match s {
        Stmt::ExprStmt { expr, .. } => format!("ExprStmt({})", shape_expr(expr)),
        Stmt::Let { idents, has_assign, expr, .. } => {
            let mut d = format!(
                "Let[{}]",
                idents.iter().map(|i| esc(i)).collect::<Vec<_>>().join(",")
            );
            if *has_assign {
                d += "=";
                match expr {
                    Some(e) => d += &shape_expr(e),
                    None => d += "null",
                }
            }
            d
        }
        Stmt::Return { exprs, .. } => format!(
            "Return({})",
            exprs.iter().map(shape_expr).collect::<Vec<_>>().join(", ")
        ),
        Stmt::Export { idents, .. } => format!(
            "Export[{}]",
            idents.iter().map(|i| esc(i)).collect::<Vec<_>>().join(",")
        ),
        Stmt::Block { prog, .. } => format!("Block{{{}}}", shape_prog(prog)),
        Stmt::If { cond, first_prog, elifs, else_prog, .. } => {
            let mut d = format!("If({}){{{}}}", shape_expr(cond), shape_prog(first_prog));
            for ei in elifs {
                d += &format!("Elif({}){{{}}}", shape_expr(&ei.cond), shape_prog(&ei.prog));
            }
            if let Some(ep) = else_prog {
                d += &format!("Else{{{}}}", shape_prog(ep));
            }
            d
        }
        Stmt::While { cond, prog, .. } => {
            let c = match cond {
                None => "null".to_string(),
                Some(e) => shape_expr(e),
            };
            format!("While({}){{{}}}", c, shape_prog(prog))
        }
        Stmt::Assign { left, right, .. } => {
            format!("Assign({}, {})", shape_expr(left), shape_expr(right))
        }
        Stmt::Break(_) => "Break".to_string(),
        Stmt::Continue(_) => "Continue".to_string(),
    }
}

pub fn shape_expr(e: &Expr) -> String {
    match e {
        Expr::Err(line) => format!("Err(L{})", line),
        Expr::Null(_) => "Null".to_string(),
        Expr::Argc(_) => "Argc".to_string(),
        Expr::Bool(_, v) => format!("Bool({})", if *v { "true" } else { "false" }),
        Expr::Int(_, v) => format!("Int({})", v),
        Expr::Float(_, v) => format!("Float({})", fmt_g(*v)),
        Expr::BinArr(_, v) => format!("BinArr[{}]", fmt_bytes(v)),
        Expr::Str(_, v) => format!("Str(\"{}\")", esc(v)),
        Expr::Ident(_, v) => format!("Ident({})", esc(v)),
        Expr::Args { key_expr, .. } => match key_expr {
            None => "Args(null)".to_string(),
            Some(k) => format!("Args({})", shape_expr(k)),
        },
        Expr::UnaryOp { op, expr, .. } => {
            format!("Unary({}, {})", type_name(*op), shape_expr(expr))
        }
        Expr::BinaryOp { op, left, right, .. } => format!(
            "Bin({}, {}, {})",
            type_name(*op),
            shape_expr(left),
            shape_expr(right)
        ),
        Expr::Call { callee, args, .. } => {
            let mut s = format!("Call({}", shape_expr(callee));
            for a in args {
                s += "; ";
                s += &shape_expr(a);
            }
            s + ")"
        }
        Expr::At { container, key_exprs, .. } => {
            let mut s = format!("At({}", shape_expr(container));
            for k in key_exprs {
                s += "; ";
                s += &shape_expr(k);
            }
            s + ")"
        }
        Expr::CustomOpcode { opcode_name, args, .. } => {
            let mut s = format!("Custom({}", esc(opcode_name));
            for a in args {
                s += "; ";
                s += &shape_expr(a);
            }
            s + ")"
        }
    }
}
