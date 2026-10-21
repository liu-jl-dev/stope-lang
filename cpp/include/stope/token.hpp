#pragma once
#include <string>
#include <string_view>

namespace Stope {
enum class TokenType {
  Invalid,  // 无效
  Eof,      // 输入结尾
  Ident,    // 标识符
  Integer,  // 整数
  Float,    // 浮点数
  String,   // "..."
  BinArr,   // '...'
  Comma,    // ,
  Semi,     // ;
  LParen,   // (

  RParen,  // )
  LBrack,  // [
  RBrack,  // ]
  LBrace,  // {
  RBrace,  // }
  Assign,  // =
  Add,     // +
  Sub,     // -
  Mul,     // *
  Div,     // /

  IDiv,  // idiv
  Mod,   // %
  Pow,   // ^
  EQ,    // ==
  NE,    // !=
  LT,    // <
  LE,    // <=
  GT,    // >
  GE,    // >=
  Not,   // ! not

  And,       // && and
  Or,        // || or
  If,        // if
  Elif,      // elif
  Else,      // else
  Let,       // let
  Return,    // return
  While,     // while
  Break,     // break
  Continue,  // continue

  Null,    // null
  False,   // false
  True,    // true
  Args,    // args
  Argc,    // argc
  Export,  // export
  Custom,  // 自定义指令
};  // 共 47 个

union NumberValue {
  long long integer;
  double floating;
};

struct Token {
  TokenType type;
  int line;
  std::u16string_view lexeme;
  std::u16string parsed;
  NumberValue numberValue;
};

}  // namespace Stope
