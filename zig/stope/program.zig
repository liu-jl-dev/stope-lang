//! 编译产物 Program：指令流 + 常量池 + 变量表（对齐 cpp/include/stope/program.hpp）。
const std = @import("std");

pub const Program = struct {
    alloc: std.mem.Allocator,
    opcodes: std.ArrayList(u16),
    variable_num: i32 = 0,
    exports: std.StringHashMap(i32),
    int_consts: std.ArrayList(i64),
    float_consts: std.ArrayList(f64),
    string_consts: std.ArrayList([]const u8),
    binarr_consts: std.ArrayList([]const u8),
    max_return_num: i32 = 0,
    required_stack_size: i32 = 0,

    pub fn init(alloc: std.mem.Allocator) Program {
        return .{
            .alloc = alloc,
            .opcodes = std.ArrayList(u16).empty,
            .exports = std.StringHashMap(i32).init(alloc),
            .int_consts = std.ArrayList(i64).empty,
            .float_consts = std.ArrayList(f64).empty,
            .string_consts = std.ArrayList([]const u8).empty,
            .binarr_consts = std.ArrayList([]const u8).empty,
        };
    }

    pub fn clear(self: *Program) void {
        self.opcodes.clearRetainingCapacity();
        self.int_consts.clearRetainingCapacity();
        self.float_consts.clearRetainingCapacity();
        self.string_consts.clearRetainingCapacity();
        self.binarr_consts.clearRetainingCapacity();
        self.exports.clearRetainingCapacity();
        self.variable_num = 0;
        self.max_return_num = 0;
        self.required_stack_size = 0;
    }
};
