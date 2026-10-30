// STML 语法器 —— 端口 cpp/src/stml_parser.cpp。
// 契约见 docs/zh-cn/stml-test-plan.md §2.6~§2.8。
//
// STML 比 XML 严格，三条容易写错：
//   1. 属性可以没有值 —— `<a flag>` 等价于 `flag = ""`，所以属性循环**不能**在开头
//      无条件 NextToken()，每个分支自己负责推进（否则无值属性会多吞一个 token）；
//   2. 子元素与元素内文本**互斥**，文本只有一段、不拼接；
//   3. 每个错误分支都**提前 return**，不在同一处级联（B-14）。

import { Result } from './common.js'
import { Element, TokenType } from './stml.js'
import { State } from './stml_lexer.js'

class Parser {
  constructor(lex) {
    this.lexer = lex
    this.stateFunc = null
    this.token = null
    this.errors = []
  }

  // 顶层只解析**一个**元素（B-15），根之后的剩余输入被忽略。
  // stateFunc(tag, attrs) -> State：由宿主决定某个标签的内容该按哪种状态扫；
  // 传 null 等价于 C++ 的 nullptr，一律 Xml（子元素模式）。
  // 返回值是 Result.Success / Result.Error（与编译器共用同一份 Result）。
  Parse(root, stateFunc = null) {
    this.stateFunc = stateFunc
    this.nextToken()
    this.parseElement(root)
    return this.errors.length === 0 ? Result.Success : Result.Error
  }

  parseElement(e) {
    // 进入元素一律先回到 Xml：自闭合分支与出错提前返回的路径都走不到
    // stateFunc，留着上一次的 Text/Nevext/Stope 会污染后续 token
    this.lexer.state = State.Xml
    e.line = this.token.line
    if (this.token.type !== TokenType.LAngle) {
      this.error('expected "<". ')
      return
    }
    this.nextToken()
    if (this.token.type !== TokenType.Word) {
      this.error('expected tag name. ')
      return
    }
    e.tag = this.token.lexeme
    this.nextToken() // 第一个属性名，或 > 或 />
    for (;;) {
      // (word ("=" string)?)*
      if (this.token.type === TokenType.RAngle) break
      else if (this.token.type === TokenType.CRAngle) {
        e.selfClosing = true
        return
      } else if (this.token.type === TokenType.Word) {
        const attr = this.token.lexeme
        this.nextToken()
        if (this.token.type === TokenType.EQ) {
          this.nextToken() // 已跳过 =
          if (this.token.type !== TokenType.String) {
            this.error('expected string. ')
            return
          }
          e.attrs.set(attr, this.token.lexeme)
          this.nextToken()
        } else {
          // 无值属性（B-9）：token 已经是下一个属性名 / > 或 />，不能再推进
          e.attrs.set(attr, '')
        }
      } else {
        this.error('expected ">" or "/>" or attribute. ')
        return
      }
    }
    // 此时 selfClosing = false，且停在 ">"
    if (this.stateFunc !== null && this.stateFunc !== undefined) {
      // attrs 传**副本**：C++ 的 LexerStateFunc 按值收 std::map，宿主改不到解析器；
      // 这里不复制的话宿主删/加键会改到 e.attrs 本身。
      this.lexer.state = this.stateFunc(e.tag, new Map(e.attrs))
    } else {
      this.lexer.state = State.Xml
    }
    if (this.lexer.state === State.Xml) {
      for (;;) {
        this.nextToken()
        if (this.token.type === TokenType.CLAngle) break
        else if (this.token.type === TokenType.LAngle) {
          const child = new Element()
          e.children.push(child)
          this.parseElement(child)
        } else {
          this.error('expected "<" or "</". ')
          return
        }
      }
    } else {
      // Text / Nevext / Stope：整段内容由 Lexer 一次性给出
      this.nextToken()
      if (
        this.token.type !== TokenType.Text &&
        this.token.type !== TokenType.NevextSrc &&
        this.token.type !== TokenType.StopeSrc
      ) {
        this.error('expected element content. ')
        return
      }
      e.text = this.token.lexeme // 只有一段，不拼接（B-11）
      this.nextToken() // 停在 CLAngle，与上面 Xml 分支的 break 处汇合
    }
    this.nextToken() // 结束标签名
    if (this.token.type !== TokenType.Word) {
      this.error('expected tag name. ')
      return
    }
    if (this.token.lexeme !== e.tag) {
      this.error('tag name mismatch. ')
      return
    }
    this.nextToken()
    if (this.token.type !== TokenType.RAngle) {
      this.error('expected ">". ')
      return
    }
  }

  nextToken() {
    this.token = this.lexer.NextToken()
    return this.token
  }

  error(msg) {
    this.errors.push(`line ${this.token.line}: ${msg}`)
  }
}

export { Parser }
