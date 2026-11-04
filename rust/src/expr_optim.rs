//! 常量折叠 —— 对齐 `python/stope/expr_optim.py` / `cpp/src/expr_optim.cpp`（C++ 权威）。
//!
//! * 只做「**单节点**」变换，不递归；挂在 parser 构造 `UnaryOpExpr` / `BinaryOpExpr`
//!   的末尾，子节点返回时就已折好，整棵树自底向上折叠完毕；
//! * 成功折叠时返回**新**节点，未折叠时返回入参本身；折叠后的节点沿用运算符节点的
//!   `line`；
//! * 拿不准就一律不折叠：除零、含浮点的 `idiv`、跨类型 `==`、`null` 参与比较、
//!   `Bool` 参与比较 —— 全部保留原节点；
//! * 整数**溢出不检查、按 64 位回绕**（Rust 用 `wrapping_*`）；整数除法向零取整。
//!
//! 判断顺序与 C++ 一一对应：L0 两侧都是字面量 → L1 and/or → L2 任一侧 null →
//! L3 比较 → L4 算术。

use crate::ast::Expr;
use crate::common::{int_div, int_mod, int_pow};
use crate::token::TokenType;
use std::rc::Rc;

pub const MAX_REPEAT_ELEM: i64 = 1 << 20; // 串重复的元素数上限：1 M

/// 常量分类（与 python 的常量分类同名）。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Kind {
    NotConst,
    Null,
    Bool,
    Int,
    Float,
    String,
    BinArr,
}

fn kind_of(e: &Expr) -> Kind {
    match e {
        Expr::Null(_) => Kind::Null,
        Expr::Bool(_, _) => Kind::Bool,
        Expr::Int(_, _) => Kind::Int,
        Expr::Float(_, _) => Kind::Float,
        Expr::Str(_, _) => Kind::String,
        Expr::BinArr(_, _) => Kind::BinArr,
        _ => Kind::NotConst,
    }
}

fn is_const(k: Kind) -> bool {
    k != Kind::NotConst
}

fn is_numeric(k: Kind) -> bool {
    k == Kind::Int || k == Kind::Float
}

fn both_int(lk: Kind, rk: Kind) -> bool {
    lk == Kind::Int && rk == Kind::Int
}

fn is_seq(k: Kind) -> bool {
    k == Kind::String || k == Kind::BinArr
}

/// 「算术上下文」里的 Bool：视作 0 / 1 的整数（只对 `+ - * / idiv % ^` 生效）。
fn is_num_like(k: Kind) -> bool {
    k == Kind::Bool || is_numeric(k)
}

/// 两侧都参与整数运算（Bool 算整数），只有出现 Float 才走浮点分支。
fn both_num_int(lk: Kind, rk: Kind) -> bool {
    is_num_like(lk) && is_num_like(rk) && lk != Kind::Float && rk != Kind::Float
}

fn num_as_int(e: &Expr) -> i64 {
    match e {
        Expr::Bool(_, v) => {
            if *v {
                1
            } else {
                0
            }
        }
        Expr::Int(_, v) => *v,
        _ => 0,
    }
}

fn as_double(e: &Expr) -> f64 {
    match e {
        Expr::Bool(_, v) => {
            if *v {
                1.0
            } else {
                0.0
            }
        }
        Expr::Int(_, v) => *v as f64,
        Expr::Float(_, v) => *v,
        _ => 0.0,
    }
}

fn seq_size(e: &Expr) -> i64 {
    match e {
        Expr::Str(_, s) => s.len() as i64,
        Expr::BinArr(_, b) => b.len() as i64,
        _ => 0,
    }
}

fn truthy(e: &Expr) -> bool {
    match e {
        Expr::Null(_) => false,
        Expr::Bool(_, v) => *v,
        Expr::Int(_, v) => *v != 0,
        Expr::Float(_, v) => *v != 0.0,
        Expr::Str(_, s) => !s.is_empty(),
        Expr::BinArr(_, b) => !b.is_empty(),
        _ => false,
    }
}

/// 入口：返回一个（可能是新的）节点 —— 成功折叠时是新常量节点，否则是入参本身。
pub fn optimize(e: Expr) -> Expr {
    match e {
        Expr::UnaryOp { .. } => fold_unary(e),
        Expr::BinaryOp { .. } => fold_binary(e),
        other => other,
    }
}

// ==================== 造节点 / 拷贝常量 / 取负 / 串重复 ====================

fn make_bool(line: i32, v: bool) -> Expr {
    Expr::Bool(line, v)
}

fn make_int(line: i32, v: i64) -> Expr {
    Expr::Int(line, v)
}

fn make_float(line: i32, v: f64) -> Expr {
    Expr::Float(line, v)
}

fn make_seq(line: i32, k: Kind) -> Expr {
    match k {
        Kind::String => Expr::Str(line, String::new()),
        _ => Expr::BinArr(line, Rc::new(Vec::new())),
    }
}

/// 取负：Int/Float 同类型取负；Bool 转成 Int 取负；null / 序列不可取负。
fn negate_const(line: i32, e: &Expr) -> Option<Expr> {
    match e {
        Expr::Bool(_, v) => Some(make_int(line, if *v { -1 } else { 0 })),
        Expr::Int(_, v) => Some(make_int(line, v.wrapping_neg())),
        Expr::Float(_, v) => Some(make_float(line, -*v)),
        _ => None,
    }
}

/// 串重复：`"ab" * 3` / `'x 41' * 3`；负次或结果过大 → None（不折叠）。
fn repeat_seq(line: i32, base: &Expr, times: i64) -> Option<Expr> {
    if times < 0 {
        return None;
    }
    let k = kind_of(base);
    let unit = seq_size(base);
    if unit == 0 {
        return Some(make_seq(line, k)); // 空串/空数组的任意次重复仍是空
    }
    if times > MAX_REPEAT_ELEM / unit {
        return None;
    }
    match base {
        Expr::Str(_, s) => Some(Expr::Str(line, s.repeat(times as usize))),
        Expr::BinArr(_, b) => {
            let mut out = Vec::with_capacity((unit * times) as usize);
            for _ in 0..times {
                out.extend_from_slice(b);
            }
            Some(Expr::BinArr(line, Rc::new(out)))
        }
        _ => None,
    }
}

fn cmp_of(op: TokenType, a: f64, b: f64) -> bool {
    match op {
        TokenType::LT => a < b,
        TokenType::LE => a <= b,
        TokenType::GT => a > b,
        _ => a >= b,
    }
}

// ==================== 一元 ====================

fn fold_unary(e: Expr) -> Expr {
    let Expr::UnaryOp { line, op, expr } = e else {
        return e;
    };
    let ck = kind_of(&expr);
    if !is_const(ck) {
        return Expr::UnaryOp { line, op, expr };
    }
    let ret = match op {
        // `!` 走 truthy；序列与 Bool 之外的非常量已在上面挡掉
        TokenType::Not if ck == Kind::Null || is_num_like(ck) => {
            Some(make_bool(line, !truthy(&expr)))
        }
        TokenType::Sub => negate_const(line, &expr),
        _ => None,
    };
    ret.unwrap_or(Expr::UnaryOp { line, op, expr })
}

// ==================== 二元 ====================

fn fold_binary(e: Expr) -> Expr {
    let Expr::BinaryOp { line, op, left, right } = e else {
        return e;
    };
    match try_fold_binary(line, op, &left, &right) {
        Some(ret) => ret,
        None => Expr::BinaryOp { line, op, left, right },
    }
}

fn try_fold_binary(line: i32, op: TokenType, l: &Expr, r: &Expr) -> Option<Expr> {
    let lk = kind_of(l);
    let rk = kind_of(r);
    // L0 两侧必须都是字面量常量：否则既算不出值，也可能吞掉 Call/Custom 的副作用
    if !is_const(lk) || !is_const(rk) {
        return None;
    }

    // ---------- L1 and / or：结果与类型无关，恒返回 Bool ----------
    if op == TokenType::And {
        return Some(make_bool(line, truthy(l) && truthy(r)));
    }
    if op == TokenType::Or {
        return Some(make_bool(line, truthy(l) || truthy(r)));
    }

    // ---------- L2 null 参与 ----------
    // null 不是数字，也不参与算术：`+ - * / idiv % ^` 一律不折叠，交给后端报错。
    // 只有 `==` `!=` 有确定结论：null 只与 null 相等。
    if lk == Kind::Null || rk == Kind::Null {
        let both_null = lk == Kind::Null && rk == Kind::Null;
        if op == TokenType::EQ {
            return Some(make_bool(line, both_null));
        }
        if op == TokenType::NE {
            return Some(make_bool(line, !both_null));
        }
        return None;
    }

    // ---------- L3 相等与大小比较（到这里两侧都非 null；跨类型一律不折叠） ----------
    if op == TokenType::EQ || op == TokenType::NE {
        let mut decided = false;
        let mut eq = false;
        if lk == Kind::Bool && rk == Kind::Bool {
            decided = true;
            eq = bool_of(l) == bool_of(r);
        } else if is_numeric(lk) && is_numeric(rk) {
            decided = true;
            eq = if both_int(lk, rk) {
                int_of(l) == int_of(r)
            } else {
                as_double(l) == as_double(r)
            };
        } else if is_seq(lk) && lk == rk {
            decided = true;
            eq = seq_equal(l, r);
        }
        if decided {
            return Some(make_bool(line, if op == TokenType::EQ { eq } else { !eq }));
        }
        return None;
    }
    if matches!(op, TokenType::LT | TokenType::LE | TokenType::GT | TokenType::GE) {
        // Bool 与序列不参与数值比较 → 两侧都必须是 Int / Float
        if is_numeric(lk) && is_numeric(rk) {
            return Some(make_bool(
                line,
                if both_int(lk, rk) {
                    cmp_of(op, int_of(l) as f64, int_of(r) as f64)
                } else {
                    cmp_of(op, as_double(l), as_double(r))
                },
            ));
        }
        return None;
    }

    // ---------- L4 算术 + - * / idiv % ^ ----------
    if is_num_like(lk) {
        // ===== L4a 左值是 Bool / Int / Float =====
        match op {
            TokenType::Add | TokenType::Sub | TokenType::Mul => {
                if is_num_like(rk) {
                    if both_num_int(lk, rk) {
                        // 两侧都没有 Float -> 整数路径，溢出不检查、按 64 位回绕
                        let a = num_as_int(l);
                        let b = num_as_int(r);
                        let v = match op {
                            TokenType::Add => a.wrapping_add(b),
                            TokenType::Sub => a.wrapping_sub(b),
                            _ => a.wrapping_mul(b),
                        };
                        return Some(make_int(line, v));
                    }
                    // 任一侧是 Float -> 浮点路径
                    let (x, y) = (as_double(l), as_double(r));
                    let v = match op {
                        TokenType::Add => x + y,
                        TokenType::Sub => x - y,
                        _ => x * y,
                    };
                    return Some(make_float(line, v));
                } else if op == TokenType::Mul && is_seq(rk) && lk != Kind::Float {
                    return repeat_seq(line, r, num_as_int(l)); // 数字 * 串 == 串重复
                }
            }
            TokenType::Div => {
                if is_num_like(rk) {
                    if both_num_int(lk, rk) {
                        let a = num_as_int(l);
                        let b = num_as_int(r);
                        // 除零 -> 不折叠；除不尽 -> 浮点数
                        if b != 0 {
                            return Some(if int_mod(a, b) == 0 {
                                make_int(line, int_div(a, b))
                            } else {
                                make_float(line, a as f64 / b as f64)
                            });
                        }
                    } else {
                        let bb = as_double(r);
                        if bb != 0.0 {
                            return Some(make_float(line, as_double(l) / bb));
                        }
                    }
                }
            }
            TokenType::IDiv => {
                if both_num_int(lk, rk) {
                    // 含浮点 -> 收窄成整数，不折叠
                    let a = num_as_int(l);
                    let b = num_as_int(r);
                    if b != 0 {
                        return Some(make_int(line, int_div(a, b))); // 向零取整
                    }
                }
            }
            TokenType::Mod => {
                if is_num_like(rk) {
                    if both_num_int(lk, rk) {
                        let a = num_as_int(l);
                        let b = num_as_int(r);
                        if b != 0 {
                            return Some(make_int(line, int_mod(a, b)));
                        }
                    } else {
                        let bb = as_double(r);
                        if bb != 0.0 {
                            // 必须 fmod：Rust 的 `%` 对 f64 就是 std::fmod 语义
                            return Some(make_float(line, as_double(l) % bb));
                        }
                    }
                }
            }
            TokenType::Pow => {
                if is_num_like(rk) {
                    if both_num_int(lk, rk) {
                        let b = num_as_int(r);
                        // 非负整数指数走快速幂（溢出回绕）；负指数落到浮点分支
                        if b >= 0 {
                            return Some(make_int(line, int_pow(num_as_int(l), b)));
                        }
                    }
                    // 负指数 / 含浮点：必须 powf（负底数 + 分数指数 → NaN）
                    let rr = crate::common::fpow(as_double(l), as_double(r));
                    if !crate::common::is_special(rr) {
                        return Some(make_float(line, rr)); // NaN / Inf -> 不折叠
                    }
                }
            }
            _ => {}
        }
    } else if is_seq(lk) {
        // ===== L4b 左值是序列（String / BinArr）=====
        match op {
            TokenType::Add if rk == lk => {
                // 同类才连接：字符串拼接 / 字节连接（跨类型不折）
                match (l, r) {
                    (Expr::Str(_, a), Expr::Str(_, b)) => {
                        let mut s = a.clone();
                        s.push_str(b);
                        return Some(Expr::Str(line, s));
                    }
                    (Expr::BinArr(_, a), Expr::BinArr(_, b)) => {
                        let mut v = (**a).clone();
                        v.extend_from_slice(b);
                        return Some(Expr::BinArr(line, Rc::new(v)));
                    }
                    _ => {}
                }
            }
            TokenType::Mul if rk == Kind::Int || rk == Kind::Bool => {
                return repeat_seq(line, l, num_as_int(r)); // 串 * 整数 == 串重复
            }
            _ => {}
        }
        // 其余运算符（Sub 等）对序列无定义 -> 不折叠
    }
    None
}

fn int_of(e: &Expr) -> i64 {
    match e {
        Expr::Bool(_, v) => {
            if *v {
                1
            } else {
                0
            }
        }
        Expr::Int(_, v) => *v,
        _ => 0,
    }
}

fn bool_of(e: &Expr) -> bool {
    match e {
        Expr::Bool(_, v) => *v,
        _ => false,
    }
}

fn seq_equal(a: &Expr, b: &Expr) -> bool {
    match (a, b) {
        (Expr::Str(_, x), Expr::Str(_, y)) => x == y,
        (Expr::BinArr(_, x), Expr::BinArr(_, y)) => x == y,
        _ => false,
    }
}
