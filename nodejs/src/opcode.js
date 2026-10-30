import { Result } from './common.js'

var Opcode = {}
Opcode[Opcode["Assign"] = 0] = "Assign"
Opcode[Opcode["PushNull"] = 1] = "PushNull"
Opcode[Opcode["PushFalse"] = 2] = "PushFalse"
Opcode[Opcode["PushTrue"] = 3] = "PushTrue"
Opcode[Opcode["PushInt"] = 4] = "PushInt"
Opcode[Opcode["PushFloat"] = 5] = "PushFloat"
Opcode[Opcode["PushString"] = 6] = "PushString"
Opcode[Opcode["PushBinArr"] = 7] = "PushBinArr"
Opcode[Opcode["PushValue"] = 8] = "PushValue"
Opcode[Opcode["PushId"] = 9] = "PushId"

Opcode[Opcode["Call"] = 10] = "Call"
Opcode[Opcode["At"] = 11] = "At"
Opcode[Opcode["Pop"] = 12] = "Pop"
Opcode[Opcode["Minus"] = 13] = "Minus"
Opcode[Opcode["Not"] = 14] = "Not"
Opcode[Opcode["Pow"] = 15] = "Pow"
Opcode[Opcode["Mul"] = 16] = "Mul"
Opcode[Opcode["Div"] = 17] = "Div"
Opcode[Opcode["IDiv"] = 18] = "IDiv"
Opcode[Opcode["Mod"] = 19] = "Mod"

Opcode[Opcode["Add"] = 20] = "Add"
Opcode[Opcode["Sub"] = 21] = "Sub"
Opcode[Opcode["EQ"] = 22] = "EQ"
Opcode[Opcode["NE"] = 23] = "NE"
Opcode[Opcode["LT"] = 24] = "LT"
Opcode[Opcode["LE"] = 25] = "LE"
Opcode[Opcode["GT"] = 26] = "GT"
Opcode[Opcode["GE"] = 27] = "GE"
Opcode[Opcode["If"] = 28] = "If"
Opcode[Opcode["GoTo"] = 29] = "GoTo"

Opcode[Opcode["GetArg"] = 30] = "GetArg"
Opcode[Opcode["ArgNum"] = 31] = "ArgNum"
Opcode[Opcode["Return"] = 32] = "Return"

Object.freeze(Opcode)

const kFirstCustomOpcode = Opcode.Return + 1 // 33

class CustomOpcode {
  constructor(opcode, argNum = -1) {
    this.opcode = opcode
    this.isVarArg = argNum < 0
    this.argNum = argNum
  }
}

// 名字 → CustomOpcode 的登记表。Lexer / Parser / Compiler 要共用同一份对象，
// 各建一份会出现「编译期找不到指令」或「退化成普通函数调用」。
//
// 名字是普通标识符或命名空间形式 a:b（词法器保证），且关键字优先 ——
// 注册一个叫 if 的指令是无效的，if 永远按关键字处理。
class CustomOpcodeConfig {
  constructor() {
    this.opcodes = new Map()
  }
  // argNum 默认 -1（变长）。同名重复注册返回 DuplicateWithBuiltinOpcode。
  // 与 C++ 一样不校验编号范围，编号请从 kFirstCustomOpcode 开始。
  addCustomOpcode(name, opcode, argNum = -1) {
    if (this.opcodes.has(name)) {
      return Result.DuplicateWithBuiltinOpcode
    }
    this.opcodes.set(name, new CustomOpcode(opcode, argNum))
    return Result.Success
  }
}

export { Opcode, CustomOpcode, CustomOpcodeConfig, kFirstCustomOpcode }