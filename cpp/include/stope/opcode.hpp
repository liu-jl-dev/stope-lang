#pragma once

namespace Stope {
enum class Opcode : unsigned short {
  Assign,      // 0
  PushNull,    // 1
  PushFalse,   // 2
  PushTrue,    // 3
  PushInt,     // 4
  PushFloat,   // 5
  PushString,  // 6
  PushBinArr,  // 7
  PushId,      // 8
  Call,        // 9

  At,     // 10
  Pop,    // 11
  Minus,  // 12
  Not,    // 13
  Pow,    // 14
  Mul,    // 15
  Div,    // 16
  IDiv,   // 17
  Mod,    // 18
  Add,    // 19

  Sub,     // 20
  EQ,      // 21
  NE,      // 22
  LT,      // 23
  LE,      // 24
  GT,      // 25
  GE,      // 26
  If,      // 27
  GoTo,    // 28
  GetArg,  // 29

  ArgNum,  // 30
  Return,  // 31
};  // 共 32 个

}  // namespace Stope
