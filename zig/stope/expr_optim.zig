//! 常量折叠（照搬 python/stope/expr_optim.py）—— 只做单节点变换，自底向上。
//! 数值 helper 折叠与 VM 共用（本文件导出）；整数 64 位回绕、除法向零取整。
const std = @import("std");
const ast = @import("ast.zig");
const tok = @import("token.zig");
const TokenType = tok.TokenType;

pub fn wrap64(v: i64) i64 {
    return v; // Zig 的 +% -% *% 天然按 64 位回绕，调用处已用回绕运算
}
pub fn intAdd(a: i64, b: i64) i64 {
    return a +% b;
}
pub fn intSub(a: i64, b: i64) i64 {
    return a -% b;
}
pub fn intMul(a: i64, b: i64) i64 {
    return a *% b;
}
pub fn intNeg(a: i64) i64 {
    return -%a;
}
pub fn intDiv(a: i64, b: i64) i64 {
    if (a == std.math.minInt(i64) and b == -1) return std.math.minInt(i64); // 回绕，避免 trap
    return @divTrunc(a, b);
}
pub fn intMod(a: i64, b: i64) i64 {
    if (b == -1) return 0; // 避免 MIN/-1 溢出
    return @rem(a, b); // 向零取整余数
}
pub fn intPow(base: i64, exp_: i64) i64 {
    var result: i64 = 1;
    var b = base;
    var e = exp_;
    while (e > 0) {
        if (e & 1 != 0) result = result *% b;
        e >>= 1;
        if (e > 0) b = b *% b;
    }
    return result;
}
pub fn isSpecial(v: f64) bool {
    return std.math.isNan(v) or std.math.isInf(v);
}
pub fn fmod(a: f64, b: f64) f64 {
    if (b == 0.0 or std.math.isNan(a) or std.math.isNan(b)) return std.math.nan(f64);
    return @rem(a, b); // Zig @rem 余数符号跟被除数（C fmod 语义）
}
pub fn fpow(a: f64, b: f64) f64 {
    return std.math.pow(f64, a, b);
}

const Kind = enum(u8) { not_const, null_, bool_, int_, float_, string, binarr };

fn kindOf(e: ?*const ast.Expr) Kind {
    if (e == null) return .not_const;
    return switch (e.?.data) {
        .null_expr => .null_,
        .bool_expr => .bool_,
        .int_expr => .int_,
        .float_expr => .float_,
        .string_expr => .string,
        .binarr_expr => .binarr,
        else => .not_const,
    };
}
fn isConst(k: Kind) bool {
    return k != .not_const;
}
fn isNumeric(k: Kind) bool {
    return k == .int_ or k == .float_;
}
fn isSeq(k: Kind) bool {
    return k == .string or k == .binarr;
}
fn isNumLike(k: Kind) bool {
    return k == .bool_ or isNumeric(k);
}
fn bothNumInt(lk: Kind, rk: Kind) bool {
    return isNumLike(lk) and isNumLike(rk) and lk != .float_ and rk != .float_;
}
fn asInt(e: *const ast.Expr) i64 {
    return switch (e.data) { .int_expr => |v| v, else => 0 };
}
fn numAsInt(e: *const ast.Expr) i64 {
    return switch (e.data) {
        .bool_expr => |v| if (v) 1 else 0,
        .int_expr => |v| v,
        else => 0,
    };
}
fn asDouble(e: *const ast.Expr) f64 {
    return switch (e.data) {
        .bool_expr => |v| if (v) 1.0 else 0.0,
        .int_expr => |v| @floatFromInt(v),
        .float_expr => |v| v,
        else => 0.0,
    };
}
fn seqSize(e: *const ast.Expr) usize {
    return switch (e.data) {
        .string_expr => |s| s.len,
        .binarr_expr => |b| b.len,
        else => 0,
    };
}
fn truthy(e: *const ast.Expr) bool {
    return switch (e.data) {
        .null_expr => false,
        .bool_expr => |v| v,
        .int_expr => |v| v != 0,
        .float_expr => |v| v != 0.0,
        .string_expr => |s| s.len != 0,
        .binarr_expr => |b| b.len != 0,
        else => false,
    };
}

const Ctx = struct {
    alloc: std.mem.Allocator,
    fn mk(self: Ctx, line: i32, data: ast.Expr.Data) !*ast.Expr {
        const e = try self.alloc.create(ast.Expr);
        e.* = .{ .line = line, .data = data };
        return e;
    }
    fn seqEqual(self: Ctx, a: *const ast.Expr, b: *const ast.Expr) bool {
        _ = self;
        return switch (a.data) {
            .string_expr => |s| switch (b.data) { .string_expr => |t| std.mem.eql(u8, s, t), else => false },
            .binarr_expr => |x| switch (b.data) { .binarr_expr => |y| std.mem.eql(u8, x, y), else => false },
            else => false,
        };
    }
    fn repeatSeq(self: Ctx, line: i32, base: *const ast.Expr, times: i64) !?*ast.Expr {
        if (times < 0) return null;
        const unit = seqSize(base);
        const k = kindOf(base);
        if (unit == 0) return try self.mk(line, if (k == .string) .{ .string_expr = "" } else .{ .binarr_expr = &.{} });
        if (times > @divTrunc(@as(i64, 1 << 20), @as(i64, @intCast(unit)))) return null;
        const out = try self.alloc.alloc(u8, unit * @as(usize, @intCast(times)));
        var pos: usize = 0;
        var i: i64 = 0;
        while (i < times) : (i += 1) {
            const src = switch (base.data) { .string_expr => |s| s, .binarr_expr => |b| b, else => unreachable };
            @memcpy(out[pos .. pos + unit], src);
            pos += unit;
        }
        return try self.mk(line, if (k == .string) .{ .string_expr = out } else .{ .binarr_expr = out });
    }
    fn cloneConst(self: Ctx, line: i32, e: *const ast.Expr) !?*ast.Expr {
        return switch (e.data) {
            .null_expr => try self.mk(line, .null_expr),
            .bool_expr => |v| try self.mk(line, .{ .bool_expr = v }),
            .int_expr => |v| try self.mk(line, .{ .int_expr = v }),
            .float_expr => |v| try self.mk(line, .{ .float_expr = v }),
            .string_expr => |s| try self.mk(line, .{ .string_expr = s }),
            .binarr_expr => |b| try self.mk(line, .{ .binarr_expr = b }),
            else => null,
        };
    }
};

fn cmpOf(op: TokenType, a: i64, b: i64) bool {
    return switch (op) { .LT => a < b, .LE => a <= b, .GT => a > b, else => a >= b };
}
fn cmpOfF(op: TokenType, a: f64, b: f64) bool {
    return switch (op) { .LT => a < b, .LE => a <= b, .GT => a > b, else => a >= b };
}

fn foldUnary(ctx: Ctx, e: *ast.Expr) !?*ast.Expr {
    const inner = switch (e.data) { .unary_op => |u| u.expr, else => return null };
    const ck = kindOf(inner);
    if (!isConst(ck)) return null;
    const op = switch (e.data) { .unary_op => |u| u.op, else => unreachable };
    const line = e.line;
    if (op == .Not) {
        if (ck == .null_ or isNumLike(ck)) return try ctx.mk(line, .{ .bool_expr = !truthy(inner) });
        return null;
    }
    if (op == .Sub) {
        return switch (inner.data) {
            .bool_expr => |v| try ctx.mk(line, .{ .int_expr = if (v) -1 else 0 }),
            .int_expr => |v| try ctx.mk(line, .{ .int_expr = intNeg(v) }),
            .float_expr => |v| try ctx.mk(line, .{ .float_expr = -v }),
            else => null,
        };
    }
    return null;
}

fn foldBinary(ctx: Ctx, e: *ast.Expr) !?*ast.Expr {
    const pair = switch (e.data) { .binary_op => |b| b, else => return null };
    const L = pair.left;
    const R = pair.right;
    const lk = kindOf(L);
    const rk = kindOf(R);
    if (!isConst(lk) or !isConst(rk)) return null;
    const op = pair.op;
    const line = e.line;

    // L1 and/or
    if (op == .And) return try ctx.mk(line, .{ .bool_expr = truthy(L) and truthy(R) });
    if (op == .Or) return try ctx.mk(line, .{ .bool_expr = truthy(L) or truthy(R) });

    // L2 null
    if (lk == .null_ or rk == .null_) {
        const both = lk == .null_ and rk == .null_;
        if (op == .EQ) return try ctx.mk(line, .{ .bool_expr = both });
        if (op == .NE) return try ctx.mk(line, .{ .bool_expr = !both });
        return null;
    }

    // L3 比较
    if (op == .EQ or op == .NE) {
        var decided = false;
        var eq = false;
        if (lk == .bool_ and rk == .bool_) {
            decided = true;
            eq = switch (L.data) { .bool_expr => |a| switch (R.data) { .bool_expr => |b| a == b, else => false }, else => false };
        } else if (isNumeric(lk) and isNumeric(rk)) {
            decided = true;
            eq = if (bothNumInt(lk, rk)) asInt(L) == asInt(R) else asDouble(L) == asDouble(R);
        } else if (isSeq(lk) and lk == rk) {
            decided = true;
            eq = ctx.seqEqual(L, R);
        }
        if (decided) return try ctx.mk(line, .{ .bool_expr = if (op == .EQ) eq else !eq });
        return null;
    }
    if (op == .LT or op == .LE or op == .GT or op == .GE) {
        if (isNumeric(lk) and isNumeric(rk)) {
            const v = if (bothNumInt(lk, rk)) cmpOf(op, asInt(L), asInt(R)) else cmpOfF(op, asDouble(L), asDouble(R));
            return try ctx.mk(line, .{ .bool_expr = v });
        }
        return null;
    }

    // L4 算术
    if (isNumLike(lk)) {
        if (op == .Add or op == .Sub or op == .Mul) {
            if (isNumLike(rk)) {
                if (bothNumInt(lk, rk)) {
                    const a = numAsInt(L);
                    const b = numAsInt(R);
                    return try ctx.mk(line, .{ .int_expr = if (op == .Add) intAdd(a, b) else if (op == .Sub) intSub(a, b) else intMul(a, b) });
                }
                const x = asDouble(L);
                const y = asDouble(R);
                return try ctx.mk(line, .{ .float_expr = if (op == .Add) x + y else if (op == .Sub) x - y else x * y });
            } else if (op == .Mul and isSeq(rk) and lk != .float_) {
                return try ctx.repeatSeq(line, R, numAsInt(L));
            }
        } else if (op == .Div) {
            if (isNumLike(rk)) {
                if (bothNumInt(lk, rk)) {
                    const a = numAsInt(L);
                    const b = numAsInt(R);
                    if (b != 0) {
                        if (intMod(a, b) == 0) return try ctx.mk(line, .{ .int_expr = intDiv(a, b) });
                        return try ctx.mk(line, .{ .float_expr = @as(f64, @floatFromInt(a)) / @as(f64, @floatFromInt(b)) });
                    }
                } else {
                    const bb = asDouble(R);
                    if (bb != 0.0) return try ctx.mk(line, .{ .float_expr = asDouble(L) / bb });
                }
            }
        } else if (op == .IDiv) {
            if (bothNumInt(lk, rk)) {
                const a = numAsInt(L);
                const b = numAsInt(R);
                if (b != 0) return try ctx.mk(line, .{ .int_expr = intDiv(a, b) });
            }
        } else if (op == .Mod) {
            if (isNumLike(rk)) {
                if (bothNumInt(lk, rk)) {
                    const a = numAsInt(L);
                    const b = numAsInt(R);
                    if (b != 0) return try ctx.mk(line, .{ .int_expr = intMod(a, b) });
                } else {
                    const bb = asDouble(R);
                    if (bb != 0.0) return try ctx.mk(line, .{ .float_expr = fmod(asDouble(L), bb) });
                }
            }
        } else if (op == .Pow) {
            if (isNumLike(rk)) {
                if (bothNumInt(lk, rk)) {
                    const b = numAsInt(R);
                    if (b >= 0) return try ctx.mk(line, .{ .int_expr = intPow(numAsInt(L), b) });
                }
                const rr = fpow(asDouble(L), asDouble(R));
                if (!isSpecial(rr)) return try ctx.mk(line, .{ .float_expr = rr });
            }
        }
    } else if (isSeq(lk)) {
        if (op == .Add and rk == lk) {
            const a = switch (L.data) { .string_expr => |s| s, .binarr_expr => |b| b, else => unreachable };
            const b = switch (R.data) { .string_expr => |s| s, .binarr_expr => |v| v, else => unreachable };
            const out = try std.mem.concat(ctx.alloc, u8, &.{ a, b });
            return try ctx.mk(line, if (lk == .string) .{ .string_expr = out } else .{ .binarr_expr = out });
        } else if (op == .Mul and (rk == .int_ or rk == .bool_)) {
            return try ctx.repeatSeq(line, L, numAsInt(R));
        }
    }
    return null;
}

/// 单节点折叠：返回新节点或入参本身。
pub fn optimize(alloc: std.mem.Allocator, e: ?*ast.Expr) !?*ast.Expr {
    if (e == null) return null;
    const ctx = Ctx{ .alloc = alloc };
    switch (e.?.data) {
        .unary_op => {
            if (try foldUnary(ctx, e.?)) |r| return r;
        },
        .binary_op => {
            if (try foldBinary(ctx, e.?)) |r| return r;
        },
        else => {},
    }
    return e;
}
