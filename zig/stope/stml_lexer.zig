//! STML 词法器：四态状态机（Xml/Text/Nevext/Stope）—— 照搬 python/stope/stml_lexer.py。
const std = @import("std");
const stml = @import("stml.zig");
const Token = stml.Token;
const TokenType = stml.TokenType;
const LexerState = stml.LexerState;

fn isWhite(c: u8) bool {
    return c == ' ' or c == '\t' or c == 0x0b or c == 0x0c or c == '\r' or c == '\n';
}
fn isAlpha(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z');
}
fn isDigit(c: u8) bool {
    return c >= '0' and c <= '9';
}
fn isWordBegin(c: u8) bool {
    return isAlpha(c) or c == '_' or c == ':';
}
fn isWordChar(c: u8) bool {
    return isWordBegin(c) or isDigit(c) or c == '-';
}

pub fn hasLexeme(t: TokenType) bool {
    return switch (t) { .Word, .String, .Text, .NevextSrc, .StopeSrc => true, else => false };
}

fn trimTrailingWs(s: []const u8) []const u8 {
    var n = s.len;
    while (n > 0 and isWhite(s[n - 1])) n -= 1;
    return s[0..n];
}

pub const Lexer = struct {
    alloc: std.mem.Allocator,
    state: LexerState = .Xml,
    src: []const u8,
    line: i32 = 1,
    errors: std.ArrayList([]const u8),

    pub fn init(alloc: std.mem.Allocator, source: []const u8, state: LexerState) Lexer {
        return .{ .alloc = alloc, .src = source, .state = state, .errors = std.ArrayList([]const u8).empty };
    }
    fn addError(self: *Lexer, line: i32, msg: []const u8) !void {
        try self.errors.append(self.alloc, try std.fmt.allocPrint(self.alloc, "line {d}: {s}", .{ line, msg }));
    }
    fn startsWith(self: *Lexer, p: []const u8) bool {
        return std.mem.startsWith(u8, self.src, p);
    }

    pub fn nextToken(self: *Lexer) !Token {
        var t = Token{};
        try self.skipWs();
        t.line = self.line;
        if (self.src.len == 0) {
            t.typ = .Eof;
        } else switch (self.state) {
            .Xml => {
                if (self.startsWith("</")) {
                    t.typ = .CLAngle; t.lexeme = "</"; self.src = self.src[2..];
                } else if (self.startsWith("/>")) {
                    t.typ = .CRAngle; t.lexeme = "/>"; self.src = self.src[2..];
                } else if (self.src[0] == '<') {
                    t.typ = .LAngle; t.lexeme = "<"; self.src = self.src[1..];
                } else if (self.src[0] == '>') {
                    t.typ = .RAngle; t.lexeme = ">"; self.src = self.src[1..];
                } else if (self.src[0] == '=') {
                    t.typ = .EQ; t.lexeme = "="; self.src = self.src[1..];
                } else if (self.src[0] == '"' or self.src[0] == '\'') {
                    try self.scanString(&t);
                } else if (isWordBegin(self.src[0])) {
                    t.typ = .Word; t.lexeme = try self.scanWord();
                } else {
                    try self.addError(self.line, "unexpected character. ");
                    t.typ = .Invalid; t.lexeme = ""; self.src = self.src[1..];
                }
            },
            .Text => {
                t.typ = .Text; t.lexeme = try self.scanContent(.Text); self.state = .Xml;
            },
            .Nevext => {
                t.typ = .NevextSrc; t.lexeme = try self.scanContent(.Nevext); self.state = .Xml;
            },
            .Stope => {
                t.typ = .StopeSrc; t.lexeme = try self.scanContent(.Stope); self.state = .Xml;
            },
        }
        return t;
    }

    // Xml 状态
    fn scanString(self: *Lexer, t: *Token) !void {
        t.typ = .String;
        const quote = self.src[0];
        self.src = self.src[1..];
        var n: usize = 0;
        while (true) {
            if (n >= self.src.len) {
                try self.addError(self.line, "unclosed string literal");
                self.src = "";
                t.typ = .Invalid;
                return;
            }
            if (self.src[n] == quote) {
                t.lexeme = self.src[0..n];
                self.src = self.src[n + 1 ..];
                return;
            }
            if (self.src[n] == '\n') self.line += 1;
            n += 1;
        }
    }

    fn scanWord(self: *Lexer) ![]const u8 {
        var end: usize = 1;
        while (end < self.src.len and isWordChar(self.src[end])) end += 1;
        const s = self.src[0..end];
        self.src = self.src[end..];
        return s;
    }

    // 内容三态
    fn scanContent(self: *Lexer, mode: LexerState) ![]const u8 {
        const begin = self.src;
        while (self.src.len > 0) {
            if (self.startsWith("</")) break;
            if (mode != .Text) {
                const c = self.src[0];
                if (c == '\'' or c == '"') {
                    try self.scanCodeStr(c, mode == .Nevext or c == '"');
                    continue;
                }
                if (self.startsWith("//")) { try self.skipSingleComment(); continue; }
                if (self.startsWith("/*")) { try self.skipMultiComment(); continue; }
            }
            if (self.src[0] == '\n') self.line += 1;
            self.src = self.src[1..];
        }
        return trimTrailingWs(begin[0 .. begin.len - self.src.len]);
    }

    fn scanCodeStr(self: *Lexer, quote: u8, escapes: bool) !void {
        const begin_line = self.line;
        self.src = self.src[1..];
        while (true) {
            if (self.src.len == 0) {
                try self.addError(begin_line, "unclosed string literal. ");
                return;
            }
            const c = self.src[0];
            self.src = self.src[1..];
            if (escapes and c == '\\') {
                if (self.src.len == 0) {
                    try self.addError(begin_line, "unclosed string literal. ");
                    return;
                }
                if (self.src[0] == '\n') self.line += 1;
                self.src = self.src[1..];
            } else if (c == quote) {
                return;
            } else if (c == '\n') self.line += 1;
        }
    }

    fn skipSingleComment(self: *Lexer) !void {
        self.src = self.src[2..];
        while (self.src.len > 0) {
            const c = self.src[0];
            self.src = self.src[1..];
            if (c == '\n') { self.line += 1; return; }
        }
    }

    fn skipMultiComment(self: *Lexer) !void {
        self.src = self.src[2..];
        while (self.src.len > 0) {
            if (self.startsWith("*/")) { self.src = self.src[2..]; return; }
            if (self.src[0] == '\n') self.line += 1;
            self.src = self.src[1..];
        }
    }

    // 空白与注释
    fn skipWs(self: *Lexer) !void {
        while (self.src.len > 0) {
            const c = self.src[0];
            if (isWhite(c)) {
                if (c == '\n') self.line += 1;
                self.src = self.src[1..];
            } else if (self.state == .Xml and self.startsWith("<!--")) {
                try self.skipXmlComment();
            } else break;
        }
    }

    fn skipXmlComment(self: *Lexer) !void {
        self.src = self.src[4..];
        while (self.src.len > 0) {
            if (self.startsWith("-->")) { self.src = self.src[3..]; return; }
            if (self.src[0] == '\n') self.line += 1;
            self.src = self.src[1..];
        }
    }
};
