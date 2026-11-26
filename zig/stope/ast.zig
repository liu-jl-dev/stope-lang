//! AST 节点与测试用形状序列化（对齐 python/stope/ast.py 与 cpp/test/test_common.hpp）。
//! 节点用 Arena 分配，泛型指针为 ?*Expr / ?*Stmt；Prog 持有 stmt 列表。
const std = @import("std");
const tok = @import("token.zig");
const TokenType = tok.TokenType;

pub const LetData = struct { idents: []const []const u8, has_assign: bool, expr: ?*Expr };
pub const IfData = struct { cond: ?*Expr, first: *Prog, elifs: []const Elif, else_prog: ?*Prog };
pub const WhileData = struct { cond: ?*Expr, prog: *Prog };
pub const BinaryData = struct { op: TokenType, left: *Expr, right: *Expr };

pub const Elif = struct {
    cond: ?*Expr = null,
    prog: *Prog,
};

pub const Stmt = struct {
    line: i32,
    data: Data,

    pub const Data = union(enum) {
        expr_stmt: *Expr,
        let_stmt: LetData,
        return_stmt: []const *Expr,
        export_stmt: []const []const u8,
        block_stmt: *Prog,
        if_stmt: IfData,
        while_stmt: WhileData,
        assign_stmt: struct { left: *Expr, right: *Expr },
        break_stmt,
        continue_stmt,
        defer_stmt: ?*Stmt,
        err, // 失败路径的裸语句
    };
};

pub const Expr = struct {
    line: i32,
    data: Data,

    pub const Data = union(enum) {
        err, // line 恒 -1，形状 Err(L-1)
        null_expr,
        bool_expr: bool,
        int_expr: i64,
        float_expr: f64,
        binarr_expr: []const u8,
        string_expr: []const u8,
        ident_expr: []const u8,
        argc_expr,
        args_expr: ?*Expr,
        unary_op: struct { op: TokenType, expr: *Expr },
        binary_op: BinaryData,
        call: struct { callee: *Expr, args: []const *Expr },
        at: struct { container: *Expr, keys: []const *Expr },
        custom: struct { name: []const u8, args: []const *Expr },
    };
};

pub const Prog = struct {
    line: i32 = -1,
    stmts: std.ArrayList(*Stmt),

    pub fn init(_: std.mem.Allocator) Prog {
        return .{ .stmts = std.ArrayList(*Stmt).empty };
    }
};

// ------------------------------------------------------------------ shape 序列化
pub const Shaper = struct {
    alloc: std.mem.Allocator,
    out: std.ArrayList(u8),

    pub fn init(alloc: std.mem.Allocator) Shaper {
        return .{ .alloc = alloc, .out = std.ArrayList(u8).empty };
    }

    fn w(self: *Shaper, s: []const u8) anyerror!void {
        try self.out.appendSlice(self.alloc, s);
    }
    fn wf(self: *Shaper, comptime fmt: []const u8, args: anytype) anyerror!void {
        var buf: [256]u8 = undefined;
        try self.w(try std.fmt.bufPrint(&buf, fmt, args));
    }

    pub fn prog(self: *Shaper, p: *const Prog) anyerror!void {
        for (p.stmts.items, 0..) |s, i| {
            if (i > 0) try self.w(" ; ");
            try self.stmt(s);
        }
    }

    pub fn stmt(self: *Shaper, s: ?*const Stmt) anyerror!void {
        if (s == null) return self.w("null");
        const st = s.?;
        switch (st.data) {
            .expr_stmt => |e| {
                try self.w("ExprStmt(");
                try self.expr(e);
                try self.w(")");
            },
            .let_stmt => |l| {
                try self.w("Let[");
                for (l.idents, 0..) |id, i| {
                    if (i > 0) try self.w(",");
                    try self.w(id);
                }
                try self.w("]");
                if (l.has_assign) {
                    try self.w("=");
                    try self.expr(l.expr);
                }
            },
            .return_stmt => |es| {
                try self.w("Return(");
                for (es, 0..) |e, i| {
                    if (i > 0) try self.w(", ");
                    try self.expr(e);
                }
                try self.w(")");
            },
            .export_stmt => |ids| {
                try self.w("Export[");
                for (ids, 0..) |id, i| {
                    if (i > 0) try self.w(",");
                    try self.w(id);
                }
                try self.w("]");
            },
            .block_stmt => |p| {
                try self.w("Block{");
                try self.prog(p);
                try self.w("}");
            },
            .if_stmt => |iv| {
                try self.w("If(");
                try self.expr(iv.cond);
                try self.w("){");
                try self.prog(iv.first);
                try self.w("}");
                for (iv.elifs) |ei| {
                    try self.w("Elif(");
                    try self.expr(ei.cond);
                    try self.w("){");
                    try self.prog(ei.prog);
                    try self.w("}");
                }
                if (iv.else_prog) |ep| {
                    try self.w("Else{");
                    try self.prog(ep);
                    try self.w("}");
                }
            },
            .while_stmt => |ws| {
                try self.w("While(");
                try self.expr(ws.cond);
                try self.w("){");
                try self.prog(ws.prog);
                try self.w("}");
            },
            .assign_stmt => |a| {
                try self.w("Assign(");
                try self.expr(a.left);
                try self.w(", ");
                try self.expr(a.right);
                try self.w(")");
            },
            .break_stmt => try self.w("Break"),
            .continue_stmt => try self.w("Continue"),
            .defer_stmt => |inner| {
                try self.w("Defer(");
                try self.stmt(inner);
                try self.w(")");
            },
            .err => try self.w("?"),
        }
    }

    pub fn expr(self: *Shaper, e: ?*const Expr) anyerror!void {
        if (e == null) return self.w("null");
        const ex = e.?;
        switch (ex.data) {
            .err => try self.wf("Err(L{d})", .{ex.line}),
            .null_expr => try self.w("Null"),
            .argc_expr => try self.w("Argc"),
            .bool_expr => |v| try self.w(if (v) "Bool(true)" else "Bool(false)"),
            .int_expr => |v| try self.wf("Int({d})", .{v}),
            .float_expr => |v| try self.wf("Float({d})", .{v}),
            .binarr_expr => |b| {
                try self.w("BinArr[");
                for (b, 0..) |byte, i| {
                    if (i > 0) try self.w(",");
                    try self.wf("{x:0>2}", .{byte});
                }
                try self.w("]");
            },
            .string_expr => |sv| {
                try self.w("Str(\"");
                try self.esc(sv);
                try self.w("\")");
            },
            .ident_expr => |id| {
                try self.w("Ident(");
                try self.w(id);
                try self.w(")");
            },
            .args_expr => |k| {
                if (k == null) {
                    try self.w("Args(null)");
                } else {
                    try self.w("Args(");
                    try self.expr(k);
                    try self.w(")");
                }
            },
            .unary_op => |u| {
                try self.w("Unary(");
                try self.w(tok.typeName(u.op));
                try self.w(", ");
                try self.expr(u.expr);
                try self.w(")");
            },
            .binary_op => |b| {
                try self.w("Bin(");
                try self.w(tok.typeName(b.op));
                try self.w(", ");
                try self.expr(b.left);
                try self.w(", ");
                try self.expr(b.right);
                try self.w(")");
            },
            .call => |c| {
                try self.w("Call(");
                try self.expr(c.callee);
                for (c.args) |a| {
                    try self.w("; ");
                    try self.expr(a);
                }
                try self.w(")");
            },
            .at => |a| {
                try self.w("At(");
                try self.expr(a.container);
                for (a.keys) |k| {
                    try self.w("; ");
                    try self.expr(k);
                }
                try self.w(")");
            },
            .custom => |c| {
                try self.w("Custom(");
                try self.w(c.name);
                for (c.args) |a| {
                    try self.w("; ");
                    try self.expr(a);
                }
                try self.w(")");
            },
        }
    }

    /// esc：\\ " \n \r \t 转义，非 ASCII 变 '?'（对齐 python/tests/golden.py 的 esc）。
    fn esc(self: *Shaper, s: []const u8) anyerror!void {
        for (s) |c| {
            switch (c) {
                '\\' => try self.w("\\\\"),
                '"' => try self.w("\\\""),
                '\n' => try self.w("\\n"),
                '\r' => try self.w("\\r"),
                '\t' => try self.w("\\t"),
                else => {
                    if (c < 128) try self.out.append(self.alloc, c) else try self.out.append(self.alloc, '?');
                },
            }
        }
    }

    pub fn done(self: *Shaper) anyerror![]const u8 {
        return self.out.toOwnedSlice(self.alloc);
    }
};

pub fn shapeProg(alloc: std.mem.Allocator, p: *const Prog) anyerror![]const u8 {
    var sh = Shaper.init(alloc);
    try sh.prog(p);
    return sh.done();
}
