package stope;

/** 二进制数组字面量【内容】的解析。无前缀按 16；b/o/d/x 切进制；
 *  段内可含下划线；超 0xFF 静默截断。 */
public final class BinArrParser {
    private static final int INT_MAX = 2147483647;
    private static final String WS = " \t\n\r\u000b\u000c";

    private static boolean isWs(char c) { return WS.indexOf(c) >= 0; }
    private static int digitOf(char c, int base) {
        int d = (c >= '0' && c <= '9') ? c - '0'
              : (c >= 'a' && c <= 'f') ? c - 'a' + 10
              : (c >= 'A' && c <= 'F') ? c - 'A' + 10 : -1;
        return (d >= 0 && d < base) ? d : -1;
    }

    /** 成功返回字节字符串（每个 char 是一个字节 0..255）；失败返回 null。 */
    public static String parse(String src) {
        StringBuilder out = new StringBuilder();
        int pos = 0;
        while (pos < src.length() && isWs(src.charAt(pos))) pos++;
        if (pos >= src.length()) return out.toString(); // 空内容合法
        int base = 16;
        char c = src.charAt(pos);
        if (c == 'b' || c == 'B') { base = 2; pos++; }
        else if (c == 'o' || c == 'O') { base = 8; pos++; }
        else if (c == 'd' || c == 'D') { base = 10; pos++; }
        else if (c == 'x' || c == 'X') { base = 16; pos++; }
        while (pos < src.length() && isWs(src.charAt(pos))) pos++;
        while (pos < src.length()) {
            long n = 0;
            boolean anyDigit = false;
            while (pos < src.length() && !isWs(src.charAt(pos))) {
                char ch = src.charAt(pos);
                int d = digitOf(ch, base);
                if (d >= 0) {
                    if (n > (INT_MAX - d) / base) return null;
                    n = n * base + d;
                    pos++;
                    anyDigit = true;
                } else if (ch == '_') pos++;
                else { pos++; return null; }
            }
            if (!anyDigit) return null;
            out.append((char) (n & 0xff));
            while (pos < src.length() && isWs(src.charAt(pos))) pos++;
        }
        return out.toString();
    }

    private BinArrParser() {}
}
