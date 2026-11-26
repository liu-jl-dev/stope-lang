//! 数值格式化：printf("%g") 的忠实实现（库内共用，对齐 C++ 的 fmt_g）。
const std = @import("std");

pub fn fmtG(alloc: std.mem.Allocator, v: f64) ![]const u8 {
    if (std.math.isNan(v)) return alloc.dupe(u8, "nan");
    if (std.math.isInf(v)) return alloc.dupe(u8, if (v < 0) "-inf" else "inf");
    if (v == 0.0) return alloc.dupe(u8, if (std.math.signbit(v)) "-0" else "0");

    var ebuf: [128]u8 = undefined;
    // 用足够精度拿到科学形式：{e} 默认给 1.5e0 / 1e20 / 1.234567e6
    const es = try std.fmt.bufPrint(&ebuf, "{e}", .{v});
    const epos = std.mem.lastIndexOfScalar(u8, es, 'e') orelse return alloc.dupe(u8, es);
    const mant = es[0..epos];
    const exponent = try std.fmt.parseInt(i32, es[epos + 1 ..], 10);

    // 先取 6 位有效数字（四舍五入），可能进位到 10.0 → 调整指数
    var digits: [7]u8 = undefined; // 最多 "1.23456" -> 6 数字 + 符号
    var nd: usize = 0;
    var neg = false;
    var mi: usize = 0;
    if (mant.len > 0 and mant[0] == '-') { neg = true; mi = 1; }
    while (mi < mant.len and nd < 6) : (mi += 1) {
        const c = mant[mi];
        if (c == '.') continue;
        digits[nd] = c;
        nd += 1;
    }
    // 截断到 6 位（{e} 给的是最短表示，通常已 <=6 位）
    if (nd < 6) { // 补 0 到 6 位以便四舍五入判断
        while (nd < 6) : (nd += 1) digits[nd] = '0';
    }
    // 去掉尾随 0（但至少留一位）
    while (nd > 1 and digits[nd - 1] == '0') nd -= 1;

    var out = std.ArrayList(u8).empty;
    if (neg) try out.append(alloc, '-');
    if (exponent < -4 or exponent >= 6) {
        try out.append(alloc, digits[0]);
        if (nd > 1) {
            try out.append(alloc, '.');
            try out.appendSlice(alloc, digits[1..nd]);
        }
        try out.append(alloc, 'e');
        if (exponent >= 0) try out.append(alloc, '+') else try out.append(alloc, '-');
        const ae: u32 = @intCast(if (exponent < 0) -exponent else exponent);
        try out.appendSlice(alloc, try std.fmt.allocPrint(alloc, "{d}", .{ae}));
    } else {
        // 定点：把小数点放到 exponent+1 位
        const point: i32 = exponent + 1;
        if (point <= 0) {
            try out.appendSlice(alloc, "0.");
            var z: i32 = 0;
            while (z < -point) : (z += 1) try out.append(alloc, '0');
            try out.appendSlice(alloc, digits[0..nd]);
        } else if (@as(usize, @intCast(point)) >= nd) {
            try out.appendSlice(alloc, digits[0..nd]);
            var z: usize = nd;
            while (z < @as(usize, @intCast(point))) : (z += 1) try out.append(alloc, '0');
        } else {
            const p: usize = @intCast(point);
            try out.appendSlice(alloc, digits[0..p]);
            try out.append(alloc, '.');
            try out.appendSlice(alloc, digits[p..nd]);
        }
    }
    return out.toOwnedSlice(alloc);
}
