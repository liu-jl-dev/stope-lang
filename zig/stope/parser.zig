//! 语法分析器（Pratt）—— 照搬 python/stope/parser.py，对齐 cpp/src/parser.cpp。
//! 深度走函数参数；超限报一条并置 aborted；分隔符缺失只报错不推进（let/return 例外）。
const std = @import("std");
const tok = @import("token.zig");
const ast = @import("ast.zig");
const binarr = @import("binarr.zig");
const expr_optim = @import("expr_optim.zig");
const Lexer = @import("lexer.zig").Lexer;
const TokenType = tok.TokenType;
const Token = tok.Token;

pub const kDefaultMaxDepth = 256;

const Precedence = struct {
    const lowest: u8 = 0;
    const or_: u8 = 1;
    const and_: u8 = 2;
    const equals: u8 = 3;
    const less_greater: u8 = 4;
    const add_sub: u8 = 5;
    const mul_div: u8 = 6;
    const pow: u8 = 7;
    const prefix: u8 = 8;
    const paren: u8 = 9;
};

fn binopPrec(t: TokenType) u8 {
    return switch (t) {
        .Or => Precedence.or_,
        .And => Precedence.and_,
        .EQ, .NE => Precedence.equals,
        .LT, .LE, .GT, .GE => Precedence.less_greater,
        .Add, .Sub => Precedence.add_sub,
        .Mul, .Div, .IDiv, .Mod => Precedence.mul_div,
        .Pow => Precedence.pow,
        .LParen, .LBrack => Precedence.paren,
        else => Precedence.lowest,
    };
}

pub const Parser = struct {
    alloc: std.mem.Allocator,
    lexer: *Lexer,
    errors: std.ArrayList([]const u8),
    aborted: bool = false,
    const_folding: bool = true, // 首版不做折叠：golden 的 SHAPE 依赖 FOLD 列，后续接 expr_optim
    max_depth: i32 = kDefaultMaxDepth,
    cur: Token = .{},
    peek: Token = .{},

    pub fn init(alloc: std.mem.Allocator, lx: *Lexer) !Parser {
        var p = Parser{
            .alloc = alloc,
            .lexer = lx,
            .errors = std.ArrayList([]const u8).empty,
        };
        try p.nextToken();
        try p.nextToken();
        return p;
    }

    fn nextToken(self: *Parser) anyerror!void {
        self.cur = self.peek;
        self.peek = try self.lexer.nextToken();
    }

    fn optimize(self: *Parser, e: *Expr) anyerror!*Expr {
        if (!self.const_folding) return e;
        return (try expr_optim.optimize(self.alloc, e)).?;
    }

    fn addError(self: *Parser, line: i32, msg: []const u8) anyerror!void {
        if (self.aborted) return;
        try self.errors.append(self.alloc, try std.fmt.allocPrint(self.alloc, "line {d}: {s}", .{ line, msg }));
    }

    fn abortTooDeep(self: *Parser, line: i32) anyerror!void {
        try self.addError(line, try std.fmt.allocPrint(self.alloc, "nesting too deep (max {d}). ", .{self.max_depth}));
        self.aborted = true;
    }

    fn newStmt(self: *Parser, line: i32, data: ast.Stmt.Data) anyerror!*Stmt {
        const s = try self.alloc.create(ast.Stmt);
        s.* = .{ .line = line, .data = data };
        return s;
    }
    fn newExpr(self: *Parser, line: i32, data: ast.Expr.Data) anyerror!*Expr {
        const e = try self.alloc.create(ast.Expr);
        e.* = .{ .line = line, .data = data };
        return e;
    }
    fn newProg(self: *Parser) anyerror!*ast.Prog {
        const p = try self.alloc.create(ast.Prog);
        p.* = ast.Prog.init(self.alloc);
        return p;
    }

    // ------------------------------------------------------------------ prog
    pub fn parseProgram(self: *Parser, prog: *ast.Prog) anyerror!void {
        try self.parseProg(prog, true, 1);
    }

    fn parseProg(self: *Parser, prog: *ast.Prog, is_top: bool, depth: i32) anyerror!void {
        if (self.aborted) return;
        while (!self.aborted and self.cur.typ != .Eof) {
            if (self.cur.typ == .RBrace) {
                if (!is_top) break;
                try self.addError(self.cur.line, "unexpected \"}\" at top level. ");
                try self.nextToken();
                continue;
            }
            if (self.cur.typ == .Semi) {
                try self.nextToken();
                continue;
            }
            const stmt = try self.parseStmtDispatch(depth);
            if (stmt == null) break;
            try prog.stmts.append(self.alloc, stmt.?);
        }
    }

    // ------------------------------------------------------------------ 语句
    fn parseLetStmt(self: *Parser, depth: i32) anyerror!*Stmt {
        const line = self.cur.line;
        var idents = std.ArrayList([]const u8).empty;
        var has_assign = false;
        var expr: ?*Expr = null;
        try self.nextToken(); // 跳过 let
        if (self.cur.typ != .Ident) {
            try self.addError(self.cur.line, "expected identifier after \"let\". ");
            try self.nextToken();
            return self.newStmt(line, .{ .let_stmt = .{ .idents = try idents.toOwnedSlice(self.alloc), .has_assign = false, .expr = null } });
        }
        try idents.append(self.alloc, self.cur.parsed);
        try self.nextToken();
        if (self.cur.typ == .Semi) {
            try self.nextToken();
        } else if (self.cur.typ == .Comma) {
            while (true) {
                if (self.cur.typ == .Comma and self.peek.typ == .Ident) {
                    try idents.append(self.alloc, self.peek.parsed);
                    try self.nextToken();
                    try self.nextToken();
                } else if (self.cur.typ == .Semi) {
                    try self.nextToken();
                    break;
                } else if (self.cur.typ == .Eof or self.cur.typ == .RBrace) {
                    try self.addError(self.cur.line, "expected \";\" in let statement. ");
                    break;
                } else {
                    try self.addError(self.cur.line, "failed to parse let statement with multiple identifiers. ");
                    try self.nextToken();
                }
            }
        } else if (self.cur.typ == .Assign) {
            has_assign = true;
            try self.nextToken();
            expr = try self.parseExpr(Precedence.lowest, depth);
            try self.nextToken();
        } else {
            try self.addError(self.cur.line, "unexpected token in let statement. ");
            try self.nextToken();
        }
        return self.newStmt(line, .{ .let_stmt = .{ .idents = try idents.toOwnedSlice(self.alloc), .has_assign = has_assign, .expr = expr } });
    }

    fn parseExportStmt(self: *Parser, _: i32) anyerror!*Stmt {
        const line = self.cur.line;
        var idents = std.ArrayList([]const u8).empty;
        try self.nextToken();
        if (self.cur.typ != .Ident) {
            try self.addError(self.cur.line, "expected identifier after \"export\". ");
            try self.nextToken();
            return self.newStmt(line, .{ .export_stmt = try idents.toOwnedSlice(self.alloc) });
        }
        try idents.append(self.alloc, self.cur.parsed);
        try self.nextToken();
        if (self.cur.typ == .Semi) {
            try self.nextToken();
        } else if (self.cur.typ == .Comma) {
            while (true) {
                if (self.cur.typ == .Comma and self.peek.typ == .Ident) {
                    try idents.append(self.alloc, self.peek.parsed);
                    try self.nextToken();
                    try self.nextToken();
                } else if (self.cur.typ == .Semi) {
                    try self.nextToken();
                    break;
                } else if (self.cur.typ == .Eof or self.cur.typ == .RBrace) {
                    try self.addError(self.cur.line, "expected \";\" in export statement. ");
                    break;
                } else {
                    try self.addError(self.cur.line, "failed to parse export statement with multiple identifiers. ");
                    try self.nextToken();
                }
            }
        } else {
            try self.addError(self.cur.line, "unexpected token in export statement. ");
            try self.nextToken();
        }
        return self.newStmt(line, .{ .export_stmt = try idents.toOwnedSlice(self.alloc) });
    }

    fn parseReturnStmt(self: *Parser, depth: i32) anyerror!*Stmt {
        const line = self.cur.line;
        var exprs = std.ArrayList(*Expr).empty;
        try self.nextToken();
        if (self.cur.typ == .Semi) {
            try self.nextToken();
            return self.newStmt(line, .{ .return_stmt = try exprs.toOwnedSlice(self.alloc) });
        }
        if (self.cur.typ == .Eof or self.cur.typ == .RBrace) {
            try self.addError(self.cur.line, "expected \";\" in return statement. ");
            return self.newStmt(line, .{ .return_stmt = try exprs.toOwnedSlice(self.alloc) });
        }
        const e0 = try self.parseExpr(Precedence.lowest, depth);
        if (e0) |e| try exprs.append(self.alloc, e);
        try self.nextToken();
        while (true) {
            if (self.cur.typ == .Semi) {
                try self.nextToken();
                break;
            } else if (self.cur.typ == .Comma) {
                try self.nextToken();
                const e = try self.parseExpr(Precedence.lowest, depth);
                if (e) |v| try exprs.append(self.alloc, v);
                try self.nextToken();
            } else {
                try self.addError(self.cur.line, "expected \";\" or \",\" in return statement. ");
                try self.nextToken();
                break;
            }
        }
        return self.newStmt(line, .{ .return_stmt = try exprs.toOwnedSlice(self.alloc) });
    }

    fn parseBlockStmt(self: *Parser, depth: i32) anyerror!?*Stmt {
        if (self.aborted) return null;
        const line = self.cur.line;
        try self.nextToken();
        const p = try self.newProg();
        try self.parseProg(p, false, depth + 1);
        if (self.cur.typ != .RBrace) try self.addError(self.cur.line, "expected \"}\" at end of block statement. ");
        try self.nextToken();
        return self.newStmt(line, .{ .block_stmt = p });
    }

    fn parseIfStmt(self: *Parser, depth: i32) anyerror!?*Stmt {
        if (self.aborted) return null;
        const line = self.cur.line;
        const cond = try self.parseExprAfterKeyword();
        if (self.cur.typ != .LBrace) {
            try self.addError(self.cur.line, "expected \"{\" in if statement. ");
            return self.newStmt(line, .{ .if_stmt = .{ .cond = cond, .first = try self.newProg(), .elifs = &.{}, .else_prog = null } });
        }
        try self.nextToken();
        const first = try self.newProg();
        try self.parseProg(first, false, depth + 1);
        if (self.cur.typ != .RBrace) {
            try self.addError(self.cur.line, "expected \"}\" in if statement. ");
            return self.newStmt(line, .{ .if_stmt = .{ .cond = cond, .first = first, .elifs = &.{}, .else_prog = null } });
        }
        try self.nextToken();
        var elifs = std.ArrayList(ast.Elif).empty;
        var else_prog: ?*ast.Prog = null;
        while (self.cur.typ == .Elif) {
            try self.nextToken();
            const ec = try self.parseExpr(Precedence.lowest, depth);
            try self.nextToken();
            if (self.cur.typ != .LBrace) {
                try self.addError(self.cur.line, "expected \"{\" of elif. ");
                break;
            }
            try self.nextToken();
            const ep = try self.newProg();
            try self.parseProg(ep, false, depth + 1);
            if (self.cur.typ != .RBrace) {
                try self.addError(self.cur.line, "expected \"}\" of elif. ");
                break;
            }
            try self.nextToken();
            try elifs.append(self.alloc, .{ .cond = ec, .prog = ep });
        }
        if (self.cur.typ == .Else) {
            try self.nextToken();
            if (self.cur.typ != .LBrace) {
                try self.addError(self.cur.line, "expected \"{\" after else. ");
            } else {
                try self.nextToken();
                const ep = try self.newProg();
                try self.parseProg(ep, false, depth + 1);
                if (self.cur.typ != .RBrace) {
                    try self.addError(self.cur.line, "expected \"}\" in if statement. ");
                }
                try self.nextToken();
                else_prog = ep;
            }
        }
        return self.newStmt(line, .{ .if_stmt = .{ .cond = cond, .first = first, .elifs = try elifs.toOwnedSlice(self.alloc), .else_prog = else_prog } });
    }

    /// if/while 的关键字后：跳过关键字 → 解析条件 → next_token 到达 {
    fn parseExprAfterKeyword(self: *Parser) anyerror!?*Expr {
        try self.nextToken();
        const e = try self.parseExpr(Precedence.lowest, 2);
        try self.nextToken();
        return e;
    }

    fn parseWhileStmt(self: *Parser, depth: i32) anyerror!?*Stmt {
        if (self.aborted) return null;
        const line = self.cur.line;
        try self.nextToken();
        var cond: ?*Expr = null;
        if (self.cur.typ != .LBrace) {
            cond = try self.parseExpr(Precedence.lowest, depth);
            try self.nextToken();
        }
        if (self.cur.typ != .LBrace) {
            try self.addError(self.cur.line, "expected \"{\" in while statement. ");
            return self.newStmt(line, .{ .while_stmt = .{ .cond = cond, .prog = try self.newProg() } });
        }
        try self.nextToken();
        const p = try self.newProg();
        try self.parseProg(p, false, depth + 1);
        if (self.cur.typ != .RBrace) try self.addError(self.cur.line, "expected \"}\" at end of while statement. ");
        try self.nextToken();
        return self.newStmt(line, .{ .while_stmt = .{ .cond = cond, .prog = p } });
    }

    fn parseBreakStmt(self: *Parser) anyerror!*Stmt {
        const line = self.cur.line;
        try self.nextToken();
        if (self.cur.typ != .Semi) {
            try self.addError(self.cur.line, "expected \";\" in break statement. ");
        } else try self.nextToken();
        return self.newStmt(line, .{ .break_stmt = {} });
    }

    fn parseContinueStmt(self: *Parser) anyerror!*Stmt {
        const line = self.cur.line;
        try self.nextToken();
        if (self.cur.typ != .Semi) {
            try self.addError(self.cur.line, "expected \";\" in continue statement. ");
        } else try self.nextToken();
        return self.newStmt(line, .{ .continue_stmt = {} });
    }

    fn parseDeferStmt(self: *Parser, depth: i32) anyerror!?*Stmt {
        if (self.aborted) return null;
        const line = self.cur.line;
        try self.nextToken();
        if (self.cur.typ == .Semi or self.cur.typ == .RBrace or self.cur.typ == .Eof) {
            try self.addError(self.cur.line, "expected statement after \"defer\". ");
            return self.newStmt(line, .{ .defer_stmt = null });
        }
        const inner = try self.parseStmtDispatch(depth + 1);
        return self.newStmt(line, .{ .defer_stmt = inner });
    }

    fn parseStmtDispatch(self: *Parser, depth: i32) anyerror!?*Stmt {
        if (self.aborted) return null;
        return switch (self.cur.typ) {
            .Let => self.parseLetStmt(depth),
            .Export => self.parseExportStmt(depth),
            .Return => self.parseReturnStmt(depth),
            .LBrace => self.parseBlockStmt(depth),
            .If => self.parseIfStmt(depth),
            .While => self.parseWhileStmt(depth),
            .Break => self.parseBreakStmt(),
            .Continue => self.parseContinueStmt(),
            .Defer => self.parseDeferStmt(depth),
            else => self.parseExprOrAssignStmt(depth),
        };
    }

    fn parseExprOrAssignStmt(self: *Parser, depth: i32) anyerror!?*Stmt {
        const left_opt = try self.parseExpr(Precedence.lowest, depth);
        if (left_opt == null) return null;
        const left = left_opt.?;
        try self.nextToken();
        if (self.cur.typ == .Semi) {
            try self.nextToken();
            return self.newStmt(left.line, .{ .expr_stmt = left });
        } else if (self.cur.typ == .Assign) {
            try self.nextToken();
            const right = try self.parseExpr(Precedence.lowest, depth);
            try self.nextToken();
            if (self.cur.typ != .Semi) try self.addError(self.cur.line, "expected \";\" at end of assign statement. ");
            try self.nextToken();
            if (right) |r| return self.newStmt(left.line, .{ .assign_stmt = .{ .left = left, .right = r } });
            return null;
        }
        try self.addError(self.cur.line, "expected \";\" or \"=\". ");
        return self.newStmt(left.line, .{ .expr_stmt = left });
    }

    // ------------------------------------------------------------------ 表达式
    fn parseExpr(self: *Parser, precedence: u8, depth: i32) anyerror!?*Expr {
        if (self.aborted) return null;
        if (self.max_depth > 0 and depth > self.max_depth) {
            try self.abortTooDeep(self.cur.line);
            return null;
        }
        const left_opt = try self.parsePrefix(depth);
        if (left_opt == null) return null;
        var left = left_opt.?;
        while (!self.aborted and self.peek.typ != .Semi and precedence < binopPrec(self.peek.typ)) {
            const is_infix = isInfix(self.peek.typ);
            if (!is_infix) {
                try self.addError(self.peek.line, "no infix parse function for token type. ");
                return left;
            }
            try self.nextToken();
            const next = try self.parseInfix(left, depth);
            if (next == null) return null;
            left = next.?;
        }
        return left;
    }

    fn parsePrefix(self: *Parser, depth: i32) anyerror!?*Expr {
        const line = self.cur.line;
        const t = self.cur.typ;
        switch (t) {
            .Ident => return self.newExpr(line, .{ .ident_expr = self.cur.parsed }),
            .Null => return self.newExpr(line, .null_expr),
            .False_, .True_ => return self.newExpr(line, .{ .bool_expr = t == .True_ }),
            .Integer => {
                const v: i64 = switch (self.cur.value) { .integer => |x| x, else => 0 };
                return self.newExpr(line, .{ .int_expr = v });
            },
            .Float => {
                const v: f64 = switch (self.cur.value) { .float => |x| x, else => 0 };
                return self.newExpr(line, .{ .float_expr = v });
            },
            .String => return self.newExpr(line, .{ .string_expr = self.cur.parsed }),
            .BinArr => {
                const bytes = binarr.parseBinaryArray(self.alloc, self.cur.lexeme) catch {
                    try self.addError(line, "invalid binary array. ");
                    return self.newExpr(line, .{ .binarr_expr = &.{} });
                };
                return self.newExpr(line, .{ .binarr_expr = bytes });
            },
            .Argc => return self.newExpr(line, .argc_expr),
            .Sub, .Not => {
                const op = t;
                try self.nextToken();
                const inner = try self.parseExpr(Precedence.prefix, depth + 1);
                if (inner == null) return null;
                const node = try self.newExpr(line, .{ .unary_op = .{ .op = op, .expr = inner.? } });
                return self.optimize(node);
            },
            .LParen => {
                try self.nextToken();
                const e = try self.parseExpr(Precedence.lowest, depth + 1);
                try self.nextToken();
                if (self.cur.typ != .RParen) try self.addError(self.cur.line, "expected \")\". ");
                return e;
            },
            .Custom => return self.parseCustomExpr(line, depth),
            .Args => return self.parseArgsExpr(line, depth),
            else => {
                try self.addError(line, "no prefix parse function for token type. ");
                return self.newExpr(line, .err);
            },
        }
    }

    fn parseCustomExpr(self: *Parser, line: i32, depth: i32) anyerror!*Expr {
        const name = self.cur.parsed;
        var args = std.ArrayList(*Expr).empty;
        try self.nextToken();
        if (self.cur.typ != .LParen) {
            try self.addError(self.cur.line, "expected \"(\" after custom opcode. ");
            try self.nextToken();
            return self.newExpr(line, .{ .custom = .{ .name = name, .args = try args.toOwnedSlice(self.alloc) } });
        }
        try self.nextToken();
        if (self.cur.typ == .RParen) {
            // 空参数表
        } else {
            const e0 = try self.parseExpr(Precedence.lowest, depth + 1);
            if (e0) |e| try args.append(self.alloc, e);
            while (self.peek.typ == .Comma) {
                try self.nextToken();
                try self.nextToken();
                const e = try self.parseExpr(Precedence.lowest, depth + 1);
                if (e) |v| try args.append(self.alloc, v);
            }
            if (self.peek.typ != .RParen) try self.addError(self.cur.line, "expected \")\". ");
            try self.nextToken();
        }
        return self.newExpr(line, .{ .custom = .{ .name = name, .args = try args.toOwnedSlice(self.alloc) } });
    }

    fn parseArgsExpr(self: *Parser, line: i32, depth: i32) anyerror!*Expr {
        if (self.peek.typ != .LBrack) {
            try self.addError(self.peek.line, "expected \"[\" after \"args\". ");
            return self.newExpr(line, .{ .args_expr = null });
        }
        try self.nextToken();
        try self.nextToken();
        const key = try self.parseExpr(Precedence.lowest, depth + 1);
        try self.nextToken();
        if (self.cur.typ != .RBrack) try self.addError(self.cur.line, "expected \"]\". ");
        return self.newExpr(line, .{ .args_expr = key });
    }

    fn parseInfix(self: *Parser, left: *Expr, depth: i32) anyerror!?*Expr {
        const op = self.cur.typ;
        if (op == .LParen) return self.parseCallExpr(left, depth);
        if (op == .LBrack) return self.parseAtExpr(left, depth);
        const line = left.line;
        var prec = binopPrec(op);
        if (op == .Pow) prec -= 1; // ^ 右结合
        try self.nextToken();
        const right = try self.parseExpr(prec, depth + 1);
        if (right == null) return null;
        const node = try self.newExpr(line, .{ .binary_op = .{ .op = op, .left = left, .right = right.? } });
        return self.optimize(node);
    }

    fn parseCallExpr(self: *Parser, callee: *Expr, depth: i32) anyerror!*Expr {
        var args = std.ArrayList(*Expr).empty;
        if (self.peek.typ != .RParen) {
            try self.nextToken();
            const e0 = try self.parseExpr(Precedence.lowest, depth + 1);
            if (e0) |e| try args.append(self.alloc, e);
            while (self.peek.typ == .Comma) {
                try self.nextToken();
                try self.nextToken();
                const e = try self.parseExpr(Precedence.lowest, depth + 1);
                if (e) |v| try args.append(self.alloc, v);
            }
        }
        if (self.peek.typ == .RParen) {
            try self.nextToken();
        } else try self.addError(self.peek.line, "expected \")\". ");
        return self.newExpr(callee.line, .{ .call = .{ .callee = callee, .args = try args.toOwnedSlice(self.alloc) } });
    }

    fn parseAtExpr(self: *Parser, container: *Expr, depth: i32) anyerror!*Expr {
        var keys = std.ArrayList(*Expr).empty;
        if (self.peek.typ != .RBrack) {
            try self.nextToken();
            const e0 = try self.parseExpr(Precedence.lowest, depth + 1);
            if (e0) |e| try keys.append(self.alloc, e);
            while (self.peek.typ == .Comma) {
                try self.nextToken();
                try self.nextToken();
                const e = try self.parseExpr(Precedence.lowest, depth + 1);
                if (e) |v| try keys.append(self.alloc, v);
            }
        }
        if (self.peek.typ == .RBrack) {
            try self.nextToken();
        } else try self.addError(self.peek.line, "expected \"]\". ");
        return self.newExpr(container.line, .{ .at = .{ .container = container, .keys = try keys.toOwnedSlice(self.alloc) } });
    }
};

const Stmt = ast.Stmt;
const Expr = ast.Expr;

fn isInfix(t: TokenType) bool {
    return switch (t) {
        .Or, .And, .EQ, .NE, .LT, .LE, .GT, .GE, .Add, .Sub, .Mul, .Div, .IDiv, .Mod, .Pow, .LParen, .LBrack => true,
        else => false,
    };
}
