package stope;

import java.util.ArrayList;
import java.util.List;
import stope.Stml.LexerState;
import stope.Stml.Token;

/** STML 词法器：四态状态机（Xml/Text/Nevext/Stope）—— 照搬 python/stope/stml_lexer.py。 */
public final class StmlLexer {
    private String src;
    private int pos = 0;
    public LexerState state = LexerState.Xml;
    public int line = 1;
    public final List<String> errors = new ArrayList<>();

    public StmlLexer(String source, LexerState st) { this.src = source; this.state = st; }
    public StmlLexer(String source) { this(source, LexerState.Xml); }

    private void addError(int ln, String msg) { errors.add("line " + ln + ": " + msg); }
    private boolean eof() { return pos >= src.length(); }
    private char cur() { return src.charAt(pos); }
    private boolean startsWith(String p) { return src.startsWith(p, pos); }

    private static boolean isWhite(char c) {
        return c == ' ' || c == '\t' || c == 0x0b || c == 0x0c || c == '\r' || c == '\n';
    }
    private static boolean isAlpha(char c) { return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z'); }
    private static boolean isDigit(char c) { return c >= '0' && c <= '9'; }
    private static boolean isWordBegin(char c) { return isAlpha(c) || c == '_' || c == ':'; }
    private static boolean isWordChar(char c) { return isWordBegin(c) || isDigit(c) || c == '-'; }

    public static boolean hasLexeme(int t) {
        return t == Stml.Word || t == Stml.String || t == Stml.Text
            || t == Stml.NevextSrc || t == Stml.StopeSrc;
    }

    public Token nextToken() {
        Token t = new Token();
        skipWs();
        t.line = line;
        if (eof()) { t.typ = Stml.Eof; return t; }
        switch (state) {
            case Xml -> {
                if (startsWith("</")) { t.typ = Stml.CLAngle; t.lexeme = "</"; pos += 2; }
                else if (startsWith("/>")) { t.typ = Stml.CRAngle; t.lexeme = "/>"; pos += 2; }
                else if (cur() == '<') { t.typ = Stml.LAngle; t.lexeme = "<"; pos++; }
                else if (cur() == '>') { t.typ = Stml.RAngle; t.lexeme = ">"; pos++; }
                else if (cur() == '=') { t.typ = Stml.EQ; t.lexeme = "="; pos++; }
                else if (cur() == '"' || cur() == '\'') scanString(t);
                else if (isWordBegin(cur())) { t.typ = Stml.Word; t.lexeme = scanWord(); }
                else { addError(line, "unexpected character. "); t.typ = Stml.Invalid; t.lexeme = ""; pos++; }
            }
            case Text -> { t.typ = Stml.Text; t.lexeme = scanContent(LexerState.Text); state = LexerState.Xml; }
            case Nevext -> { t.typ = Stml.NevextSrc; t.lexeme = scanContent(LexerState.Nevext); state = LexerState.Xml; }
            case Stope -> { t.typ = Stml.StopeSrc; t.lexeme = scanContent(LexerState.Stope); state = LexerState.Xml; }
        }
        return t;
    }

    private void scanString(Token t) {
        t.typ = Stml.String;
        char quote = cur();
        pos++;
        int start = pos;
        while (true) {
            if (eof()) { addError(line, "unclosed string literal"); pos = src.length(); t.typ = Stml.Invalid; return; }
            if (cur() == quote) { t.lexeme = src.substring(start, pos); pos++; return; }
            if (cur() == '\n') line++;
            pos++;
        }
    }

    private String scanWord() {
        int start = pos;
        pos++; // 首字符已确认
        while (!eof() && isWordChar(cur())) pos++;
        return src.substring(start, pos);
    }

    private String scanContent(LexerState mode) {
        int start = pos;
        while (!eof()) {
            if (startsWith("</")) break;
            if (mode != LexerState.Text) {
                char c = cur();
                if (c == '\'' || c == '"') { scanCodeStr(c, mode == LexerState.Nevext || c == '"'); continue; }
                if (startsWith("//")) { skipSingleComment(); continue; }
                if (startsWith("/*")) { skipMultiComment(); continue; }
            }
            if (cur() == '\n') line++;
            pos++;
        }
        String out = src.substring(start, pos);
        // trim trailing whitespace
        int n = out.length();
        while (n > 0 && isWhite(out.charAt(n - 1))) n--;
        return out.substring(0, n);
    }

    private void scanCodeStr(char quote, boolean escapes) {
        int beginLine = line;
        pos++; // 跳过开头引号
        while (true) {
            if (eof()) { addError(beginLine, "unclosed string literal. "); return; }
            char c = cur();
            pos++;
            if (escapes && c == '\\') {
                if (eof()) { addError(beginLine, "unclosed string literal. "); return; }
                if (cur() == '\n') line++;
                pos++;
            } else if (c == quote) return;
            else if (c == '\n') line++;
        }
    }

    private void skipSingleComment() {
        pos += 2;
        while (!eof()) {
            char c = cur(); pos++;
            if (c == '\n') { line++; return; }
        }
    }

    private void skipMultiComment() {
        pos += 2;
        while (!eof()) {
            if (startsWith("*/")) { pos += 2; return; }
            if (cur() == '\n') line++;
            pos++;
        }
    }

    private void skipWs() {
        while (!eof()) {
            char c = cur();
            if (isWhite(c)) { if (c == '\n') line++; pos++; }
            else if (state == LexerState.Xml && startsWith("<!--")) skipXmlComment();
            else break;
        }
    }

    private void skipXmlComment() {
        pos += 4;
        while (!eof()) {
            if (startsWith("-->")) { pos += 3; return; }
            if (cur() == '\n') line++;
            pos++;
        }
    }
}
