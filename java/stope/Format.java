package stope;

/** printf("%g") 的忠实实现（库内共用，对齐 C++ 的 fmt_g）。
 *  Java 的 String.format("%g") 是固定 6 位小数，不符，故自写。 */
public final class Format {
    private Format() {}

    public static String fmtG(double v) {
        if (Double.isNaN(v)) return "nan";
        if (Double.isInfinite(v)) return v < 0 ? "-inf" : "inf";
        if (v == 0.0) return (Double.doubleToRawLongBits(v) < 0) ? "-0" : "0";

        String es = String.format(java.util.Locale.ROOT, "%e", v);
        int epos = es.lastIndexOf('e');
        String mant = es.substring(0, epos);
        int exponent = Integer.parseInt(es.substring(epos + 1));

        StringBuilder digits = new StringBuilder();
        boolean neg = false;
        int mi = 0;
        if (mant.length() > 0 && mant.charAt(0) == '-') { neg = true; mi = 1; }
        for (; mi < mant.length() && digits.length() < 6; mi++) {
            char c = mant.charAt(mi);
            if (c != '.') digits.append(c);
        }
        while (digits.length() > 1 && digits.charAt(digits.length() - 1) == '0')
            digits.deleteCharAt(digits.length() - 1);

        StringBuilder out = new StringBuilder();
        if (neg) out.append('-');
        if (exponent < -4 || exponent >= 6) {
            out.append(digits.charAt(0));
            if (digits.length() > 1) { out.append('.'); out.append(digits, 1, digits.length()); }
            out.append('e').append(exponent >= 0 ? '+' : '-');
            int ae = Math.abs(exponent);
            if (ae < 10) out.append('0');
            out.append(ae);
        } else {
            int point = exponent + 1;
            if (point <= 0) {
                out.append("0.");
                for (int z = 0; z < -point; z++) out.append('0');
                out.append(digits);
            } else if (point >= digits.length()) {
                out.append(digits);
                for (int z = digits.length(); z < point; z++) out.append('0');
            } else {
                out.append(digits, 0, point).append('.').append(digits, point, digits.length());
            }
        }
        return out.toString();
    }
}
