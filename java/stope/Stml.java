package stope;

import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/** STML 公共类型：Token / Element（对齐 python/stope/stml.py）。元素模型只有 6 字段。 */
public final class Stml {
    private Stml() {}

    public static final int
        Invalid = 0, Eof = 1, LAngle = 2, RAngle = 3, CLAngle = 4, CRAngle = 5,
        EQ = 6, Word = 7, String = 8, Text = 9, NevextSrc = 10, StopeSrc = 11;
    private static final String[] NAMES = {
        "Invalid", "Eof", "LAngle", "RAngle", "CLAngle", "CRAngle",
        "EQ", "Word", "String", "Text", "NevextSrc", "StopeSrc"
    };
    public static String typeName(int t) { return NAMES[t]; }

    public enum LexerState { Xml, Text, Nevext, Stope }

    public static final class Token {
        public int typ = Invalid;
        public int line = -1;
        public String lexeme = "";
    }

    public static final class Element {
        public int line = -1;
        public int textLine = -1;
        public String tag = "";
        public final Map<String, String> attrs = new LinkedHashMap<>();
        public boolean selfClosing = false;
        public final List<Element> children = new ArrayList<>();
        public String text = "";
    }
}
