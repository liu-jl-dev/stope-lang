var TokenType = {}
TokenType[TokenType["Invalid"] = 0] = "Invalid"    // 无效
TokenType[TokenType["Eof"] = 1] = "Eof"            // 输入结尾
TokenType[TokenType["Ident"] = 2] = "Ident"        // 标识符
TokenType[TokenType["Integer"] = 3] = "Integer"    // 整数
TokenType[TokenType["Float"] = 4] = "Float"        // 浮点数
TokenType[TokenType["String"] = 5] = "String"      // "..."
TokenType[TokenType["BinArr"] = 6] = "BinArr"      // '...'
TokenType[TokenType["Comma"] = 7] = "Comma"        // ,
TokenType[TokenType["Semi"] = 8] = "Semi"          // ;
TokenType[TokenType["LParen"] = 9] = "LParen"      // (

TokenType[TokenType["RParen"] = 10] = "RParen"     // )
TokenType[TokenType["LBrack"] = 11] = "LBrack"     // [
TokenType[TokenType["RBrack"] = 12] = "RBrack"     // ]
TokenType[TokenType["LBrace"] = 13] = "LBrace"     // {
TokenType[TokenType["RBrace"] = 14] = "RBrace"     // }
TokenType[TokenType["Assign"] = 15] = "Assign"     // =
TokenType[TokenType["Add"] = 16] = "Add"           // +
TokenType[TokenType["Sub"] = 17] = "Sub"           // -
TokenType[TokenType["Mul"] = 18] = "Mul"           // *
TokenType[TokenType["Div"] = 19] = "Div"           // /

TokenType[TokenType["IDiv"] = 20] = "IDiv"         // idiv
TokenType[TokenType["Mod"] = 21] = "Mod"           // %
TokenType[TokenType["Pow"] = 22] = "Pow"           // ^
TokenType[TokenType["EQ"] = 23] = "EQ"             // ==
TokenType[TokenType["NE"] = 24] = "NE"             // !=
TokenType[TokenType["LT"] = 25] = "LT"             // <
TokenType[TokenType["LE"] = 26] = "LE"             // <=
TokenType[TokenType["GT"] = 27] = "GT"             // >
TokenType[TokenType["GE"] = 28] = "GE"             // >=
TokenType[TokenType["Not"] = 29] = "Not"           // ! not

TokenType[TokenType["And"] = 30] = "And"           // && and
TokenType[TokenType["Or"] = 31] = "Or"             // || or
TokenType[TokenType["If"] = 32] = "If"             // if
TokenType[TokenType["Elif"] = 33] = "Elif"         // elif
TokenType[TokenType["Else"] = 34] = "Else"         // else
TokenType[TokenType["Let"] = 35] = "Let"           // let
TokenType[TokenType["Return"] = 36] = "Return"     // return
TokenType[TokenType["While"] = 37] = "While"       // while
TokenType[TokenType["Break"] = 38] = "Break"       // break
TokenType[TokenType["Continue"] = 39] = "Continue" // continue

TokenType[TokenType["Null"] = 40] = "Null"         // null
TokenType[TokenType["False"] = 41] = "False"       // false
TokenType[TokenType["True"] = 42] = "True"         // true
TokenType[TokenType["Args"] = 43] = "Args"         // args
TokenType[TokenType["Argc"] = 44] = "Argc"         // argc
TokenType[TokenType["Export"] = 45] = "Export"     // export
TokenType[TokenType["Custom"] = 46] = "Custom"     // 自定义指令

Object.freeze(TokenType)

class Token {
  constructor(line, type) {
    this.line = line
    this.type = type
  }
}

export {
  TokenType,
  Token,
}