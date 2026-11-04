//! 返回码 + 数值助手（整数 int64 语义 / 浮点 IEEE 语义）。
//!
//! 对齐 `python/stope/common.py` / `cpp/src/` 的 `stope::Result`。整数的溢出回绕
//! 由 Rust 原生 `wrapping_*` 承担（debug 模式下普通算术会 panic，所以**全程**
//! 只准走这里的 helper —— 常量折叠与 BasicVM 共用同一套，保证同一个表达式两边
//! 给出同一个答案）。

use std::num::FpCategory;

/// 与 C++ 的 `stope::Result` / Python 的 `Result` 逐值对应。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Result {
    Success = 0,
    Error = 1,
    UnknownError = 2,
    DuplicateWithBuiltinOpcode = 3,
}

/// 向零取整的整除（C++ 的 `/` 语义），结果按 64 位回绕。`b` 为 0 时返回 0
/// （调用方在整数路径上必须先用 [`is_int_zero`] 拦住除零）。
#[inline]
pub fn int_div(a: i64, b: i64) -> i64 {
    // i64::MIN / -1 在 Rust 是 panic（结果回绕后仍是 i64::MIN）
    if a == i64::MIN && b == -1 {
        return i64::MIN;
    }
    a.wrapping_div(b)
}

/// 向零取整的余数（C++ 的 `%` 语义），结果按 64 位回绕。
#[inline]
pub fn int_mod(a: i64, b: i64) -> i64 {
    a.wrapping_sub(int_div(a, b).wrapping_mul(b))
}

/// 整数快速幂，`exp >= 0`；溢出不检查、按 64 位回绕（与 C++ 走 unsigned 一致）。
#[inline]
pub fn int_pow(base: i64, exp: i64) -> i64 {
    let mut result: i64 = 1;
    let mut b = base;
    let mut e = exp;
    while e > 0 {
        if e & 1 == 1 {
            result = result.wrapping_mul(b);
        }
        e >>= 1;
        if e > 0 {
            b = b.wrapping_mul(b);
        }
    }
    result
}

/// `nan` / `±inf` —— 这几个值过比较会给出意外结果。
#[inline]
pub fn is_special(v: f64) -> bool {
    !matches!(v.classify(), FpCategory::Normal | FpCategory::Zero | FpCategory::Subnormal)
}

/// 整数除零判定：只有两侧都是整数且除数为 0 才算（任一侧浮点走 IEEE）。
#[inline]
pub fn is_int_zero(left_is_int: bool, right_is_int: bool, right: i64) -> bool {
    left_is_int && right_is_int && right == 0
}

/// `std::pow` 语义：负底数 + 非整数指数得 nan、溢出得 ±inf、`0 ^ 负数` 得 inf。
/// Rust 的 `f64::powf` 与 C 的 `std::pow` 同为 IEEE 推荐实现，语义天然一致。
#[inline]
pub fn fpow(a: f64, b: f64) -> f64 {
    a.powf(b)
}

/// `std::fmod`：余数符号跟**被除数**。Rust 的 `%` 对 f64 就是 fmod 语义；
/// `b == 0` 得 nan 而不是 panic，与 C 一致。
#[inline]
pub fn fmod(a: f64, b: f64) -> f64 {
    a % b
}

/// IEEE 除法：`x / 0` 得 ±inf、`0 / 0` 得 nan（Rust 原生即如此，这里只是统一入口）。
#[inline]
pub fn fdiv(a: f64, b: f64) -> f64 {
    a / b
}

/// `std::trunc`：向零取整但保持浮点；对 inf / nan 原样返回。
#[inline]
pub fn ftrunc(v: f64) -> f64 {
    v.trunc()
}
