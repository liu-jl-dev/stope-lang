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
  PushValue,   // 8
  PushId,      // 9

  Call,   // 10
  At,     // 11
  Pop,    // 12
  Minus,  // 13
  Not,    // 14
  Pow,    // 15
  Mul,    // 16
  Div,    // 17
  IDiv,   // 18
  Mod,    // 19

  Add,   // 20
  Sub,   // 21
  EQ,    // 22
  NE,    // 23
  LT,    // 24
  LE,    // 25
  GT,    // 26
  GE,    // 27
  If,    // 28
  GoTo,  // 29

  GetArg,  // 30
  ArgNum,  // 31
  Return,  // 32
};  // 共 33 个

}  // namespace Stope
