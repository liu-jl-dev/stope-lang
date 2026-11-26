package stope;

/** Lexeme 是原文片段；parsed 是「语义形态」（数字去下划线、标识符拼好冒号、字符串反转义后）。 */
public final class Token {
    public int line = 1;
    public int typ = TokenType.Eof;
    public String lexeme = "";
    public String parsed = "";
    /** 只对整数/浮点有意义：Long 或 Double。 */
    public Object value = null;

    public Token() {}
}
