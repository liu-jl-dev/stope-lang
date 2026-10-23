import { TokenType, Token } from './token.js'

class Lexer {
  constructor(input) {
    Reset(input)
  }
  Reset(input) {
    this.input = input
    this.line = 1
    this.errors = []
  }
}

export { Lexer }