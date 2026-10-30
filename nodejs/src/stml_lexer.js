// STML 词法器。四态状态机（Xml / Text / Nevext / Stope），契约见
// docs/zh-cn/stml-test-plan.md §2.1~§2.5，权威实现是 cpp/src/stml_lexer.cpp。
//
// 三条最容易写错的规则：
//   1. Text / Nevext / Stope 扫完一段后**必须把 state 交还 Xml**，否则后续
//      NextToken() 会产出无限个空 token（C++ 侧由 NextToken 自己收尾）；
//   2. 输入耗尽后**永远**返回 Eof，与当前状态无关；
//   3. 任何异常路径都要**消费字符**，否则调用方的 while 会死循环。

import { Token, TokenType } from './stml.js'

const State = {
  Xml: 0,
  Text: 1,
  Nevext: 2,
  Stope: 3,
}

const WHITE = new Set([' ', '\t', '\v', '\f', '\r', '\n'])
const isWhite = (ch) => WHITE.has(ch)
const isAlpha = (ch) => {
  const c = ch.charCodeAt(0)
  return (c >= 97 && c <= 122) || (c >= 65 && c <= 90)
}
const isDigit = (ch) => ch >= '0' && ch <= '9'
const isWordBegin = (ch) => isAlpha(ch) || ch === '_' || ch === ':'
const isWordChar = (ch) => isWordBegin(ch) || isDigit(ch) || ch === '-'

// 去掉尾部空白（B-8：内容段尾部的空白不计入 lexeme）
function trimTrailingWs(s) {
  let n = s.length
  while (n > 0 && isWhite(s[n - 1])) n -= 1
  return s.slice(0, n)
}

class Lexer {
  constructor(source = '') {
    this.state = State.Xml
    this.src = source
    this.line = 1
    this.errors = []
  }

  NextToken() {
    const token = new Token()
    this.skipWs()
    token.line = this.line
    if (this.src.length === 0) {
      token.set(TokenType.Eof, '')
    } else if (this.state === State.Xml) {
      if (this.test('</')) {
        token.set(TokenType.CLAngle, '</')
        this.src = this.src.slice(2)
      } else if (this.test('/>')) {
        token.set(TokenType.CRAngle, '/>')
        this.src = this.src.slice(2)
      } else if (this.src[0] === '<') {
        token.set(TokenType.LAngle, '<')
        this.src = this.src.slice(1)
      } else if (this.src[0] === '>') {
        token.set(TokenType.RAngle, '>')
        this.src = this.src.slice(1)
      } else if (this.src[0] === '=') {
        token.set(TokenType.EQ, '=')
        this.src = this.src.slice(1)
      } else if (this.src[0] === "'" || this.src[0] === '"') {
        this.scanString(token)
      } else if (isWordBegin(this.src[0])) {
        token.set(TokenType.Word, this.scanWord())
      } else {
        this.error('unexpected character. ')
        token.set(TokenType.Invalid, '')
        this.src = this.src.slice(1) // 必须消费，否则死循环
      }
    } else if (this.state === State.Text) {
      token.set(TokenType.Text, this.scanText())
      this.state = State.Xml
    } else if (this.state === State.Nevext) {
      token.set(TokenType.NevextSrc, this.scanNevext())
      this.state = State.Xml
    } else if (this.state === State.Stope) {
      token.set(TokenType.StopeSrc, this.scanStope())
      this.state = State.Xml
    } else {
      this.error(`unexpected lexer state ${this.state}. `)
      this.src = this.src.slice(1)
    }
    return token
  }

  // ============================ Xml 状态 ============================
  // Xml 属性串：**不转义**（`\"` 里的引号就是结束引号，TD-9）。
  // 未闭合时报错（文案比代码段那条少一个句号，TD-8）并吃掉剩余全部输入。
  scanString(token) {
    token.type = TokenType.String
    const quote = this.src[0]
    this.src = this.src.slice(1) // 跳过开头的引号
    let n = 0
    for (;;) {
      if (n >= this.src.length) {
        this.error('unclosed string literal')
        this.src = ''
        token.type = TokenType.Invalid
        break
      }
      if (this.src[n] === quote) {
        token.lexeme = this.src.slice(0, n)
        this.src = this.src.slice(n + 1)
        break
      }
      if (this.src[n] === '\n') this.line += 1
      n += 1
    }
  }

  scanWord() {
    let end = 1
    while (end < this.src.length) {
      if (!isWordChar(this.src[end])) break
      end += 1
    }
    const s = this.src.slice(0, end)
    this.src = this.src.slice(end)
    return s
  }

  // ============================ 内容三态 ============================
  // 三个扫描函数同构：从 src 开头一路吃到 `</` 或输入耗尽，尾部空白不计入
  // lexeme（B-8）。Text 只认 `</`，`<b/>` 会被整段当文本吃掉（B-2）。
  scanText() {
    const begin = this.src
    while (this.src.length > 0) {
      if (this.test('</')) break
      if (this.src[0] === '\n') this.line += 1
      this.src = this.src.slice(1)
    }
    return trimTrailingWs(begin.slice(0, begin.length - this.src.length))
  }

  // Nevext 代码段：引号串与注释整段跳过，其中的 `</` 不算结束标签（B-3）。
  scanNevext() {
    const begin = this.src
    while (this.src.length > 0) {
      if (this.test('</')) break
      else if (this.src[0] === "'" || this.src[0] === '"') this.scanNevextStr(this.src[0])
      else if (this.test('//')) this.skipSinglelineComment()
      else if (this.test('/*')) this.skipMultilineComment()
      else {
        if (this.src[0] === '\n') this.line += 1
        this.src = this.src.slice(1)
      }
    }
    return trimTrailingWs(begin.slice(0, begin.length - this.src.length))
  }

  // Stope 代码段：同 Nevext，只有引号规则不同（单引号是 BinArr，不转义）。
  scanStope() {
    const begin = this.src
    while (this.src.length > 0) {
      if (this.test('</')) break
      else if (this.src[0] === "'" || this.src[0] === '"') this.scanStopeStr(this.src[0])
      else if (this.test('//')) this.skipSinglelineComment()
      else if (this.test('/*')) this.skipMultilineComment()
      else {
        if (this.src[0] === '\n') this.line += 1
        this.src = this.src.slice(1)
      }
    }
    return trimTrailingWs(begin.slice(0, begin.length - this.src.length))
  }

  // Nevext 的引号串：两种引号**都**转义，且 `\` 后的任意字符都被吃掉。
  scanNevextStr(quote) {
    const beginLine = this.line
    this.src = this.src.slice(1) // 跳过开头的引号
    for (;;) {
      if (this.src.length === 0) {
        this.error2(beginLine, 'unclosed string literal. ')
        return
      }
      const c = this.src[0]
      this.src = this.src.slice(1)
      if (c === '\\') {
        if (this.src.length === 0) {
          this.error2(beginLine, 'unclosed string literal. ')
          return
        }
        if (this.src[0] === '\n') this.line += 1
        this.src = this.src.slice(1)
      } else if (c === quote) {
        return
      } else if (c === '\n') {
        this.line += 1
      }
    }
  }

  // Stope 的引号串：双引号是字符串、转义；单引号是 BinArr，**不转义**
  // （与 Stope 的 Lexer.scanBinArr 一致）。
  scanStopeStr(quote) {
    const escapes = quote === '"'
    const beginLine = this.line
    this.src = this.src.slice(1) // 跳过开头的引号
    for (;;) {
      if (this.src.length === 0) {
        this.error2(beginLine, 'unclosed string literal. ')
        return
      }
      const c = this.src[0]
      this.src = this.src.slice(1)
      if (escapes && c === '\\') {
        if (this.src.length === 0) {
          this.error2(beginLine, 'unclosed string literal. ')
          return
        }
        if (this.src[0] === '\n') this.line += 1
        this.src = this.src.slice(1)
      } else if (c === quote) {
        return
      } else if (c === '\n') {
        this.line += 1
      }
    }
  }

  skipSinglelineComment() {
    this.src = this.src.slice(2)
    while (this.src.length > 0) {
      const c = this.src[0]
      this.src = this.src.slice(1)
      if (c === '\n') {
        this.line += 1
        break
      }
    }
  }

  skipMultilineComment() {
    this.src = this.src.slice(2)
    while (this.src.length > 0) {
      if (this.test('*/')) {
        this.src = this.src.slice(2)
        break
      }
      if (this.src[0] === '\n') this.line += 1
      this.src = this.src.slice(1)
    }
  }

  // ============================ 空白与注释 ============================
  skipWs() {
    while (this.src.length > 0) {
      if (isWhite(this.src[0])) {
        if (this.src[0] === '\n') this.line += 1
        this.src = this.src.slice(1)
      } else if (this.state === State.Xml && this.test('<!--')) {
        // `<!--` 只在 Xml 状态是注释；Nevext / Stope 里的 '<' 是小于号
        this.skipXmlComment()
      } else {
        break
      }
    }
  }

  skipXmlComment() {
    this.src = this.src.slice(4)
    while (this.src.length > 0) {
      if (this.test('-->')) {
        this.src = this.src.slice(3)
        break
      }
      if (this.src[0] === '\n') this.line += 1
      this.src = this.src.slice(1)
    }
  }

  // ============================ 小工具 ============================
  test(s) {
    if (this.src.length < s.length) return false
    return this.src.slice(0, s.length) === s
  }
  error(msg) {
    this.errors.push(`line ${this.line}: ${msg}`)
  }
  error2(line, msg) {
    this.errors.push(`line ${line}: ${msg}`)
  }
}

export { Lexer, State, TokenType, trimTrailingWs }
