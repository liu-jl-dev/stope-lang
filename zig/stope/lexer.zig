//! 词法分析器。照搬 python/stope/lexer.py 的逻辑，对齐 cpp/src/lexer.cpp。
//! 不出异常：出错只往 errors 记一条，然后按最长可行前缀产 token 继续扫。
const std = @import("std");
const tok = @import("token.zig");
const op = @import("opcode.zig");
const Token = tok.Token;
const TokenType = tok.TokenType;

const int64_min: i64 = std.math.minInt(i64);
const int64_max: i64 = std.math.maxInt(i64);

fn isWhite(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\r' or c == '\n' or c == 0x0b or c == 0x0c;
}
fn isDigit(c: u8) bool {
    return c >= '0' and c <= '9';
}
fn isHex(c: u8) bool {
    return isDigit(c) or (c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F');
}
fn isAlpha(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z');
}
fn isIdentBegin(c: u8) bool {
    return isAlpha(c) or c == '_';
}
fn isDigitsFor(c: u8, base: u8) bool {
    return switch (base) {
        2 => c == '0' or c == '1',
        8 => c >= '0' and c <= '7',
        16 => isHex(c),
        else => isDigit(c),
    };
}

const Keyword = struct { name: []const u8, typ: TokenType };
const keywords = [_]Keyword{
    .{ .name = "idiv", .typ = .IDiv },       .{ .name = "not", .typ = .Not },
    .{ .name = "and", .typ = .And },          .{ .name = "or", .typ = .Or },
    .{ .name = "if", .typ = .If },            .{ .name = "elif", .typ = .Elif },
    .{ .name = "else", .typ = .Else },        .{ .name = "let", .typ = .Let },
    .{ .name = "return", .typ = .Return },    .{ .name = "while", .typ = .While },
    .{ .name = "break", .typ = .Break },      .{ .name = "continue", .typ = .Continue },
    .{ .name = "defer", .typ = .Defer },      .{ .name = "null", .typ = .Null },
    .{ .name = "false", .typ = .False_ },     .{ .name = "true", .typ = .True_ },
    .{ .name = "args", .typ = .Args },        .{ .name = "argc", .typ = .Argc },
    .{ .name = "export", .typ = .Export },
};

pub const Lexer = struct {
    alloc: std.mem.Allocator,
    input: []const u8,
    line: i32 = 1,
    errors: std.ArrayList([]const u8),

    custom: ?*op.CustomOpcodeConfig = null,

    pub fn init(alloc: std.mem.Allocator, src: []const u8) Lexer {
        return .{ .alloc = alloc, .input = src, .errors = std.ArrayList([]const u8).empty };
    }

    fn startsWith(self: *Lexer, prefix: []const u8) bool {
        return std.mem.startsWith(u8, self.input, prefix);
    }
    fn addError(self: *Lexer, msg: []const u8) !void {
        try self.errors.append(self.alloc, try std.fmt.allocPrint(self.alloc, "line {d}: {s}", .{ self.line, msg }));
    }

    // ------------------------------------------------------------- 主循环
    pub fn nextToken(self: *Lexer) !Token {
        try self.skipWs();
        var t = Token{ .line = self.line, .typ = .Eof };
        if (self.input.len == 0) return t;
        const c = self.input[0];
        if (isDigit(c) or c == '.') {
            try self.scanNumber(&t);
        } else if (isIdentBegin(c)) {
            try self.scanIdent(&t);
            self.analyzeIdent(&t);
        } else if (c == '\'') {
            try self.scanBinArr(&t);
        } else if (c == '"') {
            try self.scanString(&t);
        } else {
            try self.scanPunct(&t, c);
        }
        return t;
    }

    // ------------------------------------------------------------- 数字
    fn scanNumber(self: *Lexer, t: *Token) !void {
        var lexeme: []const u8 = "";
        if (self.startsWith("0b") or self.startsWith("0B")) {
            t.typ = .Integer;
            lexeme = try self.matchRadixInteger(2);
        } else if (self.startsWith("0o") or self.startsWith("0O")) {
            t.typ = .Integer;
            lexeme = try self.matchRadixInteger(8);
        } else if (self.startsWith("0x") or self.startsWith("0X")) {
            t.typ = .Integer;
            lexeme = try self.matchRadixInteger(16);
        } else if (self.input[0] == '.') {
            t.typ = .Float;
            self.input = self.input[1..]; // 先吞掉小数点本身
            const frac = try self.consumeWhile(isDigitOrUnderscore);
            lexeme = try concat(self.alloc, ".", frac);
            const exp = try self.scanExponent();
            lexeme = try concat(self.alloc, lexeme, exp);
        } else {
            t.typ = .Integer;
            lexeme = try self.consumeWhile(isDigitOrUnderscore);
            if (self.input.len > 0 and self.input[0] == '.') {
                t.typ = .Float;
                self.input = self.input[1..]; // 先吞掉小数点本身
                const frac = try self.consumeWhile(isDigitOrUnderscore);
                lexeme = try concat(self.alloc, lexeme, try concat(self.alloc, ".", frac));
            }
            const exp = try self.scanExponent();
            if (exp.len > 0) t.typ = .Float;
            lexeme = try concat(self.alloc, lexeme, exp);
        }
        t.lexeme = lexeme;
        try self.parseNumber(t);
        try self.getNumberValue(t);
    }

    fn scanExponent(self: *Lexer) ![]const u8 {
        if (self.input.len == 0) return "";
        const c = self.input[0];
        if (c != 'e' and c != 'E') return "";
        var idx: usize = 1;
        if (idx < self.input.len and (self.input[idx] == '+' or self.input[idx] == '-')) idx += 1;
        while (idx < self.input.len and isDigit(self.input[idx])) idx += 1;
        const out = self.input[0..idx];
        self.input = self.input[idx..];
        return out;
    }

    fn matchRadixInteger(self: *Lexer, base: u8) ![]const u8 {
        // 前缀 0b/0o/0x 已确认存在；先取前缀，再尽量取合法数字（含下划线）。
        const prefix = self.input[0..2];
        self.input = self.input[2..];
        var idx: usize = 0;
        while (idx < self.input.len and (self.input[idx] == '_' or isDigitsFor(self.input[idx], base))) idx += 1;
        const digits = self.input[0..idx];
        self.input = self.input[idx..];
        return concat(self.alloc, prefix, digits);
    }

    fn consumeWhile(self: *Lexer, pred: *const fn (u8) bool) ![]const u8 {
        var idx: usize = 0;
        while (idx < self.input.len and pred(self.input[idx])) idx += 1;
        const out = self.input[0..idx];
        self.input = self.input[idx..];
        return out;
    }

    fn parseNumber(self: *Lexer, t: *Token) !void {
        var out = std.ArrayList(u8).empty;
        for (t.lexeme) |c| if (c != '_') try out.append(self.alloc, c);
        t.parsed = try out.toOwnedSlice(self.alloc);
    }

    fn getNumberValue(self: *Lexer, t: *Token) !void {
        if (t.typ == .Integer) {
            var base: u8 = 10;
            var prefix_len: usize = 0;
            if (t.parsed.len >= 2 and t.parsed[0] == '0') {
                switch (t.parsed[1]) {
                    'b', 'B' => { base = 2; prefix_len = 2; },
                    'o', 'O' => { base = 8; prefix_len = 2; },
                    'x', 'X' => { base = 16; prefix_len = 2; },
                    else => {},
                }
            }
            const digits = t.parsed[prefix_len..];
            if (digits.len == 0) {
                try self.addError("invalid integer. ");
                t.typ = .Invalid;
                return;
            }
            for (digits) |c| {
                if (!isDigitsFor(c, base)) {
                    try self.addError("invalid integer. ");
                    t.typ = .Invalid;
                    return;
                }
            }
            const v = std.fmt.parseInt(u64, digits, base) catch {
                try self.addError("invalid integer. ");
                t.typ = .Invalid;
                return;
            };
            if (v > @as(u64, @intCast(int64_max)) and v < @as(u64, @bitCast(int64_min)) or v > std.math.maxInt(u64)) {
                try self.addError("invalid integer. ");
                t.typ = .Invalid;
                return;
            }
            // 允许 -2^63 的绝对值（0x8000000000000000）由一元负号在外层处理；
            // 这里字面量本身超过 int64 max 即报错（对齐 stoll 的 out_of_range）。
            if (v > @as(u64, @intCast(int64_max))) {
                try self.addError("invalid integer. ");
                t.typ = .Invalid;
                return;
            }
            t.value = .{ .integer = @intCast(v) };
        } else if (t.typ == .Float) {
            // 合法性：C++ stod 的 pos 判断。形态：[digits](.[digits])?([eE][+-]?digits+)? 或 .digits...
            if (!validFloat(t.parsed)) {
                try self.addError("invalid float. ");
                t.typ = .Invalid;
                return;
            }
            const v = std.fmt.parseFloat(f64, t.parsed) catch {
                try self.addError("invalid float. ");
                t.typ = .Invalid;
                return;
            };
            if (std.math.isInf(v) or std.math.isNan(v) or (v == 0.0 and hasNonZeroDigit(t.parsed))) {
                try self.addError("invalid float. ");
                t.typ = .Invalid;
                return;
            }
            t.value = .{ .float = v };
        }
    }

    // ------------------------------------------------------------- BinArr / String
    fn scanBinArr(self: *Lexer, t: *Token) !void {
        t.typ = .BinArr;
        self.input = self.input[1..]; // 跳过 '
        const body = try self.consumeWhile(struct {
            fn f(c: u8) bool {
                return c != '\'';
            }
        }.f);
        for (body) |c| { if (c == '\n') self.line += 1; }
        if (self.input.len == 0) {
            try self.addError("unclosed binary array. ");
            t.typ = .Invalid;
            t.lexeme = body;
            return;
        }
        t.lexeme = body;
        self.input = self.input[1..]; // 跳过结尾 '
    }

    fn scanString(self: *Lexer, t: *Token) !void {
        t.typ = .String;
        self.input = self.input[1..]; // 跳过 "
        // 主体：非 " 非 \ 的字符，或 \(任意字符)，到单独的 " 或末尾孤立 \ 停下
        var idx: usize = 0;
        while (idx < self.input.len) {
            const c = self.input[idx];
            if (c == '"') break;
            if (c == '\\') {
                if (idx + 1 >= self.input.len) break;
                idx += 2;
            } else idx += 1;
        }
        const body = self.input[0..idx];
        for (body) |c| { if (c == '\n') self.line += 1; }
        t.lexeme = body;
        self.input = self.input[idx..];
        if (self.input.len == 0 or self.input[0] != '"') {
            try self.addError("unclosed string literal. ");
            t.typ = .Invalid;
            self.input = "";
            return;
        }
        self.input = self.input[1..]; // 跳过结尾 "
        try self.escapeString(t);
    }

    fn escapeString(self: *Lexer, t: *Token) !void {
        var out = std.ArrayList(u8).empty;
        var i: usize = 0;
        while (i < t.lexeme.len) {
            const ch = t.lexeme[i];
            if (ch == '\\') {
                i += 1;
                if (i >= t.lexeme.len) {
                    try self.addError("invalid escape character. ");
                    break;
                }
                if (t.lexeme[i] == 'u') {
                    if (i + 4 >= t.lexeme.len or !allHex(t.lexeme[i + 1 .. i + 5])) {
                        try self.addError("invalid escape character. ");
                        break;
                    }
                    const cp = try std.fmt.parseInt(u21, t.lexeme[i + 1 .. i + 5], 16);
                    var buf: [4]u8 = undefined;
                    const n = std.unicode.utf8Encode(cp, &buf) catch {
                        try self.addError("invalid escape character. ");
                        break;
                    };
                    try out.appendSlice(self.alloc, buf[0..n]);
                    i += 5;
                    continue;
                }
                const mapped: ?u8 = switch (t.lexeme[i]) {
                    '\\' => '\\', '\'' => '\'', '"' => '"',
                    'b' => 0x08, 'r' => '\r', 't' => '\t',
                    'v' => 0x0b, 'n' => '\n', 'f' => 0x0c,
                    else => null,
                };
                if (mapped) |m| {
                    try out.append(self.alloc, m);
                    i += 1;
                } else {
                    try self.addError("invalid escape character. ");
                    break;
                }
            } else {
                try out.append(self.alloc, ch);
                i += 1;
            }
        }
        t.parsed = try out.toOwnedSlice(self.alloc);
    }

    // ------------------------------------------------------------- 标识符 / 标点
    fn scanIdent(self: *Lexer, t: *Token) !void {
        t.typ = .Ident;
        var parsed = std.ArrayList(u8).empty;
        var src = std.ArrayList(u8).empty;
        const head = try self.consumeWhile(isIdentChar);
        try parsed.appendSlice(self.alloc, head);
        try src.appendSlice(self.alloc, head);
        while (true) {
            const skipped = try self.skipWsReturning();
            try src.appendSlice(self.alloc, skipped);
            if (self.input.len == 0 or self.input[0] != ':') break;
            try src.append(self.alloc, ':');
            try parsed.append(self.alloc, ':');
            self.input = self.input[1..];
            const skipped2 = try self.skipWsReturning();
            try src.appendSlice(self.alloc, skipped2);
            // 冒号后的段必须以字母/下划线开头（_RE_IDENT_HEAD），不能是数字。
            if (self.input.len == 0 or !isIdentBegin(self.input[0])) {
                try self.addError("unclosed identifier. ");
                t.typ = .Invalid;
                break;
            }
            const seg = try self.consumeWhile(isIdentChar);
            try src.appendSlice(self.alloc, seg);
            try parsed.appendSlice(self.alloc, seg);
        }
        t.lexeme = try src.toOwnedSlice(self.alloc);
        t.parsed = try parsed.toOwnedSlice(self.alloc);
    }

    fn analyzeIdent(self: *Lexer, t: *Token) void {
        if (t.typ == .Invalid) return;
        for (keywords) |kw| {
            if (std.mem.eql(u8, t.parsed, kw.name)) {
                t.typ = kw.typ;
                return;
            }
        }
        // 自定义指令由宿主登记的 config 决定（关键字优先）。
        if (self.custom) |cfg| {
            if (cfg.opcodes.contains(t.parsed)) {
                t.typ = .Custom;
                return;
            }
        }
        t.typ = .Ident;
    }

    fn scanPunct(self: *Lexer, t: *Token, c: u8) !void {
        if (self.input.len >= 2) {
            const two = self.input[0..2];
            const typ: ?TokenType = if (std.mem.eql(u8, two, "==")) .EQ else if (std.mem.eql(u8, two, "!=")) .NE else if (std.mem.eql(u8, two, "<=")) .LE else if (std.mem.eql(u8, two, ">=")) .GE else if (std.mem.eql(u8, two, "&&")) .And else if (std.mem.eql(u8, two, "||")) .Or else null;
            if (typ) |tt| {
                t.typ = tt;
                t.lexeme = two;
                self.input = self.input[2..];
                return;
            }
        }
        const one: ?TokenType = switch (c) {
            ',' => .Comma, ';' => .Semi, '(' => .LParen, ')' => .RParen,
            '[' => .LBrack, ']' => .RBrack, '{' => .LBrace, '}' => .RBrace,
            '+' => .Add, '-' => .Sub, '*' => .Mul, '/' => .Div,
            '%' => .Mod, '^' => .Pow, '=' => .Assign, '!' => .Not,
            '<' => .LT, '>' => .GT, else => null,
        };
        t.typ = one orelse .Invalid;
        t.lexeme = self.input[0..1];
        self.input = self.input[1..];
        if (one == null) try self.addError("unknown token. ");
    }

    // ------------------------------------------------------------- 空白 / 注释
    fn skipWs(self: *Lexer) !void {
        while (self.input.len > 0) {
            const c = self.input[0];
            if (isWhite(c)) {
                if (c == '\n') self.line += 1;
                self.input = self.input[1..];
            } else if (self.startsWith("//")) {
                const pos = std.mem.indexOfScalar(u8, self.input, '\n');
                if (pos == null) {
                    self.input = "";
                } else {
                    self.input = self.input[pos.? + 1 ..];
                    self.line += 1;
                }
            } else if (self.startsWith("/*")) {
                try self.skipMultilineComment();
            } else break;
        }
    }

    fn skipWsReturning(self: *Lexer) ![]const u8 {
        const before = self.input;
        try self.skipWs();
        return before[0 .. before.len - self.input.len];
    }

    fn skipMultilineComment(self: *Lexer) !void {
        self.input = self.input[2..]; // 跳过 /*
        while (self.input.len > 0) {
            if (self.startsWith("*/")) {
                self.input = self.input[2..];
                break;
            }
            if (self.input[0] == '\n') self.line += 1;
            self.input = self.input[1..];
        }
    }
};

// ------------------------------------------------------------------ 工具函数
fn isDigitOrUnderscore(c: u8) bool {
    return isDigit(c) or c == '_';
}
fn isIdentChar(c: u8) bool {
    return isAlpha(c) or isDigit(c) or c == '_';
}
fn concat(alloc: std.mem.Allocator, a: []const u8, b: []const u8) ![]const u8 {
    return std.mem.concat(alloc, u8, &.{ a, b });
}
fn allHex(s: []const u8) bool {
    for (s) |c| if (!isHex(c)) return false;
    return true;
}
fn hasNonZeroDigit(s: []const u8) bool {
    for (s) |c| if (c >= '1' and c <= '9') return true;
    return false;
}
fn validFloat(s: []const u8) bool {
    // (?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+)(?:[eE][+-]?[0-9]+)? 全匹配
    if (s.len == 0) return false;
    var i: usize = 0;
    var int_digits: usize = 0;
    while (i < s.len and isDigit(s[i])) : (i += 1) int_digits += 1;
    var frac_digits: usize = 0;
    if (i < s.len and s[i] == '.') {
        i += 1;
        while (i < s.len and isDigit(s[i])) : (i += 1) frac_digits += 1;
    }
    if (int_digits == 0 and frac_digits == 0) return false;
    if (int_digits == 0 and s[0] != '.') return false;
    if (i < s.len and (s[i] == 'e' or s[i] == 'E')) {
        i += 1;
        if (i < s.len and (s[i] == '+' or s[i] == '-')) i += 1;
        const start = i;
        while (i < s.len and isDigit(s[i])) : (i += 1) {}
        if (i == start) return false;
    }
    return i == s.len;
}
