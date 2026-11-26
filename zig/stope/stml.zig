//! STML 公共类型：Token / Element（对齐 python/stope/stml.py）。元素模型只有 6 字段。
const std = @import("std");

pub const TokenType = enum(u8) {
    Invalid, Eof, LAngle, RAngle, CLAngle, CRAngle, EQ, Word, String, Text, NevextSrc, StopeSrc,
};
const type_names = [_][]const u8{
    "Invalid", "Eof", "LAngle", "RAngle", "CLAngle", "CRAngle",
    "EQ", "Word", "String", "Text", "NevextSrc", "StopeSrc",
};
pub fn typeName(t: TokenType) []const u8 {
    return type_names[@intFromEnum(t)];
}

pub const LexerState = enum(u8) { Xml, Text, Nevext, Stope };

pub const Token = struct {
    typ: TokenType = .Invalid,
    line: i32 = -1,
    lexeme: []const u8 = "",
};

pub const Element = struct {
    line: i32 = -1,
    text_line: i32 = -1,
    tag: []const u8 = "",
    attrs: std.StringHashMap([]const u8),
    self_closing: bool = false,
    children: std.ArrayList(*Element),
    text: []const u8 = "",

    pub fn init(alloc: std.mem.Allocator) Element {
        return .{ .attrs = std.StringHashMap([]const u8).init(alloc), .children = std.ArrayList(*Element).empty };
    }
};
