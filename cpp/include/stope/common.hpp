#pragma once

namespace Stope {
enum Result {
  Success,
  Error,
  UnknownError,
  DuplicateWithBuiltinOpcode,
};
enum class OpPrecedence : int {
  Lowest,
  Or,           // or ||
  And,          // and &&
  Equals,       // == !=
  LessGreater,  // < <= > >=
  AddSub,       // + -
  MulDiv,       // * / idiv %
  Pow,          // ^
  Prefix,       // - ! not
  Paren,        // () []  包括括号、Call、At
};
}  // namespace Stope
