//! 指令集与自定义指令登记表。33 条内置指令，编号与 C++ 逐项相同（0..32）。
const std = @import("std");

pub const Opcode = enum(u16) {
    Assign = 0,
    PushNull,
    PushFalse,
    PushTrue,
    PushInt,
    PushFloat,
    PushString,
    PushBinArr,
    PushValue,
    PushId,
    Call,
    At,
    Pop,
    Minus,
    Not,
    Pow,
    Mul,
    Div,
    IDiv,
    Mod,
    Add,
    Sub,
    EQ,
    NE,
    LT,
    LE,
    GT,
    GE,
    If,
    GoTo,
    GetArg,
    ArgNum,
    Return,
};

pub const kFirstCustomOpcode: u16 = @intFromEnum(Opcode.Return) + 1;

/// 带操作数的内置指令（操作数紧跟在 opcodes 里）。自定义指令由登记表决定。
pub fn hasArg(op: u16) bool {
    if (op > @intFromEnum(Opcode.Return)) return false; // 自定义指令由调用方查表
    const o: Opcode = @enumFromInt(op);
    return switch (o) {
        .PushInt, .PushFloat, .PushString, .PushBinArr, .PushValue, .PushId,
        .Call, .At, .If, .GoTo, .Return => true,
        else => false,
    };
}

pub const CustomOpcode = struct {
    opcode: u16,
    arg_num: i32,
    is_var_arg: bool,
};

pub const CustomOpcodeConfig = struct {
    alloc: std.mem.Allocator,
    opcodes: std.StringHashMap(CustomOpcode),

    pub fn init(alloc: std.mem.Allocator) CustomOpcodeConfig {
        return .{ .alloc = alloc, .opcodes = std.StringHashMap(CustomOpcode).init(alloc) };
    }
    pub fn add(self: *CustomOpcodeConfig, name: []const u8, opcode: u16, arg_num: i32) !void {
        try self.opcodes.put(name, .{ .opcode = opcode, .arg_num = arg_num, .is_var_arg = arg_num < 0 });
    }
    pub fn find(self: *CustomOpcodeConfig, name: []const u8) ?CustomOpcode {
        return self.opcodes.get(name);
    }
};
