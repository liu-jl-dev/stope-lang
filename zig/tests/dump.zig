//! 单行产物格式（docs/zh-cn/compiler-test-plan.md §2.3）—— 测试侧私有，不进库。
//! 照抄 python/tests/golden.py 的 dump_program。
const std = @import("std");
const stope = @import("stope");

const opcode = stope.opcode;
const Opcode = opcode.Opcode;

const builtin_names = [_][]const u8{
    "Assign", "PushNull", "PushFalse", "PushTrue", "PushInt", "PushFloat",
    "PushString", "PushBinArr", "PushValue", "PushId", "Call", "At", "Pop",
    "Minus", "Not", "Pow", "Mul", "Div", "IDiv", "Mod", "Add", "Sub", "EQ",
    "NE", "LT", "LE", "GT", "GE", "If", "GoTo", "GetArg", "ArgNum", "Return",
};

fn hasArg(op: u16, cfg: ?*opcode.CustomOpcodeConfig) bool {
    if (op > @intFromEnum(Opcode.Return)) {
        if (cfg == null) return false;
        var it = cfg.?.opcodes.valueIterator();
        while (it.next()) |info| {
            if (info.opcode == op) return info.is_var_arg;
        }
        return false;
    }
    return opcode.hasArg(op);
}

const fmtG = stope.format.fmtG;


fn esc(alloc: std.mem.Allocator, s: []const u8) ![]const u8 {
    var out = std.ArrayList(u8).empty;
    for (s) |c| {
        switch (c) {
            '\\' => try out.appendSlice(alloc, "\\\\"),
            '"' => try out.appendSlice(alloc, "\\\""),
            '\n' => try out.appendSlice(alloc, "\\n"),
            '\r' => try out.appendSlice(alloc, "\\r"),
            '\t' => try out.appendSlice(alloc, "\\t"),
            else => {
                if (c < 128) try out.append(alloc, c) else try out.append(alloc, '?');
            },
        }
    }
    return out.toOwnedSlice(alloc);
}

fn fmtBytes(alloc: std.mem.Allocator, bytes: []const u8) ![]const u8 {
    var out = std.ArrayList(u8).empty;
    for (bytes, 0..) |byte, i| {
        if (i > 0) try out.append(alloc, ',');
        var buf: [8]u8 = undefined;
        try out.appendSlice(alloc, try std.fmt.bufPrint(&buf, "{x:0>2}", .{byte}));
    }
    return out.toOwnedSlice(alloc);
}

pub fn dumpProgram(alloc: std.mem.Allocator, prog: *const stope.program.Program, cfg: ?*opcode.CustomOpcodeConfig) ![]const u8 {
    var out = std.ArrayList(u8).empty;
    try out.appendSlice(alloc, "code[");
    const ops = prog.opcodes.items;
    var i: usize = 0;
    while (i < ops.len) {
        if (i > 0) try out.append(alloc, ' ');
        const o: u16 = @bitCast(ops[i]);
        i += 1;
        var buf: [32]u8 = undefined;
        if (o > @intFromEnum(Opcode.Return)) {
            try out.appendSlice(alloc, try std.fmt.bufPrint(&buf, "Opcode({d})", .{o}));
        } else {
            try out.appendSlice(alloc, builtin_names[o]);
        }
        if (hasArg(o, cfg) and i < ops.len) {
            const arg: i16 = @bitCast(ops[i]);
            try out.appendSlice(alloc, try std.fmt.bufPrint(&buf, "({d})", .{arg}));
            i += 1;
        }
    }
    try out.appendSlice(alloc, "]");
    var scratch: [64]u8 = undefined;
    try out.appendSlice(alloc, try std.fmt.bufPrint(&scratch, " vars={d} stack={d} maxRet={d}", .{ prog.variable_num, prog.required_stack_size, prog.max_return_num }));
    try out.appendSlice(alloc, " ints=[");
    for (prog.int_consts.items, 0..) |v, k| {
        if (k > 0) try out.append(alloc, ',');
        try out.appendSlice(alloc, try std.fmt.bufPrint(&scratch, "{d}", .{v}));
    }
    try out.appendSlice(alloc, "] floats=[");
    for (prog.float_consts.items, 0..) |v, k| {
        if (k > 0) try out.append(alloc, ',');
        try out.appendSlice(alloc, try fmtG(alloc, v));
    }
    try out.appendSlice(alloc, "] strs=[");
    for (prog.string_consts.items, 0..) |v, k| {
        if (k > 0) try out.append(alloc, ',');
        try out.appendSlice(alloc, try esc(alloc, v));
    }
    try out.appendSlice(alloc, "] binarrs=[");
    for (prog.binarr_consts.items, 0..) |v, k| {
        if (k > 0) try out.append(alloc, ' ');
        try out.append(alloc, '[');
        try out.appendSlice(alloc, try fmtBytes(alloc, v));
        try out.append(alloc, ']');
    }
    try out.appendSlice(alloc, "] exports=[");
    // exports 按名字排序（C++ 是 std::map）
    var names = std.ArrayList([]const u8).empty;
    var it = prog.exports.keyIterator();
    while (it.next()) |k| try names.append(alloc, k.*);
    std.mem.sort([]const u8, names.items, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lessThan);
    for (names.items, 0..) |name, k| {
        if (k > 0) try out.append(alloc, ',');
        try out.appendSlice(alloc, try esc(alloc, name));
        try out.append(alloc, ':');
        try out.appendSlice(alloc, try std.fmt.bufPrint(&scratch, "{d}", .{prog.exports.get(name).?}));
    }
    try out.appendSlice(alloc, "]");
    return out.toOwnedSlice(alloc);
}
