import { TokenType, Token } from './token.js'

class Lexer {
  constructor(input) {
    this.Reset(input)
  }
  Reset(input) {
    this.input = input
    this.line = 1
    this.errors = []
  }
  // custom 形如 { opcodes: {...} } 或 { opcodes: Map }，可省略
  NextToken(custom) {
    this.skipWs()
    let token = new Token(this.line, TokenType.Eof)
    token.lexeme = ''
    token.parsed = ''
    if (this.input.length <= 0) { // 输入结尾，直接返回 Eof
      return token
    }
    const c = this.input[0]
    if (isDigit(c) || c == '.') { // 数字字面量
      this.scanNumber(token)
      this.parseNumber(token)
      this.getNumberValue(token)
    } else if (isIdentBegin(c)) { // 标识符 / 关键字 / 自定义指令
      this.scanIdent(token)
      this.analyzeIdent(token, custom)
    } else if (c == "'") { // '...'
      this.scanBinArr(token)
    } else if (c == '"') { // "..."
      this.scanString(token)
    } else { // 标点
      this.scanPunct(token, c)
    }
    return token
  }

  // private
  // 数字：先按前缀分类，再交给对应的正则
  scanNumber(token) {
    if (this.test('0b') || this.test('0B')) { // ^0[bB][_01]+
      token.type = TokenType.Integer
      token.lexeme = this.matchRadixInteger(reBinInteger)
    } else if (this.test('0o') || this.test('0O')) { // ^0[oO][_0-7]+
      token.type = TokenType.Integer
      token.lexeme = this.matchRadixInteger(reOctInteger)
    } else if (this.test('0x') || this.test('0X')) { // ^0[xX][_0-9a-fA-F]+
      token.type = TokenType.Integer
      token.lexeme = this.matchRadixInteger(reHexInteger)
    } else if (this.input[0] == '.') { // .[_0-9]*([eE][+-]?[0-9]+)?
      token.type = TokenType.Float
      token.lexeme = this.matchAndConsume(reDot) + this.matchAndConsume(reDecDigitsOpt)
      const exp = this.scanExponent()
      if (exp != '') token.type = TokenType.Float
      token.lexeme += exp
    } else { // [_0-9]+(.[_0-9]*)?([eE][+-]?[0-9]+)?
      token.type = TokenType.Integer
      let lexeme = this.matchAndConsume(reDecDigits)
      if (this.input[0] == '.') { // 有小数点就是浮点数
        token.type = TokenType.Float
        lexeme += this.matchAndConsume(reDecFrac)
      }
      const exp = this.scanExponent()
      if (exp != '') token.type = TokenType.Float
      token.lexeme = lexeme + exp
    }
  }
  // ([eE][+-]?[0-9]+)? —— 指数部分；返回 '' 表示没有。
  // 注意 C++ 里数字部分可以为空（"1e" 的 e 也在 lexeme 内），交给 getNumberValue 报错
  scanExponent() {
    if (this.input.length <= 0) return ''
    const c = this.input[0]
    if (c != 'e' && c != 'E') return ''
    return this.matchAndConsume(reDecExp)
  }
  // 取走正则匹配到的文本；不匹配时只取前缀（如 "0b"），让 getNumberValue 报错
  matchRadixInteger(re) {
    const m = re.exec(this.input)
    return this.matchAndConsume(re, m ? m[0] : this.input.slice(0, 2))
  }
  matchAndConsume(re, fallback) {
    const m = re.exec(this.input)
    const text = m ? m[0] : fallback
    this.input = this.input.slice(text.length)
    return text
  }
  // 数字字面量允许下划线分隔，parsed 是去掉下划线后的文本
  parseNumber(token) {
    token.parsed = token.lexeme.replace(/_/g, '')
  }
  // 按 parsed 求数值；不合法（含超出 int64）则报错并把 token 置为 Invalid
  getNumberValue(token) {
    if (token.type == TokenType.Integer) {
      const [base, prefixLen] = numberBase(token.parsed)
      const digits = token.parsed.slice(prefixLen)
      if (!reDigits(base).test(digits)) { // 空或有非法字符，如 "0b"、"0b2"
        this.error('invalid integer. ')
        token.type = TokenType.Invalid
        return
      }
      let value
      try {
        value = BigInt(radixPrefix(base) + digits)
      } catch (e) {
        this.error('invalid integer. ')
        token.type = TokenType.Invalid
        return
      }
      if (value < INT64_MIN || value > INT64_MAX) { // 对齐 C++ stoll 的 out_of_range
        this.error('invalid integer. ')
        token.type = TokenType.Invalid
        return
      }
      // JS 没有 int64：超过 2^53 的整数只能存成 Number，会丢精度（C++ 侧是 long long）
      token.value = value
    } else if (token.type == TokenType.Float) {
      if (!reFloat.test(token.parsed)) { // 如 "1e"、"." —— C++ 用 stod 的 pos 判断
        this.error('invalid float. ')
        token.type = TokenType.Invalid
        return
      }
      const value = Number(token.parsed)
      // C++ 用 stod，上溢与下溢都抛 out_of_range → Invalid；JS 的 Number 不抛，
      // 只能自己判：非有限值（1e999），或者有非零数字却算出 0（1e-999 下溢）
      if (!Number.isFinite(value) || (value == 0 && /[1-9]/.test(token.parsed))) {
        this.error('invalid float. ')
        token.type = TokenType.Invalid
        return
      }
      token.value = value
    }
  }
  // '...' 到下一个 ' 为止，中间可以换行（换行计入 line）
  scanBinArr(token) {
    token.type = TokenType.BinArr
    this.input = this.input.slice(1) // 跳过开头的 '
    const body = this.matchAndConsume(reBinArrBody, '')
    this.line += countNewlines(body)
    if (this.input.length <= 0) { // 没扫到闭合的 '
      this.error('unclosed binary array. ')
      token.type = TokenType.Invalid
      token.lexeme = body
      this.input = ''
      return
    }
    token.lexeme = body
    this.input = this.input.slice(1) // 跳过结尾的 '
  }
  // "..." 里的 \ 会转义后一个字符（含 \"），未闭合则报错
  scanString(token) {
    token.type = TokenType.String
    this.input = this.input.slice(1) // 跳过开头的 "
    const body = this.matchAndConsume(reStringBody, '')
    if (this.input.length <= 0 || this.input[0] != '"') { // 没扫到闭合的 "
      this.error('unclosed string literal. ')
      token.type = TokenType.Invalid
      token.lexeme = body
      this.input = ''
      return
    }
    token.lexeme = body
    this.input = this.input.slice(1) // 跳过结尾的 "
    this.escapeString(token)
  }
  // 处理转义序列；遇到非法转义就报错并停下（已解析的部分保留）
  escapeString(token) {
    let parsed = ''
    let i = 0
    for (; i < token.lexeme.length;) {
      if (token.lexeme[i] == '\\') {
        ++i
        if (i >= token.lexeme.length) { // 末尾一个孤立的 \
          this.error('invalid escape character. ')
          break
        }
        const c = escapeMap.get(token.lexeme[i])
        if (c === undefined) {
          this.error('invalid escape character. ')
          break
        }
        parsed += c
        ++i
      } else {
        parsed += token.lexeme[i]
        ++i
      }
    }
    token.parsed = parsed
  }
  // ^[a-zA-Z_][a-zA-Z0-9_]*(:[a-zA-Z_][a-zA-Z0-9_]*)* ，冒号两侧允许空白与注释
  scanIdent(token) {
    token.type = TokenType.Ident
    let src = ''
    let parsed = this.matchAndConsume(reIdentHead)
    src += parsed
    for (;;) {
      src += this.skipWsReturningSkipped() // 冒号之前的空白与注释
      if (this.input.length <= 0 || this.input[0] != ':') {
        break
      }
      src += ':'
      parsed += ':'
      this.input = this.input.slice(1)
      src += this.skipWsReturningSkipped() // 冒号之后的空白与注释
      const seg = reIdentHead.exec(this.input)
      if (!seg) { // 冒号后面不是标识符
        this.error('unclosed identifier. ')
        token.type = TokenType.Invalid
        break
      }
      src += seg[0]
      parsed += seg[0]
      this.input = this.input.slice(seg[0].length)
    }
    token.lexeme = src
    token.parsed = parsed
  }
  // 关键字 > 自定义指令 > 标识符
  analyzeIdent(token, custom) {
    if (token.type == TokenType.Invalid) {
      return
    }
    const kw = keywords.get(token.parsed)
    if (kw !== undefined) {
      token.type = kw
    } else if (custom && hasKey(custom.opcodes, token.parsed)) {
      token.type = TokenType.Custom
    } else {
      token.type = TokenType.Ident
    }
  }
  // 先按两字符查表（== != <= >= && ||），再按单字符查表
  scanPunct(token, c) {
    const two = twoCharOps.get(this.input.slice(0, 2))
    if (two !== undefined) {
      token.type = two
      token.lexeme = this.input.slice(0, 2)
      this.input = this.input.slice(2)
      return
    }
    const one = oneCharOps.get(c)
    token.type = one === undefined ? TokenType.Invalid : one
    token.lexeme = c
    this.input = this.input.slice(1)
    if (one === undefined) {
      this.error('unknown token. ')
    }
  }
  test(prefix) {
    return this.input.startsWith(prefix)
  }
  skipWs() {
    for (; this.input.length > 0;) {
      if (isWhiteChar(this.input[0])) {
        if (this.input[0] == '\n') ++this.line
        this.input = this.input.slice(1)
      } else if (this.test('//')) { // 单行注释
        const pos = this.input.indexOf('\n')
        if (pos < 0) { // 直接到字符串结尾
          this.input = ''
        } else { // 还有新行
          this.input = this.input.slice(pos + 1)
          ++this.line
        }
      } else if (this.test('/*')) { // 多行注释
        this.skipMultilineComment()
      } else {
        break
      }
    }
  }
  // 与 skipWs 相同，但返回被跳过的原文（标识符的 ':' 两侧要把它记进 lexeme）
  skipWsReturningSkipped() {
    const before = this.input
    this.skipWs()
    return before.slice(0, before.length - this.input.length)
  }
  skipMultilineComment() {
    this.input = this.input.slice(2) // 跳过 /*
    for (; this.input.length > 0;) {
      if (this.test('*/')) {
        this.input = this.input.slice(2)
        break
      }
      if (this.input[0] == '\n') ++this.line
      this.input = this.input.slice(1)
    }
  }
  error(msg) {
    this.errors.push('line ' + this.line + ': ' + msg)
  }
}

const isWhiteChar = (c) => {
  return c == ' ' || c == '\t' || c == '\r' || c == '\n' || c == '\v' || c == '\f'
}
const isDigit = (c) => {
  return c >= '0' && c <= '9'
}
const isAlpha = (c) => {
  return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
}
const isIdentBegin = (c) => {
  return isAlpha(c) || c == '_'
}
const countNewlines = (s) => {
  return (s.match(/\n/g) || []).length
}
// 容器可能是 Map 也可能是普通对象（普通对象要防原型链上的同名键）
const hasKey = (collection, key) => {
  if (!collection) return false
  return collection instanceof Map
    ? collection.has(key)
    : Object.prototype.hasOwnProperty.call(collection, key)
}
// 按字面量前缀决定基数，并给出前缀长度（调用方跳过前缀后再转换）
const numberBase = (s) => {
  if (s.length >= 2 && s[0] == '0') {
    if (s[1] == 'b' || s[1] == 'B') return [2, 2]
    if (s[1] == 'o' || s[1] == 'O') return [8, 2]
    if (s[1] == 'x' || s[1] == 'X') return [16, 2]
  }
  return [10, 0]
}
// BigInt 只认 0b / 0o / 0x 前缀，十进制不加前缀
const radixPrefix = (base) => {
  if (base == 2) return '0b'
  if (base == 8) return '0o'
  if (base == 16) return '0x'
  return ''
}
// 某基数下的合法数字串：先判断基数，再取对应的正则
const reDigits = (base) => {
  if (base == 2) return /^[01]+$/
  if (base == 8) return /^[0-7]+$/
  if (base == 16) return /^[0-9a-fA-F]+$/
  return /^[0-9]+$/
}

const reBinInteger = /^0[bB][_01]+/
const reOctInteger = /^0[oO][_0-7]+/
const reHexInteger = /^0[xX][_0-9a-fA-F]+/
const reDot = /^\./
const reDecDigits = /^[_0-9]+/ // 整数部分，至少一位
const reDecDigitsOpt = /^[_0-9]*/ // 小数点之后的数字，可以没有
const reDecFrac = /^\.[_0-9]*/ // 小数点 + 数字
const reDecExp = /^[eE][+-]?[0-9]*/ // 指数部分（数字可以没有，如 "1e"）
// 浮点数（parsed，已去掉下划线）：整数部分允许省略，指数部分必须完整
const reFloat = /^(?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+)(?:[eE][+-]?[0-9]+)?$/
const reIdentHead = /^[a-zA-Z_][a-zA-Z0-9_]*/
// 字符串主体：普通字符或转义对，遇到单独的 " 或单独的 \ 停下
const reStringBody = /^(?:[^"\\]|\\[\s\S])*/
const reBinArrBody = /^[^']*/

const INT64_MIN = -(2n ** 63n)
const INT64_MAX = 2n ** 63n - 1n

const escapeMap = new Map([
  ['\\', '\\'], ["'", "'"], ['"', '"'],
  ['b', '\b'], ['r', '\r'], ['t', '\t'],
  ['v', '\v'], ['n', '\n'], ['f', '\f'],
])

const keywords = new Map([
  ['idiv', TokenType.IDiv], ['not', TokenType.Not],
  ['and', TokenType.And], ['or', TokenType.Or],
  ['if', TokenType.If], ['elif', TokenType.Elif],
  ['else', TokenType.Else], ['let', TokenType.Let],
  ['return', TokenType.Return], ['while', TokenType.While],
  ['break', TokenType.Break], ['continue', TokenType.Continue],
  ['null', TokenType.Null], ['false', TokenType.False],
  ['true', TokenType.True], ['args', TokenType.Args],
  ['argc', TokenType.Argc], ['export', TokenType.Export],
])

const twoCharOps = new Map([
  ['==', TokenType.EQ], ['!=', TokenType.NE],
  ['<=', TokenType.LE], ['>=', TokenType.GE],
  ['&&', TokenType.And], ['||', TokenType.Or],
])

const oneCharOps = new Map([
  [',', TokenType.Comma], [';', TokenType.Semi],
  ['(', TokenType.LParen], [')', TokenType.RParen],
  ['[', TokenType.LBrack], [']', TokenType.RBrack],
  ['{', TokenType.LBrace], ['}', TokenType.RBrace],
  ['+', TokenType.Add], ['-', TokenType.Sub],
  ['*', TokenType.Mul], ['/', TokenType.Div],
  ['%', TokenType.Mod], ['^', TokenType.Pow],
  ['=', TokenType.Assign], ['!', TokenType.Not],
  ['<', TokenType.LT], ['>', TokenType.GT],
])

export { Lexer }
