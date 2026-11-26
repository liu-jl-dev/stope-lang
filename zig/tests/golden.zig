//! golden 数据的读取与转义（照抄 python/tests/golden.py 的逻辑）。
//! 数据真源在 gdscript/test/data/，只读、绝不复制。测试只跑在仓库里。
const std = @import("std");

pub const Record = struct {
    fields: std.StringHashMap([]const u8),

    pub fn get(self: Record, key: []const u8) []const u8 {
        return self.fields.get(key) orelse "";
    }
};

/// 找数据目录：先试仓库根的相对路径，再试从 zig/ 出发的 ../。
fn locateDataDir(alloc: std.mem.Allocator, io: std.Io) ![]const u8 {
    const cwd = std.Io.Dir.cwd();
    for ([_][]const u8{ "gdscript/test/data", "../gdscript/test/data" }) |cand| {
        if (cwd.access(io, cand, .{})) |_| {
            return alloc.dupe(u8, cand);
        } else |_| {}
    }
    return error.DataDirNotFound;
}

pub fn dataPath(alloc: std.mem.Allocator, io: std.Io, name: []const u8) ![]const u8 {
    return std.fs.path.join(alloc, &.{ try locateDataDir(alloc, io), name });
}

/// 读整份文件，统一剥掉 \r（Windows 探针输出 CRLF）。返回按行切好的切片。
pub fn readLines(alloc: std.mem.Allocator, io: std.Io, name: []const u8) ![][]const u8 {
    const path = try dataPath(alloc, io, name);
    const raw = try std.Io.Dir.cwd().readFileAlloc(io, path, alloc, .limited(16 * 1024 * 1024));
    const clean = try alloc.alloc(u8, raw.len);
    var n: usize = 0;
    for (raw) |c| {
        if (c != '\r') {
            clean[n] = c;
            n += 1;
        }
    }
    var lines = std.ArrayList([]const u8).empty;
    var it = std.mem.splitScalar(u8, clean[0..n], '\n');
    while (it.next()) |line| try lines.append(alloc, line);
    return lines.toOwnedSlice(alloc);
}

/// KEY=VALUE 字典（行首 # 是注释）。unescape_values 只对 golden.txt / golden_disasm 为 true。
pub fn readGolden(alloc: std.mem.Allocator, io: std.Io, name: []const u8, unescape_values: bool) ![]Record {
    const lines = try readLines(alloc, io, name);
    var out = std.ArrayList(Record).empty;
    for (lines) |line| {
        if (line.len == 0 or line[0] == '#') continue;
        var rec = Record{ .fields = std.StringHashMap([]const u8).init(alloc) };
        var fit = std.mem.splitScalar(u8, line, '\t');
        while (fit.next()) |field| {
            const eq = std.mem.indexOfScalar(u8, field, '=') orelse continue;
            const key = field[0..eq];
            const v = field[eq + 1 ..];
            try rec.fields.put(key, if (unescape_values) try unescape(alloc, v) else v);
        }
        if (rec.fields.count() > 0) try out.append(alloc, rec);
    }
    return out.toOwnedSlice(alloc);
}

/// 与探针 E_() 对称：\\ \n \r \t，其余原样保留。
pub fn unescape(alloc: std.mem.Allocator, s: []const u8) ![]const u8 {
    var out = std.ArrayList(u8).empty;
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] != '\\') {
            try out.append(alloc, s[i]);
            i += 1;
            continue;
        }
        i += 1;
        const c = if (i < s.len) s[i] else 0;
        i += 1;
        switch (c) {
            '\\' => try out.append(alloc, '\\'),
            'n' => try out.append(alloc, '\n'),
            'r' => try out.append(alloc, '\r'),
            't' => try out.append(alloc, '\t'),
            else => {
                try out.append(alloc, '\\');
                try out.append(alloc, c);
            },
        }
    }
    return out.toOwnedSlice(alloc);
}

/// 与 unescape 相同，但多认 \v \f —— 词法与 STML 的 SRC 用这套。
pub fn unescapeLex(alloc: std.mem.Allocator, s: []const u8) ![]const u8 {
    var out = std.ArrayList(u8).empty;
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] == '\\' and i + 1 < s.len) {
            const c = s[i + 1];
            const mapped: ?u8 = switch (c) {
                '\\' => '\\',
                'n' => '\n',
                'r' => '\r',
                't' => '\t',
                'v' => 0x0b,
                'f' => 0x0c,
                else => null,
            };
            if (mapped) |m| {
                try out.append(alloc, m);
                i += 2;
                continue;
            }
        }
        try out.append(alloc, s[i]);
        i += 1;
    }
    return out.toOwnedSlice(alloc);
}

/// 词法比对专用转义：比 esc 多 \v \f、不转义引号。
/// 非 ASCII 按 UTF-16 码元数输出 '?'（BMP 一个、非 BMP 两个），对齐 C++ 的 u16string 口径。
pub fn escLex(alloc: std.mem.Allocator, s: []const u8) ![]const u8 {
    var out = std.ArrayList(u8).empty;
    var i: usize = 0;
    while (i < s.len) {
        const c = s[i];
        if (c < 128) {
            switch (c) {
                '\\' => try out.appendSlice(alloc, "\\\\"),
                '\n' => try out.appendSlice(alloc, "\\n"),
                '\r' => try out.appendSlice(alloc, "\\r"),
                '\t' => try out.appendSlice(alloc, "\\t"),
                0x0b => try out.appendSlice(alloc, "\\v"),
                0x0c => try out.appendSlice(alloc, "\\f"),
                else => try out.append(alloc, c),
            }
            i += 1;
            continue;
        }
        const n = std.unicode.utf8ByteSequenceLength(c) catch 1;
        const cp = std.unicode.utf8Decode(s[i .. @min(i + n, s.len)]) catch 0;
        const units: usize = if (cp > 0xffff) 2 else 1;
        var k: usize = 0;
        while (k < units) : (k += 1) try out.append(alloc, '?');
        i += n;
    }
    return out.toOwnedSlice(alloc);
}

/// printf("%g") 的忠实实现（C 的 %g）。先用 {d} 起步，够 golden 的词法用例。
pub fn fmtG(alloc: std.mem.Allocator, v: f64) ![]const u8 {
    if (std.math.isNan(v)) return alloc.dupe(u8, "nan");
    if (std.math.isInf(v)) return alloc.dupe(u8, if (v < 0) "-inf" else "inf");
    var buf: [256]u8 = undefined;
    const s = try std.fmt.bufPrint(&buf, "{d}", .{v});
    return alloc.dupe(u8, s);
}

pub fn joinEsc(alloc: std.mem.Allocator, errs: []const []const u8) ![]const u8 {
    var out = std.ArrayList(u8).empty;
    for (errs, 0..) |e, i| {
        if (i > 0) try out.append(alloc, '|');
        try out.appendSlice(alloc, try escLex(alloc, e));
    }
    return out.toOwnedSlice(alloc);
}
