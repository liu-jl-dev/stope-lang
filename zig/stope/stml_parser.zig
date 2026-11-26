//! STML 语法分析器 —— 照搬 python/stope/stml_parser.py。
const std = @import("std");
const stml = @import("stml.zig");
const stml_lexer = @import("stml_lexer.zig");
const Element = stml.Element;
const Token = stml.Token;
const TokenType = stml.TokenType;
const LexerState = stml.LexerState;

pub const StateFunc = *const fn (tag: []const u8) LexerState;

pub fn defaultStateFunc(tag: []const u8) LexerState {
    if (std.mem.eql(u8, tag, "sto")) return .Stope;
    if (std.mem.eql(u8, tag, "nev")) return .Nevext;
    if (std.mem.eql(u8, tag, "p")) return .Text;
    return .Xml;
}

pub const Parser = struct {
    alloc: std.mem.Allocator,
    lexer: *stml_lexer.Lexer,
    state_func: ?StateFunc,
    errors: std.ArrayList([]const u8),
    token: Token = .{},
    max_depth: i32 = 256,
    aborted: bool = false,

    pub fn init(alloc: std.mem.Allocator, lx: *stml_lexer.Lexer) Parser {
        return .{ .alloc = alloc, .lexer = lx, .state_func = null, .errors = std.ArrayList([]const u8).empty };
    }

    pub fn parse(self: *Parser, root: *Element, sf: ?StateFunc) !bool {
        self.state_func = sf;
        self.aborted = false;
        try self.nextToken();
        try self.parseElement(root, 1);
        return self.errors.items.len == 0;
    }

    fn parseElement(self: *Parser, e: *Element, depth: i32) anyerror!void {
        if (self.aborted) return;
        if (self.max_depth > 0 and depth > self.max_depth) {
            try self.addError(try std.fmt.allocPrint(self.alloc, "nesting too deep (max {d}). ", .{self.max_depth}));
            self.aborted = true;
            return;
        }
        self.lexer.state = .Xml;
        e.line = self.token.line;
        if (self.token.typ != .LAngle) { try self.addError("expected \"<\". "); return; }
        try self.nextToken();
        if (self.token.typ != .Word) { try self.addError("expected tag name. "); return; }
        e.tag = self.token.lexeme;
        try self.nextToken();
        while (true) {
            if (self.token.typ == .RAngle) break;
            if (self.token.typ == .CRAngle) { e.self_closing = true; return; }
            if (self.token.typ == .Word) {
                const name = self.token.lexeme;
                try self.nextToken();
                if (self.token.typ == .EQ) {
                    try self.nextToken();
                    if (self.token.typ != .String) { try self.addError("expected string. "); return; }
                    if (!e.attrs.contains(name)) try e.attrs.put(name, self.token.lexeme);
                    try self.nextToken();
                } else {
                    if (!e.attrs.contains(name)) try e.attrs.put(name, "");
                }
            } else {
                try self.addError("expected \">\" or \"/>\" or attribute. ");
                return;
            }
        }
        self.lexer.state = if (self.state_func) |sf| sf(e.tag) else .Xml;
        if (self.lexer.state == .Xml) {
            while (true) {
                try self.nextToken();
                if (self.token.typ == .CLAngle) break;
                if (self.token.typ == .LAngle) {
                    const child = try self.alloc.create(Element);
                    child.* = Element.init(self.alloc);
                    try e.children.append(self.alloc, child);
                    try self.parseElement(child, depth + 1);
                    if (self.aborted) return;
                } else {
                    try self.addError("expected \"<\" or \"</\". ");
                    return;
                }
            }
        } else {
            try self.nextToken();
            if (self.token.typ != .Text and self.token.typ != .NevextSrc and self.token.typ != .StopeSrc) {
                try self.addError("expected element content. ");
                return;
            }
            e.text = self.token.lexeme;
            e.text_line = self.token.line;
            try self.nextToken();
        }
        try self.nextToken();
        if (self.token.typ != .Word) { try self.addError("expected tag name. "); return; }
        if (!std.mem.eql(u8, self.token.lexeme, e.tag)) { try self.addError("tag name mismatch. "); return; }
        try self.nextToken();
        if (self.token.typ != .RAngle) { try self.addError("expected \">\". "); return; }
    }

    fn nextToken(self: *Parser) !void {
        self.token = try self.lexer.nextToken();
    }
    fn addError(self: *Parser, msg: []const u8) !void {
        if (self.aborted) return;
        try self.errors.append(self.alloc, try std.fmt.allocPrint(self.alloc, "line {d}: {s}", .{ self.token.line, msg }));
    }
};

/// 元素形状串（测试用，照搬 python/tests/test_stml.py 的 _shape）。
pub fn shape(alloc: std.mem.Allocator, e: *const Element, esc16: *const fn (std.mem.Allocator, []const u8) anyerror![]const u8) ![]const u8 {
    var out = std.ArrayList(u8).empty;
    try out.appendSlice(alloc, "Elem(");
    try out.appendSlice(alloc, try esc16(alloc, e.tag));
    try out.appendSlice(alloc, try std.fmt.allocPrint(alloc, ", L{d}", .{e.line}));
    if (e.self_closing) try out.appendSlice(alloc, ", /");
    var names = std.ArrayList([]const u8).empty;
    var it = e.attrs.keyIterator();
    while (it.next()) |k| try names.append(alloc, k.*);
    std.mem.sort([]const u8, names.items, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool { return std.mem.order(u8, a, b) == .lt; }
    }.lt);
    for (names.items) |name| {
        try out.appendSlice(alloc, ", @");
        try out.appendSlice(alloc, try esc16(alloc, name));
        const v = e.attrs.get(name).?;
        if (v.len > 0) {
            try out.appendSlice(alloc, "=\"");
            try out.appendSlice(alloc, try esc16(alloc, v));
            try out.append(alloc, '"');
        }
    }
    if (e.text.len > 0) {
        try out.appendSlice(alloc, try std.fmt.allocPrint(alloc, ", T(L{d})=\"", .{e.text_line}));
        try out.appendSlice(alloc, try esc16(alloc, e.text));
        try out.append(alloc, '"');
    }
    if (e.children.items.len > 0) {
        try out.appendSlice(alloc, ", C=[");
        for (e.children.items, 0..) |c, i| {
            if (i > 0) try out.append(alloc, ' ');
            try out.appendSlice(alloc, try shape(alloc, c, esc16));
        }
        try out.append(alloc, ']');
    }
    try out.append(alloc, ')');
    return out.toOwnedSlice(alloc);
}
