package tests;

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.Paths;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/** golden 数据的读取与转义（照抄 python/tests/golden.py 的逻辑）。
 *  数据真源在 gdscript/test/data/，只读、绝不复制。测试只跑在仓库里。
 *  Java 的 String 天然按 UTF-16 码元编址，与 C++ u16string 对齐。 */
public final class Golden {
    private Golden() {}

    public static final class Record {
        public final Map<String, String> fields;
        public Record(Map<String, String> f) { this.fields = f; }
        public String get(String k) { String v = fields.get(k); return v == null ? "" : v; }
        public boolean has(String k) { return fields.containsKey(k); }
    }

    /** 找数据目录：先试仓库根的相对路径，再试从 java/ 出发的 ../。 */
    private static Path dataDir() {
        for (String cand : new String[] { "gdscript/test/data", "../gdscript/test/data" }) {
            if (Files.isDirectory(Paths.get(cand))) return Paths.get(cand);
        }
        throw new RuntimeException("golden data dir not found");
    }

    public static Path dataPath(String name) { return dataDir().resolve(name); }

    /** 读整份文件，统一剥掉 \r。返回按行切好的列表。 */
    public static List<String> readLines(String name) {
        try {
            byte[] raw = Files.readAllBytes(dataPath(name));
            String decoded = new String(raw, StandardCharsets.UTF_8);
            StringBuilder clean = new StringBuilder(decoded.length());
            for (int i = 0; i < decoded.length(); i++) {
                char c = decoded.charAt(i);
                if (c != '\r') clean.append(c);
            }
            List<String> lines = new ArrayList<>();
            for (String line : clean.toString().split("\n", -1)) lines.add(line);
            return lines;
        } catch (IOException e) {
            throw new RuntimeException(e);
        }
    }

    /** KEY=VALUE 字典（行首 # 是注释）。unescapeValues 只对 golden.txt / golden_disasm 为 true。 */
    public static List<Record> readGolden(String name, boolean unescapeValues) {
        List<Record> out = new ArrayList<>();
        for (String line : readLines(name)) {
            if (line.isEmpty() || line.charAt(0) == '#') continue;
            Map<String, String> fields = new LinkedHashMap<>();
            for (String field : line.split("\t", -1)) {
                int eq = field.indexOf('=');
                if (eq < 0) continue;
                String v = field.substring(eq + 1);
                fields.put(field.substring(0, eq), unescapeValues ? unescape(v) : v);
            }
            if (!fields.isEmpty()) out.add(new Record(fields));
        }
        return out;
    }

    /** 与探针 E_() 对称：\ \n \r \t，其余原样保留。 */
    public static String unescape(String s) {
        StringBuilder out = new StringBuilder(s.length());
        for (int i = 0; i < s.length(); i++) {
            char c = s.charAt(i);
            if (c != '\\') { out.append(c); continue; }
            i++;
            char e = i < s.length() ? s.charAt(i) : 0;
            switch (e) {
                case '\\' -> out.append('\\');
                case 'n' -> out.append('\n');
                case 'r' -> out.append('\r');
                case 't' -> out.append('\t');
                default -> { out.append('\\'); out.append(e); }
            }
        }
        return out.toString();
    }

    /** 与 unescape 相同，但多认 \v \f —— 词法与 STML 的 SRC 用这套。 */
    public static String unescapeLex(String s) {
        StringBuilder out = new StringBuilder(s.length());
        for (int i = 0; i < s.length(); i++) {
            char c = s.charAt(i);
            if (c == '\\' && i + 1 < s.length()) {
                char e = s.charAt(i + 1);
                char mapped = switch (e) {
                    case '\\' -> '\\'; case 'n' -> '\n'; case 'r' -> '\r';
                    case 't' -> '\t'; case 'v' -> 0x0b; case 'f' -> 0x0c;
                    default -> 0;
                };
                if (e == '\\' || e == 'n' || e == 'r' || e == 't' || e == 'v' || e == 'f') {
                    out.append(mapped); i++; continue;
                }
            }
            out.append(c);
        }
        return out.toString();
    }

    /** 词法比对专用转义：比 esc 多 \v \f、不转义引号。
     *  非 ASCII 按 UTF-16 码元输出 '?' —— Java String 按 char 遍历天然是码元。 */
    public static String escLex(String s) {
        StringBuilder out = new StringBuilder(s.length());
        for (int i = 0; i < s.length(); i++) {
            char c = s.charAt(i);
            if (c < 128) {
                switch (c) {
                    case '\\' -> out.append("\\\\");
                    case '\n' -> out.append("\\n");
                    case '\r' -> out.append("\\r");
                    case '\t' -> out.append("\\t");
                    case 0x0b -> out.append("\\v");
                    case 0x0c -> out.append("\\f");
                    default -> out.append(c);
                }
            } else out.append('?');
        }
        return out.toString();
    }

    /** STML shape 转义：与 escLex 同但转义引号（对齐 python test_stml 的 _esc16）。 */
    public static String esc16(String s) {
        StringBuilder out = new StringBuilder(s.length());
        for (int i = 0; i < s.length(); i++) {
            char c = s.charAt(i);
            if (c < 128) {
                switch (c) {
                    case '\\' -> out.append("\\\\");
                    case '"' -> out.append("\\\"");
                    case '\n' -> out.append("\\n");
                    case '\r' -> out.append("\\r");
                    case '\t' -> out.append("\\t");
                    default -> out.append(c);
                }
            } else out.append('?');
        }
        return out.toString();
    }

    public static String joinEsc(List<String> errs) {
        StringBuilder out = new StringBuilder();
        for (int i = 0; i < errs.size(); i++) {
            if (i > 0) out.append('|');
            out.append(escLex(errs.get(i)));
        }
        return out.toString();
    }

    public static String fmtG(double v) { return stope.Format.fmtG(v); }

    /** stml_cases 的一条用例。 */
    public static final class StmlCase {
        public final Record rec;
        public final String src;
        public final int times;
        public StmlCase(Record r, String s, int t) { rec = r; src = s; times = t; }
        public String get(String k) { return rec.get(k); }
    }

    /** stml_cases.txt：用例清单（SRC 用 unescapeLex，TIMES 默认 1）。 */
    public static List<StmlCase> readStmlCases() {
        List<StmlCase> out = new ArrayList<>();
        for (String line : readLines("stml_cases.txt")) {
            if (line.isEmpty() || line.charAt(0) == '#') continue;
            Map<String, String> fields = new LinkedHashMap<>();
            for (String field : line.split("	", -1)) {
                int eq = field.indexOf('=');
                if (eq < 0) continue;
                fields.put(field.substring(0, eq), field.substring(eq + 1));
            }
            Record rec = new Record(fields);
            if (!rec.has("ID")) continue;
            String src = unescapeLex(rec.get("SRC"));
            int times = 1;
            String ts = rec.get("TIMES");
            if (!ts.isEmpty()) try { times = Integer.parseInt(ts); } catch (NumberFormatException ignored) {}
            out.add(new StmlCase(rec, src, times));
        }
        return out;
    }

}
