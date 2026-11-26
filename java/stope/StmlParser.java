package stope;

import java.util.ArrayList;
import java.util.Collections;
import java.util.List;
import java.util.function.Function;
import stope.Stml.Element;
import stope.Stml.LexerState;
import stope.Stml.Token;

/** STML 语法分析器 —— 照搬 python/stope/stml_parser.py。 */
public final class StmlParser {
    /** tag → 内容状态的函数（宿主可定制）。 */
    public interface StateFunc { LexerState apply(String tag); }

    public static StateFunc defaultStateFunc() {
        return tag -> {
            if ("sto".equals(tag)) return LexerState.Stope;
            if ("nev".equals(tag)) return LexerState.Nevext;
            if ("p".equals(tag)) return LexerState.Text;
            return LexerState.Xml;
        };
    }

    private final StmlLexer lexer;
    private StateFunc stateFunc;
    public final List<String> errors = new ArrayList<>();
    private Token token = new Token();
    public int maxDepth = 256;
    public boolean aborted = false;

    public StmlParser(StmlLexer lx) { this.lexer = lx; }

    public boolean parse(Element root, StateFunc sf) {
        this.stateFunc = sf;
        this.aborted = false;
        nextToken();
        parseElement(root, 1);
        return errors.isEmpty();
    }

    private void parseElement(Element e, int depth) {
        if (aborted) return;
        if (maxDepth > 0 && depth > maxDepth) {
            addError("nesting too deep (max " + maxDepth + "). ");
            aborted = true;
            return;
        }
        lexer.state = LexerState.Xml;
        e.line = token.line;
        if (token.typ != Stml.LAngle) { addError("expected \"<\". "); return; }
        nextToken();
        if (token.typ != Stml.Word) { addError("expected tag name. "); return; }
        e.tag = token.lexeme;
        nextToken();
        while (true) {
            if (token.typ == Stml.RAngle) break;
            if (token.typ == Stml.CRAngle) { e.selfClosing = true; return; }
            if (token.typ == Stml.Word) {
                String name = token.lexeme;
                nextToken();
                if (token.typ == Stml.EQ) {
                    nextToken();
                    if (token.typ != Stml.String) { addError("expected string. "); return; }
                    if (!e.attrs.containsKey(name)) e.attrs.put(name, token.lexeme);
                    nextToken();
                } else {
                    if (!e.attrs.containsKey(name)) e.attrs.put(name, "");
                }
            } else { addError("expected \">\" or \"/>\" or attribute. "); return; }
        }
        lexer.state = stateFunc != null ? stateFunc.apply(e.tag) : LexerState.Xml;
        if (lexer.state == LexerState.Xml) {
            while (true) {
                nextToken();
                if (token.typ == Stml.CLAngle) break;
                if (token.typ == Stml.LAngle) {
                    Element child = new Element();
                    e.children.add(child);
                    parseElement(child, depth + 1);
                    if (aborted) return;
                } else { addError("expected \"<\" or \"</\". "); return; }
            }
        } else {
            nextToken();
            if (token.typ != Stml.Text && token.typ != Stml.NevextSrc && token.typ != Stml.StopeSrc) {
                addError("expected element content. "); return;
            }
            e.text = token.lexeme;
            e.textLine = token.line;
            nextToken();
        }
        nextToken();
        if (token.typ != Stml.Word) { addError("expected tag name. "); return; }
        if (!token.lexeme.equals(e.tag)) { addError("tag name mismatch. "); return; }
        nextToken();
        if (token.typ != Stml.RAngle) { addError("expected \">\". "); return; }
    }

    private void nextToken() { token = lexer.nextToken(); }
    private void addError(String msg) {
        if (aborted) return;
        errors.add("line " + token.line + ": " + msg);
    }

    /** 元素形状串（测试用，照搬 python/tests/test_stml.py 的 _shape）。 */
    public static String shape(Element e, Function<String, String> esc16) {
        StringBuilder out = new StringBuilder("Elem(");
        out.append(esc16.apply(e.tag));
        out.append(", L").append(e.line);
        if (e.selfClosing) out.append(", /");
        List<String> names = new ArrayList<>(e.attrs.keySet());
        Collections.sort(names);
        for (String name : names) {
            out.append(", @").append(esc16.apply(name));
            String v = e.attrs.get(name);
            if (!v.isEmpty()) out.append("=\"").append(esc16.apply(v)).append('"');
        }
        if (!e.text.isEmpty()) {
            out.append(", T(L").append(e.textLine).append(")=\"").append(esc16.apply(e.text)).append('"');
        }
        if (!e.children.isEmpty()) {
            out.append(", C=[");
            for (int i = 0; i < e.children.size(); i++) {
                if (i > 0) out.append(' ');
                out.append(shape(e.children.get(i), esc16));
            }
            out.append(']');
        }
        out.append(')');
        return out.toString();
    }
}
