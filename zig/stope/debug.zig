//! 反汇编（照搬 python/stope/debug.py）。输出与 C++/GD/Node/C# 逐字节一致。
const std = @import("std");
const op = @import("opcode.zig");
const program = @import("program.zig");
const format = @import("format.zig");
const Opcode = op.Opcode;

const names = [_][]const u8{
    "Assign", "PushNull", "PushFalse", "PushTrue", "PushInt",
    "PushFloat", "PushString", "PushBinArr", "PushValue", "PushId",
    "Call", "At", "Pop", "Minus", "Not",
    "Pow", "Mul", "Div", "IDiv", "Mod",
    "Add", "Sub", "EQ", "NE", "LT",
    "LE", "GT", "GE", "If", "GoTo",
    "GetArg", "ArgNum", "Return",
};
const min_name_width: usize = 10;

fn padRight(alloc: std.mem.Allocator, s: []const u8, width: usize) ![]const u8 {
    const n = s.len; // 名字是 ASCII
    if (n >= width) return alloc.dupe(u8, s);
    const out = try alloc.alloc(u8, width);
    @memcpy(out[0..n], s);
    @memset(out[n..], ' ');
    return out;
}

const fmtG = format.fmtG;


pub fn opcodeHasArg(raw: i32) bool {
    if (raw >= @intFromEnum(Opcode.PushInt) and raw <= @intFromEnum(Opcode.At)) return true;
    return raw == @intFromEnum(Opcode.If) or raw == @intFromEnum(Opcode.GoTo) or raw == @intFromEnum(Opcode.Return);
}

pub fn disasm(alloc: std.mem.Allocator, prog: *const program.Program, cfg: ?*op.CustomOpcodeConfig) ![]const u8 {
    var out = std.ArrayList(u8).empty;
    const ByOpcode = struct { name: []const u8, info: op.CustomOpcode };
    var by_opcode = std.AutoHashMap(i32, ByOpcode).init(alloc);
    var warnings = std.ArrayList([]const u8).empty;
    var name_width: usize = min_name_width;

    if (cfg) |config| {
        // 按名字字典序建表（撞号时"谁赢"与 C++ 一致）
        var names_list = std.ArrayList([]const u8).empty;
        var kit = config.opcodes.keyIterator();
        while (kit.next()) |k| try names_list.append(alloc, k.*);
        std.mem.sort([]const u8, names_list.items, {}, struct {
            fn lt(_: void, a: []const u8, b: []const u8) bool {
                return std.mem.order(u8, a, b) == .lt;
            }
        }.lt);
        for (names_list.items) |name| {
            const info = config.opcodes.get(name).?;
            const raw: i32 = @intCast(info.opcode);
            if (raw < op.kFirstCustomOpcode) {
                const what = if (raw >= 0 and raw < names.len) names[@intCast(raw)] else "(not an opcode)";
                try warnings.append(alloc, try std.fmt.allocPrint(alloc, "custom opcode \"{s}\" uses #{d}, which collides with {s}; builtin decoding wins.", .{ name, raw, what }));
                continue;
            }
            if (by_opcode.get(raw)) |prev| {
                try warnings.append(alloc, try std.fmt.allocPrint(alloc, "custom opcodes \"{s}\" and \"{s}\" share #{d}; the former wins.", .{ prev.name, name, raw }));
                continue;
            }
            try by_opcode.put(raw, .{ .name = name, .info = info });
            if (name.len > name_width) name_width = name.len;
        }
    }

    var unknown = std.ArrayList(i32).empty;
    const ops = prog.opcodes.items;
    var i: usize = 0;
    while (i < ops.len) {
        const raw: i32 = @as(i16, @bitCast(ops[i]));
        var has_arg = false;
        var name: []const u8 = undefined;
        if (raw >= 0 and raw < names.len) {
            name = names[@intCast(raw)];
            has_arg = opcodeHasArg(raw);
        } else if (by_opcode.get(raw)) |ent| {
            name = ent.name;
            has_arg = ent.info.is_var_arg;
        } else {
            name = if (raw > @as(i32, @intFromEnum(Opcode.Return)))
                try std.fmt.allocPrint(alloc, "Custom{d}", .{raw})
            else
                try std.fmt.allocPrint(alloc, "Op#{d}", .{raw});
            var seen = false;
            for (unknown.items) |u| if (u == raw) { seen = true; break; };
            if (!seen) try unknown.append(alloc, raw);
        }
        const idx_s = try std.fmt.allocPrint(alloc, "[{d}]", .{i});
        try out.appendSlice(alloc, try padRight(alloc, idx_s, 8));
        try out.appendSlice(alloc, try padRight(alloc, name, name_width));
        try out.append(alloc, ' ');
        i += 1;
        if (has_arg) {
            if (i < ops.len) {
                try out.appendSlice(alloc, try std.fmt.allocPrint(alloc, "{d}", .{@as(i16, @bitCast(ops[i]))}));
                i += 1;
            } else {
                try out.appendSlice(alloc, "<missing operand>");
                try warnings.append(alloc, try std.fmt.allocPrint(alloc, "opcode at [{d}] expects an operand but the stream ends there.", .{i - 1}));
            }
        }
        try out.append(alloc, '\n');
    }

    if (by_opcode.count() > 0) {
        try out.appendSlice(alloc, "custom opcodes:\n");
        var keys = std.ArrayList(i32).empty;
        var kit2 = by_opcode.keyIterator();
        while (kit2.next()) |k| try keys.append(alloc, k.*);
        std.mem.sort(i32, keys.items, {}, struct {
            fn lt(_: void, a: i32, b: i32) bool { return a < b; }
        }.lt);
        for (keys.items) |k| {
            const ent = by_opcode.get(k).?;
            try out.appendSlice(alloc, "  ");
            try out.appendSlice(alloc, try padRight(alloc, ent.name, name_width));
            try out.appendSlice(alloc, try std.fmt.allocPrint(alloc, " -> {d}", .{k}));
            if (ent.info.is_var_arg) {
                try out.appendSlice(alloc, " (vararg)\n");
            } else {
                try out.appendSlice(alloc, try std.fmt.allocPrint(alloc, " ({d} args)\n", .{ent.info.arg_num}));
            }
        }
    }

    try out.appendSlice(alloc, "variables:\n");
    const variables = try alloc.alloc([]const u8, @intCast(@max(prog.variable_num, 0)));
    for (variables) |*v| v.* = "";
    var eit = prog.exports.iterator();
    while (eit.next()) |ent| {
        const idx = ent.value_ptr.*;
        if (idx >= 0 and idx < variables.len) variables[@intCast(idx)] = ent.key_ptr.*;
    }
    try out.append(alloc, ' ');
    try out.append(alloc, ' ');
    for (variables, 0..) |v, k| {
        if (k > 0) try out.append(alloc, ' ');
        try out.append(alloc, '"');
        try out.appendSlice(alloc, v);
        try out.append(alloc, '"');
    }
    try out.append(alloc, '\n');

    try out.appendSlice(alloc, "int consts:\n");
    for (prog.int_consts.items) |v| {
        try out.appendSlice(alloc, "  ");
        try out.appendSlice(alloc, try std.fmt.allocPrint(alloc, "{d}", .{v}));
    }
    try out.appendSlice(alloc, "\nfloat consts:\n");
    for (prog.float_consts.items) |v| {
        try out.appendSlice(alloc, "  ");
        try out.appendSlice(alloc, try fmtG(alloc, v));
    }
    try out.appendSlice(alloc, "\nstring consts:\n");
    for (prog.string_consts.items) |v| {
        try out.appendSlice(alloc, "  \"");
        try out.appendSlice(alloc, v);
        try out.appendSlice(alloc, "\"\n");
    }
    try out.appendSlice(alloc, "binary array consts:\n");
    for (prog.binarr_consts.items) |v| {
        try out.appendSlice(alloc, try std.fmt.allocPrint(alloc, "  {d} bytes\n", .{v.len}));
    }
    try out.appendSlice(alloc, try std.fmt.allocPrint(alloc, "max return num: {d}\n", .{prog.max_return_num}));
    try out.appendSlice(alloc, try std.fmt.allocPrint(alloc, "required stack size: {d}\n", .{prog.required_stack_size}));

    for (unknown.items) |raw| {
        if (raw > @as(i32, @intFromEnum(Opcode.Return))) {
            try warnings.append(alloc, try std.fmt.allocPrint(alloc, "opcode #{d} is not a builtin; pass the CustomOpcodeConfig to Disasm() to decode it.", .{raw}));
        } else {
            try warnings.append(alloc, try std.fmt.allocPrint(alloc, "opcode #{d} is not a valid instruction (unpatched placeholder?).", .{raw}));
        }
    }
    for (warnings.items) |w| {
        try out.appendSlice(alloc, "warning: ");
        try out.appendSlice(alloc, w);
        try out.append(alloc, '\n');
    }
    return out.toOwnedSlice(alloc);
}
