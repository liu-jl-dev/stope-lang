#include <stope/ast.hpp>

namespace Stope {

const std::map<TokenType, OpPrecedence>& binopPrecMap() {
  static const std::map<TokenType, OpPrecedence> map{
      {TokenType::Or, OpPrecedence::Or},
      {TokenType::And, OpPrecedence::And},
      {TokenType::EQ, OpPrecedence::Equals},
      {TokenType::NE, OpPrecedence::Equals},

      {TokenType::LT, OpPrecedence::LessGreater},
      {TokenType::LE, OpPrecedence::LessGreater},
      {TokenType::GT, OpPrecedence::LessGreater},
      {TokenType::GE, OpPrecedence::LessGreater},

      {TokenType::Add, OpPrecedence::AddSub},
      {TokenType::Sub, OpPrecedence::AddSub},

      {TokenType::Mul, OpPrecedence::MulDiv},
      {TokenType::Div, OpPrecedence::MulDiv},
      {TokenType::IDiv, OpPrecedence::MulDiv},
      {TokenType::Mod, OpPrecedence::MulDiv},

      {TokenType::Pow, OpPrecedence::Pow},

      {TokenType::LParen, OpPrecedence::Paren},
      {TokenType::LBrack, OpPrecedence::Paren},
  };
  return map;
}

}  // namespace Stope
