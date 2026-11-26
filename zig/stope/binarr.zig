//! 二进制数组字面量内容解析（照搬 python/stope/binarr_parser.py）。
//! 无前缀按 16；b/o/d/x 切进制；段内可含下划线；超 0xFF 静默截断。
const std = @import("std");

fn isWs(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r' or c == 0x0b or c == 0x0c;
}

fn digitOf(c: u8, base: u8) i32 {
    const d: i32 = if (c >= '0' and c <= '9') c - '0' else if (c >= 'a' and c <= 'f') c - 'a' + 10 else if (c >= 'A' and c <= 'F') c - 'A' + 10 else -1;
    return if (d >= 0 and d < base) d else -1;
}

const int_max: i64 = 2147483647;

/// 成功返回字节列表；失败返回 error.InvalidBinaryArray。
pub fn parseBinaryArray(alloc: std.mem.Allocator, src: []const u8) ![]const u8 {
    var out = std.ArrayList(u8).empty;
    var pos: usize = 0;
    while (pos < src.len and isWs(src[pos])) pos += 1;
    var base: u8 = 16;
    if (pos < src.len) {
        switch (src[pos]) {
            'b', 'B' => { base = 2; pos += 1; },
            'o', 'O' => { base = 8; pos += 1; },
            'd', 'D' => { base = 10; pos += 1; },
            'x', 'X' => { base = 16; pos += 1; },
            else => {},
        }
    }
    while (pos < src.len and isWs(src[pos])) pos += 1;
    while (pos < src.len) {
        var n: i64 = 0;
        var any_digit = false;
        var failed = false;
        while (pos < src.len and !isWs(src[pos])) {
            const c = src[pos];
            const d = digitOf(c, base);
            if (d >= 0) {
                if (n > @divTrunc(int_max - d, base)) {
                    failed = true;
                    break;
                }
                n = n * base + d;
                pos += 1;
                any_digit = true;
            } else if (c == '_') {
                pos += 1;
            } else {
                pos += 1;
                failed = true;
                break;
            }
        }
        if (failed or !any_digit) return error.InvalidBinaryArray;
        try out.append(alloc, @intCast(n & 0xff));
        while (pos < src.len and isWs(src[pos])) pos += 1;
    }
    return out.toOwnedSlice(alloc);
}
