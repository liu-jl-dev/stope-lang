package stope;

import java.util.ArrayList;
import java.util.List;
import java.util.Map;

/** 词法分析器。照搬 python/stope/lexer.py，对齐 cpp/src/lexer.cpp。
 *  不出异常：出错只往 errors 记一条，然后按最长可行前缀产 token 继续扫。
 *  Java String 按 UTF-16 码元编址，与语言契约一致。 */
public final class Lexer {
    private String input;
    private int pos = 0;
    private int line = 1;
    public final List<String> errors = new ArrayList<>();
    public Opcode.CustomOpcodeConfig custom = null;

    private static final Map<String, Integer> KEYWORDS = Map.ofEntries(
        Map.entry("idiv", TokenType.IDiv), Map.entry("not", TokenType.Not),
        Map.entry("and", TokenType.And), Map.entry("or", TokenType.Or),
        Map.entry("if", TokenType.If), Map.entry("elif", TokenType.Elif),
        Map.entry("else", TokenType.Else), Map.entry("let", TokenType.Let),
        Map.entry("return", TokenType.Return), Map.entry("while", TokenType.While),
        Map.entry("break", TokenType.Break), Map.entry("continue", TokenType.Continue),
        Map.entry("defer", TokenType.Defer), Map.entry("null", TokenType.Null),
        Map.entry("false", TokenType.False_), Map.entry("true", TokenType.True_),
        Map.entry("args", TokenType.Args), Map.entry("argc", TokenType.Argc),
        Map.entry("export", TokenType.Export)
    );

    public Lexer(String src) { this.input = src; }

    private boolean eof() { return pos >= input.length(); }
    private char cur() { return input.charAt(pos); }
    private boolean startsWith(String s) { return input.startsWith(s, pos); }
    private void addError(String msg) {
        errors.add("line " + line + ": " + msg);
    }

    private static boolean isWhite(char c) {
        return c == ' ' || c == '\t' || c == '\r' || c == '\n' || c == 0x0b || c == 0x0c;
    }
    private static boolean isDigit(char c) { return c >= '0' && c <= '9'; }
    private static boolean isHex(char c) {
        return isDigit(c) || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F');
    }
    private static boolean isAlpha(char c) {
        return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z');
    }
    private static boolean isIdentBegin(char c) { return isAlpha(c) || c == '_'; }
    private static boolean isIdentChar(char c) { return isAlpha(c) || isDigit(c) || c == '_'; }
    private static boolean isDigitOrUnderscore(char c) { return isDigit(c) || c == '_'; }
    private static boolean isDigitsFor(char c, int base) {
        return switch (base) {
            case 2 -> c == '0' || c == '1';
            case 8 -> c >= '0' && c <= '7';
            case 16 -> isHex(c);
            default -> isDigit(c);
        };
    }

    // ------------------------------------------------------------- 主循环
    public Token nextToken() {
        skipWs();
        Token t = new Token();
        t.line = line;
        t.typ = TokenType.Eof;
        if (eof()) return t;
        char c = cur();
        if (isDigit(c) || c == '.') scanNumber(t);
        else if (isIdentBegin(c)) { scanIdent(t); analyzeIdent(t); }
        else if (c == '\'') scanBinArr(t);
        else if (c == '"') scanString(t);
        else scanPunct(t, c);
        return t;
    }

    // ------------------------------------------------------------- 数字
    private void scanNumber(Token t) {
        String lexeme;
        if (startsWith("0b") || startsWith("0B")) { t.typ = TokenType.Integer; lexeme = matchRadixInteger(2); }
        else if (startsWith("0o") || startsWith("0O")) { t.typ = TokenType.Integer; lexeme = matchRadixInteger(8); }
        else if (startsWith("0x") || startsWith("0X")) { t.typ = TokenType.Integer; lexeme = matchRadixInteger(16); }
        else if (cur() == '.') {
            t.typ = TokenType.Float;
            pos++; // 先吞掉小数点本身
            String frac = consumeWhile(Lexer::isDigitOrUnderscore);
            lexeme = "." + frac;
            String exp = scanExponent();
            lexeme += exp;
        } else {
            t.typ = TokenType.Integer;
            lexeme = consumeWhile(Lexer::isDigitOrUnderscore);
            if (!eof() && cur() == '.') {
                t.typ = TokenType.Float;
                pos++; // 先吞掉小数点本身
                String frac = consumeWhile(Lexer::isDigitOrUnderscore);
                lexeme += "." + frac;
            }
            String exp = scanExponent();
            if (!exp.isEmpty()) t.typ = TokenType.Float;
            lexeme += exp;
        }
        t.lexeme = lexeme;
        t.parsed = lexeme.replace("_", "");
        getNumberValue(t);
    }

    private String scanExponent() {
        if (eof() || (cur() != 'e' && cur() != 'E')) return "";
        int start = pos;
        pos++;
        if (!eof() && (cur() == '+' || cur() == '-')) pos++;
        while (!eof() && isDigit(cur())) pos++;
        return input.substring(start, pos);
    }

    private String matchRadixInteger(int base) {
        String prefix = input.substring(pos, pos + 2);
        pos += 2;
        int start = pos;
        while (!eof() && (cur() == '_' || isDigitsFor(cur(), base))) pos++;
        return prefix + input.substring(start, pos);
    }

    @FunctionalInterface
    private interface CharPred { boolean test(char c); }
    private String consumeWhile(CharPred pred) {
        int start = pos;
        while (!eof() && pred.test(cur())) pos++;
        return input.substring(start, pos);
    }

    private void getNumberValue(Token t) {
        if (t.typ == TokenType.Integer) {
            int base = 10, skip = 0;
            if (t.parsed.length() >= 2 && t.parsed.charAt(0) == '0') {
                char b = t.parsed.charAt(1);
                if (b == 'b' || b == 'B') { base = 2; skip = 2; }
                else if (b == 'o' || b == 'O') { base = 8; skip = 2; }
                else if (b == 'x' || b == 'X') { base = 16; skip = 2; }
            }
            String digits = t.parsed.substring(skip);
            if (digits.isEmpty()) { addError("invalid integer. "); t.typ = TokenType.Invalid; return; }
            for (int i = 0; i < digits.length(); i++) {
                if (!isDigitsFor(digits.charAt(i), base)) { addError("invalid integer. "); t.typ = TokenType.Invalid; return; }
            }
            try {
                long v = Long.parseUnsignedLong(digits, base);
                if (Long.compareUnsigned(v, Long.MAX_VALUE) > 0) { addError("invalid integer. "); t.typ = TokenType.Invalid; return; }
                t.value = v;
            } catch (NumberFormatException e) {
                addError("invalid integer. "); t.typ = TokenType.Invalid;
            }
        } else if (t.typ == TokenType.Float) {
            if (!validFloat(t.parsed)) { addError("invalid float. "); t.typ = TokenType.Invalid; return; }
            try {
                double v = Double.parseDouble(t.parsed);
                if (Double.isInfinite(v) || Double.isNaN(v) || (v == 0.0 && hasNonZeroDigit(t.parsed))) {
                    addError("invalid float. "); t.typ = TokenType.Invalid; return;
                }
                t.value = v;
            } catch (NumberFormatException e) {
                addError("invalid float. "); t.typ = TokenType.Invalid;
            }
        }
    }

    // ------------------------------------------------------------- BinArr / String
    private void scanBinArr(Token t) {
        t.typ = TokenType.BinArr;
        pos++; // 跳过 '
        int start = pos;
        while (!eof() && cur() != '\'') { if (cur() == '\n') line++; pos++; }
        String body = input.substring(start, pos);
        t.lexeme = body;
        if (eof()) { addError("unclosed binary array. "); t.typ = TokenType.Invalid; return; }
        pos++; // 跳过结尾 '
    }

    private void scanString(Token t) {
        t.typ = TokenType.String;
        pos++; // 跳过 "
        int start = pos;
        while (!eof()) {
            char c = cur();
            if (c == '"') break;
            if (c == '\\') { if (pos + 1 >= input.length()) break; pos += 2; }
            else pos++;
        }
        String body = input.substring(start, pos);
        for (int i = 0; i < body.length(); i++) if (body.charAt(i) == '\n') line++;
        t.lexeme = body;
        if (eof() || cur() != '"') {
            addError("unclosed string literal. ");
            t.typ = TokenType.Invalid;
            pos = input.length();
            return;
        }
        pos++; // 跳过结尾 "
        t.parsed = escapeString(body);
    }

    private String escapeString(String body) {
        StringBuilder out = new StringBuilder(body.length());
        int i = 0;
        while (i < body.length()) {
            char ch = body.charAt(i);
            if (ch == '\\') {
                i++;
                if (i >= body.length()) { addError("invalid escape character. "); break; }
                if (body.charAt(i) == 'u') {
                    if (i + 4 >= body.length() || !allHex(body, i + 1, 4)) {
                        addError("invalid escape character. "); break;
                    }
                    int cp = Integer.parseInt(body.substring(i + 1, i + 5), 16);
                    out.append((char) cp); // Java char 天然是 UTF-16 码元，代理项也合法
                    i += 5;
                    continue;
                }
                char mapped = switch (body.charAt(i)) {
                    case '\\' -> '\\'; case '\'' -> '\''; case '"' -> '"';
                    case 'b' -> 0x08; case 'r' -> '\r'; case 't' -> '\t';
                    case 'v' -> 0x0b; case 'n' -> '\n'; case 'f' -> 0x0c;
                    default -> 0;
                };
                char e = body.charAt(i);
                if (e == '\\' || e == '\'' || e == '"' || e == 'b' || e == 'r' || e == 't'
                    || e == 'v' || e == 'n' || e == 'f') {
                    out.append(mapped); i++;
                } else { addError("invalid escape character. "); break; }
            } else { out.append(ch); i++; }
        }
        return out.toString();
    }

    // ------------------------------------------------------------- 标识符 / 标点
    private void scanIdent(Token t) {
        t.typ = TokenType.Ident;
        StringBuilder parsed = new StringBuilder();
        StringBuilder src = new StringBuilder();
        String head = consumeWhile(Lexer::isIdentChar);
        parsed.append(head); src.append(head);
        while (true) {
            String skipped = skipWsReturning();
            src.append(skipped);
            if (eof() || cur() != ':') break;
            src.append(':'); parsed.append(':'); pos++;
            String skipped2 = skipWsReturning();
            src.append(skipped2);
            if (eof() || !isIdentBegin(cur())) {
                addError("unclosed identifier. "); t.typ = TokenType.Invalid; break;
            }
            String seg = consumeWhile(Lexer::isIdentChar);
            src.append(seg); parsed.append(seg);
        }
        t.lexeme = src.toString();
        t.parsed = parsed.toString();
    }

    private void analyzeIdent(Token t) {
        if (t.typ == TokenType.Invalid) return;
        Integer kw = KEYWORDS.get(t.parsed);
        if (kw != null) { t.typ = kw; return; }
        if (custom != null && custom.contains(t.parsed)) { t.typ = TokenType.Custom; return; }
        t.typ = TokenType.Ident;
    }

    private void scanPunct(Token t, char c) {
        if (!eof() && pos + 1 < input.length()) {
            String two = input.substring(pos, pos + 2);
            Integer typ = switch (two) {
                case "==" -> TokenType.EQ; case "!=" -> TokenType.NE;
                case "<=" -> TokenType.LE; case ">=" -> TokenType.GE;
                case "&&" -> TokenType.And; case "||" -> TokenType.Or;
                default -> null;
            };
            if (typ != null) { t.typ = typ; t.lexeme = two; pos += 2; return; }
        }
        int one = switch (c) {
            case ',' -> TokenType.Comma; case ';' -> TokenType.Semi;
            case '(' -> TokenType.LParen; case ')' -> TokenType.RParen;
            case '[' -> TokenType.LBrack; case ']' -> TokenType.RBrack;
            case '{' -> TokenType.LBrace; case '}' -> TokenType.RBrace;
            case '+' -> TokenType.Add; case '-' -> TokenType.Sub; case '*' -> TokenType.Mul;
            case '/' -> TokenType.Div; case '%' -> TokenType.Mod; case '^' -> TokenType.Pow;
            case '=' -> TokenType.Assign; case '!' -> TokenType.Not;
            case '<' -> TokenType.LT; case '>' -> TokenType.GT;
            default -> -1;
        };
        t.typ = one < 0 ? TokenType.Invalid : one;
        t.lexeme = String.valueOf(c);
        pos++;
        if (one < 0) addError("unknown token. ");
    }

    // ------------------------------------------------------------- 空白 / 注释
    private void skipWs() {
        while (!eof()) {
            char c = cur();
            if (isWhite(c)) { if (c == '\n') line++; pos++; }
            else if (startsWith("//")) {
                int nl = input.indexOf('\n', pos);
                if (nl < 0) pos = input.length();
                else { pos = nl + 1; line++; }
            } else if (startsWith("/*")) { skipMultilineComment(); }
            else break;
        }
    }

    private String skipWsReturning() {
        int start = pos;
        skipWs();
        return input.substring(start, pos);
    }

    private void skipMultilineComment() {
        pos += 2; // 跳过 /*
        while (!eof()) {
            if (startsWith("*/")) { pos += 2; break; }
            if (cur() == '\n') line++;
            pos++;
        }
    }

    // ------------------------------------------------------------- 工具函数
    private static boolean allHex(String s, int start, int n) {
        for (int i = start; i < start + n; i++) if (!isHex(s.charAt(i))) return false;
        return true;
    }
    private static boolean hasNonZeroDigit(String s) {
        for (int i = 0; i < s.length(); i++) { char c = s.charAt(i); if (c >= '1' && c <= '9') return true; }
        return false;
    }
    private static boolean validFloat(String s) {
        if (s.isEmpty()) return false;
        int i = 0, intDigits = 0;
        while (i < s.length() && isDigit(s.charAt(i))) { i++; intDigits++; }
        int fracDigits = 0;
        if (i < s.length() && s.charAt(i) == '.') {
            i++;
            while (i < s.length() && isDigit(s.charAt(i))) { i++; fracDigits++; }
        }
        if (intDigits == 0 && fracDigits == 0) return false;
        if (intDigits == 0 && s.charAt(0) != '.') return false;
        if (i < s.length() && (s.charAt(i) == 'e' || s.charAt(i) == 'E')) {
            i++;
            if (i < s.length() && (s.charAt(i) == '+' || s.charAt(i) == '-')) i++;
            int start = i;
            while (i < s.length() && isDigit(s.charAt(i))) i++;
            if (i == start) return false;
        }
        return i == s.length();
    }
}
