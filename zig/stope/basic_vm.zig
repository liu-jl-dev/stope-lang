//! 参考执行器（照搬 python/stope/basic_vm.py）—— 33 条内置指令，step/run 各写一遍。
//! 不是标准的一部分；值语义对齐 C++ 的 6 种可观测值（bool=整数 1/0）。
const std = @import("std");
const op = @import("opcode.zig");
const program = @import("program.zig");
const common = @import("expr_optim.zig");
const format = @import("format.zig");
const Opcode = op.Opcode;
const Program = program.Program;

pub const HostFn = *const fn (ctx: ?*anyopaque, args: []const Value) Value;

pub const Handle = struct { data: ?*anyopaque = null };

pub const Value = union(enum) {
    null_,
    integer: i64,
    float: f64,
    string: []const u8,
    binarr: []const u8,
    host_fn: struct { ctx: ?*anyopaque, func: HostFn },
    identifier: i32, // PushId 压的槽位引用，只有 Assign 认它
    handle: Handle,

    fn isInt(v: Value) bool {
        return v == .integer;
    }
    fn isFloat(v: Value) bool {
        return v == .float;
    }
    fn isNumber(v: Value) bool {
        return v == .integer or v == .float;
    }
    fn isSeq(v: Value) bool {
        return v == .string or v == .binarr;
    }
    fn asDouble(v: Value) f64 {
        return switch (v) {
            .integer => |x| @floatFromInt(x),
            .float => |x| x,
            else => 0.0,
        };
    }
};

pub fn truely(v: Value) bool {
    return switch (v) {
        .null_ => false,
        .integer => |x| x != 0,
        .float => |x| x != 0.0,
        .string => |s| s.len != 0,
        .binarr => |b| b.len != 0,
        .host_fn => true,
        else => true,
    };
}

pub fn equals(a: Value, b: Value) bool {
    if (a == .null_ or b == .null_) return a == .null_ and b == .null_;
    if (a == .integer and b == .integer) return a.integer == b.integer;
    if (a == .integer and b == .float) return @as(f64, @floatFromInt(a.integer)) == b.float;
    if (a == .float and b == .integer) return a.float == @as(f64, @floatFromInt(b.integer));
    if (a == .float and b == .float) return a.float == b.float;
    if (a == .string and b == .string) return std.mem.eql(u8, a.string, b.string);
    if (a == .binarr and b == .binarr) return std.mem.eql(u8, a.binarr, b.binarr);
    if (a == .host_fn and b == .host_fn) return a.host_fn.func == b.host_fn.func and a.host_fn.ctx == b.host_fn.ctx;
    if (a == .handle and b == .handle) return a.handle.data == b.handle.data;
    return false;
}

/// 实参表接口（宿主实现）。取不到时自己调 s.error 并返回 .null_。
pub const Arguments = struct {
    ctx: ?*anyopaque,
    at: *const fn (?*anyopaque, *State, Value) Value,
    num: *const fn (?*anyopaque) i32,
};

pub const State = struct {
    alloc: std.mem.Allocator,
    prog: *const Program,
    args: ?*const Arguments = null,
    returns: std.ArrayList(Value),
    variables: []Value,
    stack: std.ArrayList(Value),
    errors: std.ArrayList([]const u8),
    i: usize = 0,
    custom_ops: std.AutoHashMap(u16, Handler),

    pub const Handler = *const fn (*State) anyerror!void;

    pub fn init(alloc: std.mem.Allocator, prog: *const Program) !State {
        const vars = try alloc.alloc(Value, @intCast(@max(prog.variable_num, 0)));
        for (vars) |*v| v.* = .null_;
        var custom = std.AutoHashMap(u16, Handler).init(alloc);
        try installBuiltins(&custom);
        return .{
            .alloc = alloc,
            .prog = prog,
            .returns = std.ArrayList(Value).empty,
            .variables = vars,
            .stack = std.ArrayList(Value).empty,
            .errors = std.ArrayList([]const u8).empty,
            .custom_ops = custom,
        };
    }

    pub fn addError(self: *State, msg: []const u8) !void {
        try self.errors.append(self.alloc, try std.fmt.allocPrint(self.alloc, "{d}: {s}", .{ self.i, msg }));
    }
    fn atTop(self: *State, k: usize) Value {
        return self.stack.items[self.stack.items.len - k];
    }
    fn storeBinary(self: *State, v: Value) void {
        _ = self.stack.pop();
        self.stack.items[self.stack.items.len - 1] = v;
    }
    fn readOperand(self: *State) i32 {
        self.i += 1;
        return @as(i16, @bitCast(self.prog.opcodes.items[self.i]));
    }
    fn checkArith(self: *State, opname: []const u8, l: Value, r: Value) !bool {
        if (l == .null_ or r == .null_) {
            try self.addError(try std.fmt.allocPrint(self.alloc, "\"{s}\" cannot operate on null. ", .{opname}));
            return false;
        }
        if (!l.isNumber() or !r.isNumber()) {
            try self.addError(try std.fmt.allocPrint(self.alloc, "\"{s}\" can only operate on integer or float. ", .{opname}));
            return false;
        }
        return true;
    }
    fn checkIntZero(self: *State, opname: []const u8, l: Value, r: Value) !bool {
        if (l == .integer and r == .integer and r.integer == 0) {
            try self.addError(try std.fmt.allocPrint(self.alloc, "\"{s}\" division by zero. ", .{opname}));
            return false;
        }
        return true;
    }
    fn lessThan(self: *State, l: Value, r: Value) !bool {
        if (l.isNumber() and r.isNumber()) return l.asDouble() < r.asDouble();
        try self.addError("only on integer or float can be compared. ");
        return false;
    }

    /// 执行一条指令。errors 非空或指令流走完时不做事。
    pub fn step(self: *State) !bool {
        if (self.errors.items.len > 0) return false;
        if (self.i >= self.prog.opcodes.items.len) return true;
        const raw = self.prog.opcodes.items[self.i];
        const o: u16 = @bitCast(raw);
        if (self.custom_ops.get(o)) |h| {
            try h(self);
        } else {
            try self.addError(try std.fmt.allocPrint(self.alloc, "no implement for opcode {d}. ", .{o}));
        }
        if (self.errors.items.len > 0) return false;
        self.i += 1;
        return true;
    }

    /// 执行到结束（与 step 独立的两份实现）。
    pub fn run(self: *State) !bool {
        const ops = self.prog.opcodes.items;
        const n = ops.len;
        while (self.i < n) {
            const o: u16 = @bitCast(ops[self.i]);
            if (self.custom_ops.get(o)) |h| {
                try h(self);
            } else {
                try self.addError(try std.fmt.allocPrint(self.alloc, "no implement for opcode {d}. ", .{o}));
            }
            if (self.errors.items.len > 0) return false;
            self.i += 1;
        }
        return true;
    }
};

// ============================== 33 条指令 ==============================
fn opAssign(s: *State) !void {
    if (s.stack.items.len < 2) { try s.addError("stack underflow. "); return; }
    const target = s.atTop(2);
    const val = s.stack.items[s.stack.items.len - 1];
    switch (target) {
        .identifier => |idx| {
            s.variables[@intCast(idx)] = val;
            _ = s.stack.pop(); _ = s.stack.pop();
        },
        .handle => {
            try s.addError("no implement for value type. ");
        },
        else => try s.addError("no implement for value type. "),
    }
}
fn opPushNull(s: *State) !void { try s.stack.append(s.alloc, .null_); }
fn opPushFalse(s: *State) !void { try s.stack.append(s.alloc, .{ .integer = 0 }); }
fn opPushTrue(s: *State) !void { try s.stack.append(s.alloc, .{ .integer = 1 }); }
fn opPushInt(s: *State) !void {
    const idx = s.readOperand();
    try s.stack.append(s.alloc, .{ .integer = s.prog.int_consts.items[@intCast(idx)] });
}
fn opPushFloat(s: *State) !void {
    const idx = s.readOperand();
    try s.stack.append(s.alloc, .{ .float = s.prog.float_consts.items[@intCast(idx)] });
}
fn opPushString(s: *State) !void {
    const idx = s.readOperand();
    try s.stack.append(s.alloc, .{ .string = s.prog.string_consts.items[@intCast(idx)] });
}
fn opPushBinArr(s: *State) !void {
    const idx = s.readOperand();
    try s.stack.append(s.alloc, .{ .binarr = s.prog.binarr_consts.items[@intCast(idx)] });
}
fn opPushValue(s: *State) !void {
    const idx = s.readOperand();
    try s.stack.append(s.alloc, s.variables[@intCast(idx)]);
}
fn opPushId(s: *State) !void {
    const idx = s.readOperand();
    try s.stack.append(s.alloc, .{ .identifier = idx });
}
fn opCall(s: *State) !void {
    const arg_num = s.readOperand();
    const callee = s.atTop(@intCast(arg_num + 1));
    if (callee != .host_fn) { try s.addError("\"Call\" can only call a function. "); return; }
    var argv = try s.alloc.alloc(Value, @intCast(arg_num));
    var k: i32 = arg_num;
    while (k > 0) : (k -= 1) argv[@intCast(k - 1)] = s.atTop(@intCast(k));
    const out = callee.host_fn.func(callee.host_fn.ctx, argv);
    var j: i32 = 0;
    while (j < arg_num) : (j += 1) _ = s.stack.pop();
    s.stack.items[s.stack.items.len - 1] = out;
}
fn opAt(s: *State) !void {
    const key_num = s.readOperand();
    if (key_num != 1) { try s.addError("no implement for key num != 1. "); return; }
    const container = s.atTop(2);
    const key = s.atTop(1);
    if (key != .integer) { try s.addError("index must be integer. "); return; }
    const index = key.integer;
    var result: Value = .null_;
    if (container == .binarr) {
        if (index < 0 or index >= @as(i64, @intCast(container.binarr.len))) { try s.addError("index out of range. "); return; }
        result = .{ .integer = container.binarr[@intCast(index)] };
    } else if (container == .string) {
        // UTF-16 码元：把字符串按 UTF-16LE 展开再按码元取
        var units = std.ArrayList(u16).empty;
        var view = std.unicode.Utf8View.init(container.string) catch {
            try s.addError("index out of range. "); return;
        };
        var it = view.iterator();
        while (it.nextCodepoint()) |cp| {
            if (cp <= 0xffff) {
                try units.append(s.alloc, @intCast(cp));
            } else {
                const x = cp - 0x10000;
                try units.append(s.alloc, @intCast(0xd800 + (x >> 10)));
                try units.append(s.alloc, @intCast(0xdc00 + (x & 0x3ff)));
            }
        }
        if (index < 0 or index >= @as(i64, @intCast(units.items.len))) { try s.addError("index out of range. "); return; }
        result = .{ .integer = units.items[@intCast(index)] };
    } else {
        try s.addError("no implement for container type. "); return;
    }
    _ = s.stack.pop(); _ = s.stack.pop();
    try s.stack.append(s.alloc, result);
}
fn opPop(s: *State) !void { _ = s.stack.pop(); }
fn opMinus(s: *State) !void {
    const v = s.stack.items[s.stack.items.len - 1];
    switch (v) {
        .integer => |x| s.stack.items[s.stack.items.len - 1] = .{ .integer = -%x },
        .float => |x| s.stack.items[s.stack.items.len - 1] = .{ .float = -x },
        else => try s.addError("\"Minus\" can only operate on integer or float. "),
    }
}
fn opNot(s: *State) !void {
    const v = s.stack.items[s.stack.items.len - 1];
    switch (v) {
        .null_ => s.stack.items[s.stack.items.len - 1] = .{ .integer = 1 },
        .integer => |x| s.stack.items[s.stack.items.len - 1] = .{ .integer = if (x == 0) 1 else 0 },
        .float => |x| s.stack.items[s.stack.items.len - 1] = .{ .integer = if (x == 0.0) 1 else 0 },
        else => try s.addError("\"Not\" can only operate on integer or float. "),
    }
}
fn opPow(s: *State) !void {
    const l = s.atTop(2); const r = s.atTop(1);
    if (!try s.checkArith("Pow", l, r)) return;
    if (l == .integer and r == .integer and r.integer >= 0) {
        s.storeBinary(.{ .integer = common.intPow(l.integer, r.integer) });
    } else {
        s.storeBinary(.{ .float = common.fpow(l.asDouble(), r.asDouble()) });
    }
}
fn opMul(s: *State) !void {
    const l = s.atTop(2); const r = s.atTop(1);
    if (l == .null_ or r == .null_) { try s.addError("\"Mul\" cannot operate on null. "); return; }
    if (l.isNumber() and r.isNumber()) {
        if (l == .integer and r == .integer) {
            s.storeBinary(.{ .integer = common.intMul(l.integer, r.integer) });
        } else s.storeBinary(.{ .float = l.asDouble() * r.asDouble() });
        return;
    }
    if ((l.isSeq() and r == .integer) or (l == .integer and r.isSeq())) {
        const seq = if (l.isSeq()) l else r;
        const times = if (l.isSeq()) r.integer else l.integer;
        if (times < 0) { try s.addError("\"Mul\" cannot repeat a sequence by a negative number. "); return; }
        const src = if (seq == .string) seq.string else seq.binarr;
        var out = std.ArrayList(u8).empty;
        var t: i64 = 0;
        while (t < times) : (t += 1) try out.appendSlice(s.alloc, src);
        s.storeBinary(if (seq == .string) .{ .string = try out.toOwnedSlice(s.alloc) } else .{ .binarr = try out.toOwnedSlice(s.alloc) });
        return;
    }
    try s.addError("\"Mul\" can only operate on numbers, or repeat a string / bin array by an integer. ");
}
fn opDiv(s: *State) !void {
    const l = s.atTop(2); const r = s.atTop(1);
    if (!try s.checkArith("Div", l, r)) return;
    if (!try s.checkIntZero("Div", l, r)) return;
    if (l == .integer and r == .integer) {
        if (common.intMod(l.integer, r.integer) == 0) {
            s.storeBinary(.{ .integer = common.intDiv(l.integer, r.integer) });
        } else {
            s.storeBinary(.{ .float = fdiv(l.asDouble(), r.asDouble()) });
        }
    } else s.storeBinary(.{ .float = fdiv(l.asDouble(), r.asDouble()) });
}
fn opIDiv(s: *State) !void {
    const l = s.atTop(2); const r = s.atTop(1);
    if (!try s.checkArith("IDiv", l, r)) return;
    if (!try s.checkIntZero("IDiv", l, r)) return;
    if (l == .integer and r == .integer) {
        s.storeBinary(.{ .integer = common.intDiv(l.integer, r.integer) });
    } else {
        s.storeBinary(.{ .float = trunc(fdiv(l.asDouble(), r.asDouble())) });
    }
}
fn opMod(s: *State) !void {
    const l = s.atTop(2); const r = s.atTop(1);
    if (!try s.checkArith("Mod", l, r)) return;
    if (!try s.checkIntZero("Mod", l, r)) return;
    if (l == .integer and r == .integer) {
        s.storeBinary(.{ .integer = common.intMod(l.integer, r.integer) });
    } else s.storeBinary(.{ .float = fmod(l.asDouble(), r.asDouble()) });
}
fn opAdd(s: *State) !void {
    const l = s.atTop(2); const r = s.atTop(1);
    if (l == .null_ or r == .null_) { try s.addError("\"Add\" cannot operate on null. "); return; }
    if (l == .integer) {
        if (r == .integer) s.storeBinary(.{ .integer = common.intAdd(l.integer, r.integer) })
        else if (r == .float) s.storeBinary(.{ .float = @as(f64, @floatFromInt(l.integer)) + r.float })
        else try s.addError("integer can only add integer or float. ");
    } else if (l == .float) {
        if (r.isNumber()) s.storeBinary(.{ .float = l.float + r.asDouble() })
        else try s.addError("float can only add integer or float. ");
    } else if (l == .string and r == .string) {
        s.storeBinary(.{ .string = try std.mem.concat(s.alloc, u8, &.{ l.string, r.string }) });
    } else if (l == .binarr and r == .binarr) {
        s.storeBinary(.{ .binarr = try std.mem.concat(s.alloc, u8, &.{ l.binarr, r.binarr }) });
    } else try s.addError("\"Add\" can only operate on numbers, strings or bin arrays. ");
}
fn opSub(s: *State) !void {
    const l = s.atTop(2); const r = s.atTop(1);
    if (!try s.checkArith("Sub", l, r)) return;
    if (l == .integer) {
        if (r == .integer) s.storeBinary(.{ .integer = common.intSub(l.integer, r.integer) })
        else if (r == .float) s.storeBinary(.{ .float = @as(f64, @floatFromInt(l.integer)) - r.float })
        else try s.addError("integer can only subtract integer or float. ");
    } else if (l == .float) {
        if (r.isNumber()) s.storeBinary(.{ .float = l.float - r.asDouble() })
        else try s.addError("float can only subtract integer or float. ");
    } else try s.addError("\"Sub\" can only operate on integer or float. ");
}
fn opEq(s: *State) !void { s.storeBinary(.{ .integer = if (equals(s.atTop(2), s.atTop(1))) 1 else 0 }); }
fn opNe(s: *State) !void { s.storeBinary(.{ .integer = if (equals(s.atTop(2), s.atTop(1))) 0 else 1 }); }
fn opLt(s: *State) !void { s.storeBinary(.{ .integer = if (try s.lessThan(s.atTop(2), s.atTop(1))) 1 else 0 }); }
fn opLe(s: *State) !void { s.storeBinary(.{ .integer = if (try s.lessThan(s.atTop(1), s.atTop(2))) 0 else 1 }); }
fn opGt(s: *State) !void { s.storeBinary(.{ .integer = if (try s.lessThan(s.atTop(1), s.atTop(2))) 1 else 0 }); }
fn opGe(s: *State) !void { s.storeBinary(.{ .integer = if (try s.lessThan(s.atTop(2), s.atTop(1))) 0 else 1 }); }
fn opIf(s: *State) !void {
    const yes = truely(s.stack.items[s.stack.items.len - 1]);
    _ = s.stack.pop();
    const target = s.readOperand();
    if (!yes) s.i = @as(usize, @intCast(target)) - 1;
}
fn opGoTo(s: *State) !void {
    const target = s.readOperand();
    s.i = @as(usize, @intCast(target)) - 1;
}
fn opGetArg(s: *State) !void {
    if (s.args == null) { try s.addError("no args. "); return; }
    const key = s.stack.pop().?;
    const v = s.args.?.at(s.args.?.ctx, s, key);
    try s.stack.append(s.alloc, v);
}
fn opArgNum(s: *State) !void {
    if (s.args == null) { try s.addError("no args. "); return; }
    try s.stack.append(s.alloc, .{ .integer = s.args.?.num(s.args.?.ctx) });
}
fn opReturn(s: *State) !void {
    const num = s.readOperand();
    s.returns.clearRetainingCapacity();
    var k: i32 = num;
    while (k > 0) : (k -= 1) try s.returns.append(s.alloc, s.atTop(@intCast(k)));
    s.i = s.prog.opcodes.items.len;
}

fn fdiv(a: f64, b: f64) f64 {
    if (b != 0.0) return a / b;
    if (a == 0.0 or std.math.isNan(a)) return std.math.nan(f64);
    return std.math.copysign(std.math.inf(f64), a) * std.math.copysign(@as(f64, 1.0), b);
}
fn fmod(a: f64, b: f64) f64 {
    if (b == 0.0 or std.math.isNan(a) or std.math.isNan(b)) return std.math.nan(f64);
    return @rem(a, b);
}
fn trunc(v: f64) f64 {
    if (common.isSpecial(v)) return v;
    return @trunc(v);
}

fn installBuiltins(map: *std.AutoHashMap(u16, State.Handler)) !void {
    const handlers = [_]State.Handler{
        opAssign, opPushNull, opPushFalse, opPushTrue, opPushInt,
        opPushFloat, opPushString, opPushBinArr, opPushValue, opPushId,
        opCall, opAt, opPop, opMinus, opNot,
        opPow, opMul, opDiv, opIDiv, opMod,
        opAdd, opSub, opEq, opNe, opLt,
        opLe, opGt, opGe, opIf, opGoTo,
        opGetArg, opArgNum, opReturn,
    };
    for (handlers, 0..) |h, i| try map.put(@intCast(i), h);
}

/// 紧凑值格式（测试用，对齐 python/tests/test_vm.py 的 _fmt）。
pub fn fmtValue(alloc: std.mem.Allocator, v: Value) ![]const u8 {
    switch (v) {
        .null_ => return alloc.dupe(u8, "null"),
        .integer => |x| return std.fmt.allocPrint(alloc, "{d}", .{x}),
        .float => |x| {
            if (std.math.isNan(x)) return alloc.dupe(u8, "nan");
            if (std.math.isInf(x)) return alloc.dupe(u8, if (x < 0) "-inf" else "inf");
            const t = try format.fmtG(alloc, x);
            if (std.mem.indexOfScalar(u8, t, '.') == null and std.mem.indexOfScalar(u8, t, 'e') == null) {
                return std.mem.concat(alloc, u8, &.{ t, ".0" });
            }
            return t;
        },
        .string => |s| return alloc.dupe(u8, s),
        .binarr => |b| {
            var out = std.ArrayList(u8).empty;
            try out.append(alloc, '[');
            for (b, 0..) |byte, i| {
                if (i > 0) try out.append(alloc, ',');
                try out.appendSlice(alloc, try std.fmt.allocPrint(alloc, "{d}", .{byte}));
            }
            try out.append(alloc, ']');
            return out.toOwnedSlice(alloc);
        },
        else => return alloc.dupe(u8, "<other>"),
    }
}
