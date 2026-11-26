package demo;

import stope.*;

/** demo 02：STML 解析（默认状态函数 + shape 输出）。 */
public final class Demo02 {
    public static void main(String[] args) {
        String src = "<root a=\"1\"><p>Hello</p><sto>return 1;</sto></root>";
        StmlLexer lx = new StmlLexer(src, Stml.LexerState.Xml);
        StmlParser ps = new StmlParser(lx);
        Stml.Element root = new Stml.Element();
        boolean ok = ps.parse(root, StmlParser.defaultStateFunc());
        System.out.println("parse: " + (ok ? "Success" : "Error"));
        System.out.println("shape: " + StmlParser.shape(root, Goldenless::esc));
    }

    /** demo 不依赖 tests包的 Golden，自带一个简单转义。 */
    static final class Goldenless {
        static String esc(String s) {
            StringBuilder out = new StringBuilder();
            for (int i = 0; i < s.length(); i++) {
                char c = s.charAt(i);
                switch (c) {
                    case '\\' -> out.append("\\\\");
                    case '"' -> out.append("\\\"");
                    case '\n' -> out.append("\\n");
                    case '\r' -> out.append("\\r");
                    case '\t' -> out.append("\\t");
                    default -> out.append(c < 128 ? c : '?');
                }
            }
            return out.toString();
        }
    }
}
