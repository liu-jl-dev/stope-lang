//! 二进制数组字面量【内容】的解析 —— 对齐 `cpp/src/parse_binarr.cpp`。
//!
//! * `b/B o/O d/D x/X` 前缀选进制；**没有前缀按 16**（首字符就是数据本身）；
//! * 每段数字产生一个字节，超一个字节**静默截断**到低 8 位；
//! * 出现该进制不允许的字符 → [`Result::Error`]，上层报 `invalid binary array. `；
//! * 空内容合法；只有前缀没有数据（`'b'`）也是零长数组；
//! * `'b 0100 0001'` 是**两个**字节 `04 01`，不是 `0x41`。

use crate::common::Result;

const INT_MAX: i64 = 2147483647;

fn is_ws(c: u8) -> bool {
    matches!(c, b' ' | b'\t' | b'\n' | b'\r' | 0x0b | 0x0c)
}

/// 返回该进制下的数值；不是该进制的字符返回 -1。
fn digit_of(c: u8, base: u32) -> i64 {
    let d = match c {
        b'0'..=b'9' => (c - b'0') as i64,
        b'a'..=b'f' => (c - b'a') as i64 + 10,
        b'A'..=b'F' => (c - b'A') as i64 + 10,
        _ => -1,
    };
    if d >= 0 && d < base as i64 {
        d
    } else {
        -1
    }
}

/// 解析 `'...'` 里的内容（不含单引号），字节按顺序 push 进 `output`。
pub fn parse_binary_array(input: &str, output: &mut Vec<u8>) -> Result {
    let bytes = input.as_bytes();
    let mut pos = 0usize;
    let skip_ws = |pos: &mut usize| {
        while *pos < bytes.len() && is_ws(bytes[*pos]) {
            *pos += 1;
        }
    };
    skip_ws(&mut pos);
    if pos >= bytes.len() {
        return Result::Success;
    }
    let base: u32 = match bytes[pos] {
        b'b' | b'B' => {
            pos += 1;
            2
        }
        b'o' | b'O' => {
            pos += 1;
            8
        }
        b'd' | b'D' => {
            pos += 1;
            10
        }
        b'x' | b'X' => {
            pos += 1;
            16
        }
        _ => 16,
    };
    // parse_by_base
    skip_ws(&mut pos);
    while pos < bytes.len() {
        // parse_integer
        let mut n: i64 = 0;
        let mut any_digit = false;
        while pos < bytes.len() {
            let c = bytes[pos];
            if is_ws(c) {
                break;
            }
            let d = digit_of(c, base);
            if d >= 0 {
                if n > (INT_MAX - d) / base as i64 {
                    return Result::Error;
                }
                n = n * base as i64 + d;
                pos += 1;
                any_digit = true;
            } else if c == b'_' {
                pos += 1;
            } else {
                return Result::Error;
            }
        }
        if !any_digit {
            return Result::Error;
        }
        output.push((n & 0xFF) as u8);
        skip_ws(&mut pos);
    }
    Result::Success
}
