// 程序 = 指令流 + 常量池 + 变量表 —— 对应 cpp/include/stope/program.hpp。
//
// 字段名取 C++ 的 camelCase 形式，容器都给默认空值：`new Program()` 拿到的就是
// 可直接编译 / 执行的空程序（与 C++ 的 Program 默认构造一致）。
//
// 常量池的元素类型：intConsts 是 BigInt（与 lexer / AST 一致），floatConsts 是 Number，
// stringConsts 是字符串，binArrConsts 是 Uint8Array。
class Program {
  constructor() {
    this.opcodes = [] // 指令与操作数混排；元素是普通 number（int16 范围内）
    this.variableNum = 0 // 变量数量
    this.exports = new Map() // 导出变量名 -> 槽位
    this.intConsts = []
    this.floatConsts = []
    this.stringConsts = []
    this.binArrConsts = []
    this.maxReturnNum = 0 // return 语句最大返回值数量
    this.requiredStackSize = 0
  }

  // 序列化成普通对象（对应 GD 的 to_map）。BigInt 转成字符串，JSON 才不报错；
  // 键名与 GDScript 侧完全一致，方便两侧跑同一套比对脚本。
  toMap() {
    return {
      c: this.opcodes.slice(),
      i: this.intConsts.map(String),
      f: this.floatConsts.slice(),
      s: this.stringConsts.slice(),
      ba: this.binArrConsts.map((b) => Array.from(b)),
      vn: this.variableNum,
      e: Object.fromEntries(this.exports),
      sc: this.requiredStackSize,
      mr: this.maxReturnNum,
    }
  }

  toJsonString() {
    return JSON.stringify(this.toMap())
  }
}

// 清空成「刚构造」的状态（编译器在每次 Compile 开头调用）
function clearProgram(p) {
  p.opcodes.length = 0
  p.intConsts.length = 0
  p.floatConsts.length = 0
  p.binArrConsts.length = 0
  p.stringConsts.length = 0
  p.exports.clear()
  p.variableNum = 0
  p.maxReturnNum = 0
  p.requiredStackSize = 0
}

export { Program, clearProgram }
