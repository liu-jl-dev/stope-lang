package stope;

import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/** 编译产物 Program：指令流 + 常量池 + 变量表（对齐 cpp/include/stope/program.hpp）。
 *  opcodes 存 int（低 16 位是指令编号，自定义指令编号可超 32）。 */
public final class Program {
    public final List<Integer> opcodes = new ArrayList<>();
    public int variableNum = 0;
    public final Map<String, Integer> exports = new LinkedHashMap<>();
    public final List<Long> intConsts = new ArrayList<>();
    public final List<Double> floatConsts = new ArrayList<>();
    public final List<String> stringConsts = new ArrayList<>();
    public final List<String> binarrConsts = new ArrayList<>();
    public int maxReturnNum = 0;
    public int requiredStackSize = 0;

    public void clear() {
        opcodes.clear(); intConsts.clear(); floatConsts.clear();
        stringConsts.clear(); binarrConsts.clear(); exports.clear();
        variableNum = 0; maxReturnNum = 0; requiredStackSize = 0;
    }
}
