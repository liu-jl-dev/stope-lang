// 语法分析器（Pratt）—— 端口 cpp/src/parser.cpp（C++ 为权威实现）。
//
// 行为契约见 docs/zh-cn/parser-test-plan.md。几条容易踩错、且各实现必须一致的约定：
//   1. 错误恢复：**分隔符缺失时只报错、不推进**，把后续 token 留给下一条语句重新解析。
//      例外（有意保留旧语义）：parseLetStmt / parseReturnStmt 的兜底分支仍会推进。
//   2. 不变量：parseExpr() 之后必有一次 nextToken()。删错误分支里的推进时别连带删它。
//   3. 顶层孤立 "}" 要报错【并跳过】继续解析；块内的 "}" 由外层消费，不报错。
//   4. 常量折叠挂在 parseUnaryOpExpr / parseBinaryOpExpr 的构造末尾，
//      **不要**改成把 parseExpr 包一层 —— 那样每层递归多一个栈帧，深括号用例会崩。
//   5. 节点取 token 的 parsed 而非 lexeme：字符串要转义后的值、标识符要拼好的 ':'。
//      只有 BinArr 取 lexeme（词法阶段不做任何转义）。

import { TokenType } from './token.js'
import { BinaryArrayParser } from './binarr_parser.js'
import * as A from './ast.js'
import { optimize } from './expr_optim.js'
import { Result } from './common.js'

const NT = A.NodeType

// 嵌套深度上限。depth 由调用链显式传递（每个 parseXxx 一个形参），不存成员：
// 哪一层递归、离上限还有多远，看签名就知道。0 = 不限制。
// 超限时报一条错、置 aborted，此后不再解析（返回 null）。默认值与 C++ 的
// Parser::maxDepth 相同，错误文案也逐字相同（两侧测试逐字比对）。
const kDefaultMaxDepth = 256

// ---------------- 前缀 / 中缀分发表 ----------------
// 表的内容与 cpp/include/stope/parser.hpp 的 prefixParseFns / infixParseFns 逐项对应。
const prefixFns = new Map()
const infixFns = new Map()

class Parser {
  constructor(lexer, custom = null) {
    this.binArrParser = new BinaryArrayParser()
    this.prefixFns = prefixFns
    this.infixFns = infixFns
    this.Reset(lexer, custom)
  }

  // 与 C++ 的 Parser::Reset 一致：清错误、重挂词法器、重读两个 token。
  Reset(lexer, custom = null) {
    this.errors = []
    this.aborted = false
    this.lexer = lexer
    this.custom = custom
    this.constFolding = true
    this.maxDepth = kDefaultMaxDepth
    // 先读两个 token，cur / peek 才都有值 —— 顺序不能变，
    // 否则输入最开头的自定义指令或首个 token 会被漏掉。
    this.nextToken()
    this.nextToken()
  }

  ParseProgram(prog) {
    this.parseProg(prog, true, 1)
  }

  // ================================ 语句 ================================
  // isTopLevel=true 只有 ParseProgram 用。块/if/while 内部的 prog 都是 false：
  // 它们的 "}" 属于外层语句，必须由外层自己消费。
  parseProg(prog, isTopLevel, depth) {
    if (this.aborted) return
    while (!this.aborted && this.curToken.type !== TokenType.Eof) {
      if (this.curToken.type === TokenType.RBrace) {
        if (!isTopLevel) break // 块内：正常结束，不跳过，交给外层处理
        this.error(this.curToken.line, 'unexpected "}" at top level. ')
        this.nextToken()
        continue
      }
      if (this.curToken.type === TokenType.Semi) { // 空语句
        this.nextToken()
        continue
      }
      let stmt
      if (this.curToken.type === TokenType.Let) stmt = this.parseLetStmt(depth)
      else if (this.curToken.type === TokenType.Export) stmt = this.parseExportStmt(depth)
      else if (this.curToken.type === TokenType.Return) stmt = this.parseReturnStmt(depth)
      else if (this.curToken.type === TokenType.LBrace) stmt = this.parseBlockStmt(depth)
      else if (this.curToken.type === TokenType.If) stmt = this.parseIfStmt(depth)
      else if (this.curToken.type === TokenType.While) stmt = this.parseWhileStmt(depth)
      else if (this.curToken.type === TokenType.Break) stmt = this.parseBreakStmt(depth)
      else if (this.curToken.type === TokenType.Continue) stmt = this.parseContinueStmt(depth)
      else stmt = this.parseExprOrAssignStmt(depth) // 表达式语句或赋值语句
      // 超限中止时子函数返回 null：不追加、不再往下解析（否则拿着同一个
      // token 反复调用会死循环）。
      if (stmt === null) break
      prog.stmts.push(stmt)
    }
  }

  parseLetStmt(depth) {
    const stmt = new A.LetStmt(this.curToken.line)
    stmt.hasAssign = false
    this.nextToken() // 跳过 let
    if (this.curToken.type !== TokenType.Ident) {
      this.error(this.curToken.line, 'expected identifier after "let". ')
      this.nextToken()
      return stmt
    }
    stmt.idents.push(this.curToken.parsed)
    this.nextToken()
    if (this.curToken.type === TokenType.Semi) {
      // 单个标识符且不赋值
      this.nextToken()
    } else if (this.curToken.type === TokenType.Comma) {
      // 多个标识符，禁止赋值
      for (;;) {
        if (this.curToken.type === TokenType.Comma && this.peekToken.type === TokenType.Ident) {
          stmt.idents.push(this.peekToken.parsed)
          this.nextToken()
          this.nextToken()
        } else if (this.curToken.type === TokenType.Semi) {
          this.nextToken()
          break
        } else if (this.curToken.type === TokenType.Eof || this.curToken.type === TokenType.RBrace) {
          // 缺 ";"：此处不能再推进。Eof 上推进不会前进会死循环，
          // 推进又会吞掉外层块的 "}" 导致解析错位。
          this.error(this.curToken.line, 'expected ";" in let statement. ')
          break
        } else {
          this.error(this.curToken.line, 'failed to parse let statement with multiple identifiers. ')
          this.nextToken()
        }
      }
    } else if (this.curToken.type === TokenType.Assign) {
      stmt.hasAssign = true
      this.nextToken()
      stmt.expr = this.parseExpr(A.Precedence.Lowest, depth)
      this.nextToken()
    } else {
      this.error(this.curToken.line, 'unexpected token in let statement. ')
      this.nextToken()
    }
    return stmt
  }

  parseExportStmt(_depth) {
    const stmt = new A.ExportStmt(this.curToken.line)
    this.nextToken() // 跳过 export
    if (this.curToken.type !== TokenType.Ident) {
      this.error(this.curToken.line, 'expected identifier after "export". ')
      this.nextToken()
      return stmt
    }
    stmt.idents.push(this.curToken.parsed)
    this.nextToken()
    if (this.curToken.type === TokenType.Semi) {
      this.nextToken()
    } else if (this.curToken.type === TokenType.Comma) {
      for (;;) {
        if (this.curToken.type === TokenType.Comma && this.peekToken.type === TokenType.Ident) {
          stmt.idents.push(this.peekToken.parsed)
          this.nextToken()
          this.nextToken()
        } else if (this.curToken.type === TokenType.Semi) {
          this.nextToken()
          break
        } else if (this.curToken.type === TokenType.Eof || this.curToken.type === TokenType.RBrace) {
          this.error(this.curToken.line, 'expected ";" in export statement. ')
          break
        } else {
          this.error(this.curToken.line, 'failed to parse export statement with multiple identifiers. ')
          this.nextToken()
        }
      }
    } else {
      this.error(this.curToken.line, 'unexpected token in export statement. ')
      this.nextToken()
    }
    return stmt
  }

  // return_stmt : "return" ( expr ( "," expr )* )? ";"
  parseReturnStmt(depth) {
    const stmt = new A.ReturnStmt(this.curToken.line)
    this.nextToken() // 跳过 return
    if (this.curToken.type === TokenType.Semi) {
      // 无返回值，exprs 为空
      this.nextToken()
      return stmt
    }
    if (this.curToken.type === TokenType.Eof || this.curToken.type === TokenType.RBrace) {
      // 缺 ";"：此时不能吞掉 } 或 Eof，否则外层块会解析错位
      this.error(this.curToken.line, 'expected ";" in return statement. ')
      return stmt
    }
    stmt.exprs.push(this.parseExpr(A.Precedence.Lowest, depth)) // 第一个表达式
    this.nextToken() // 到达 , 或 ;
    for (;;) {
      // ("," expr)*
      if (this.curToken.type === TokenType.Semi) {
        this.nextToken()
        break
      } else if (this.curToken.type === TokenType.Comma) {
        this.nextToken()
        stmt.exprs.push(this.parseExpr(A.Precedence.Lowest, depth))
        this.nextToken()
      } else {
        this.error(this.curToken.line, 'expected ";" or "," in return statement. ')
        this.nextToken()
        break
      }
    }
    return stmt
  }

  parseBlockStmt(depth) {
    if (this.aborted) return null // 已超限：不再解析
    const stmt = new A.BlockStmt(this.curToken.line)
    this.nextToken() // 跳过 {
    stmt.prog = new A.Prog()
    this.parseProg(stmt.prog, false, depth + 1)
    if (this.curToken.type !== TokenType.RBrace) {
      this.error(this.curToken.line, 'expected "}" at end of block statement. ')
    }
    this.nextToken() // 跳过 }
    return stmt
  }

  // if_stmt : "if" expr "{" prog "}" ("elif" expr "{" prog "}")* ("else" "{" prog "}")?
  parseIfStmt(depth) {
    if (this.aborted) return null
    const stmt = new A.IfStmt(this.curToken.line)
    this.nextToken() // 跳过 if
    stmt.cond = this.parseExpr(A.Precedence.Lowest, depth)
    this.nextToken() // 到达 {
    if (this.curToken.type !== TokenType.LBrace) {
      this.error(this.curToken.line, 'expected "{" in if statement. ')
      return stmt
    }
    this.nextToken() // 跳过 {
    stmt.firstProg = new A.Prog()
    this.parseProg(stmt.firstProg, false, depth + 1)
    if (this.curToken.type !== TokenType.RBrace) {
      this.error(this.curToken.line, 'expected "}" in if statement. ')
      return stmt
    }
    this.nextToken() // 跳过 }
    while (this.curToken.type === TokenType.Elif) {
      // ("elif" expr "{" prog "}")*
      const ei = new A.IfStmtElif(this.curToken.line)
      this.nextToken() // 跳过 elif
      ei.cond = this.parseExpr(A.Precedence.Lowest, depth)
      this.nextToken()
      if (this.curToken.type !== TokenType.LBrace) {
        this.error(this.curToken.line, 'expected "{" of elif. ')
        return stmt
      }
      this.nextToken() // 跳过 {
      ei.prog = new A.Prog()
      this.parseProg(ei.prog, false, depth + 1)
      if (this.curToken.type !== TokenType.RBrace) {
        this.error(this.curToken.line, 'expected "}" of elif. ')
        return stmt
      }
      this.nextToken() // 跳过 }
      stmt.elifs.push(ei)
    }
    if (this.curToken.type === TokenType.Else) {
      this.nextToken()
      if (this.curToken.type !== TokenType.LBrace) {
        this.error(this.curToken.line, 'expected "{" after else. ')
        return stmt
      }
      this.nextToken() // 跳过 {
      stmt.elseProg = new A.Prog()
      this.parseProg(stmt.elseProg, false, depth + 1)
      if (this.curToken.type !== TokenType.RBrace) {
        this.error(this.curToken.line, 'expected "}" in if statement. ')
        return stmt
      }
      this.nextToken() // 跳过 }
    }
    return stmt
  }

  // while_stmt : "while" expr? "{" prog "}"
  parseWhileStmt(depth) {
    if (this.aborted) return null
    const stmt = new A.WhileStmt(this.curToken.line)
    this.nextToken() // 跳过 while
    if (this.curToken.type !== TokenType.LBrace) {
      stmt.cond = this.parseExpr(A.Precedence.Lowest, depth)
      this.nextToken() // 到达 {
    }
    if (this.curToken.type !== TokenType.LBrace) {
      this.error(this.curToken.line, 'expected "{" in while statement. ')
      return stmt
    }
    this.nextToken() // 跳过 {
    stmt.prog = new A.Prog()
    this.parseProg(stmt.prog, false, depth + 1)
    if (this.curToken.type !== TokenType.RBrace) {
      this.error(this.curToken.line, 'expected "}" at end of while statement. ')
      return stmt
    }
    this.nextToken()
    return stmt
  }

  parseBreakStmt(_depth) {
    const stmt = new A.BreakStmt(this.curToken.line)
    this.nextToken() // 跳过 break
    if (this.curToken.type !== TokenType.Semi) {
      this.error(this.curToken.line, 'expected ";" in break statement. ')
    } else {
      this.nextToken()
    }
    return stmt
  }

  parseContinueStmt(_depth) {
    const stmt = new A.ContinueStmt(this.curToken.line)
    this.nextToken() // 跳过 continue
    if (this.curToken.type !== TokenType.Semi) {
      this.error(this.curToken.line, 'expected ";" in continue statement. ')
    } else {
      this.nextToken()
    }
    return stmt
  }

  parseExprOrAssignStmt(depth) {
    const leftExpr = this.parseExpr(A.Precedence.Lowest, depth)
    if (leftExpr === null) return null // 超限中止：下面要读 leftExpr.line
    this.nextToken() // 到达 = 或 ;
    if (this.curToken.type === TokenType.Semi) {
      this.nextToken() // 跳过 ;
      const s = new A.ExprStmt(leftExpr.line)
      s.expr = leftExpr
      return s
    } else if (this.curToken.type === TokenType.Assign) {
      this.nextToken() // 跳过 =
      const a = new A.AssignStmt(leftExpr.line)
      a.leftExpr = leftExpr
      a.rightExpr = this.parseExpr(A.Precedence.Lowest, depth)
      this.nextToken() // 到达 ;
      if (this.curToken.type !== TokenType.Semi) {
        this.error(this.curToken.line, 'expected ";" at end of assign statement. ')
      }
      this.nextToken()
      return a
    }
    this.error(this.curToken.line, 'expected ";" or "=". ')
    // 不推进：当前 token 不是合法的语句边界，留给下一轮语句解析。
    // 否则会吞掉后续语句（f(1, 2 x; y; 里的 x; 被吞）。
    const s2 = new A.ExprStmt(leftExpr.line)
    s2.expr = leftExpr
    return s2
  }

  // ================================ 表达式主循环 ================================
  parseExpr(precedence, depth) {
    // 深度检查只在这里和 parseProg 做 —— 只有这两处会递归。
    if (this.aborted) return null
    if (this.maxDepth > 0 && depth > this.maxDepth) {
      this.abortTooDeep(this.curToken.line)
      return null
    }
    const prefix = prefixFns.get(this.curToken.type)
    if (prefix === undefined) {
      this.error(this.curToken.line, 'no prefix parse function for token type. ')
      return new A.Expr(this.curToken.line) // 失败路径返回裸节点，形状为 Err(L行号)
    }
    let leftExpr = prefix(this, depth)
    if (leftExpr === null) return null // 子表达式已中止（括号会原样透出）
    while (!this.aborted && this.peekToken.type !== TokenType.Semi && precedence < this.peekPrecedence()) {
      const infix = infixFns.get(this.peekToken.type)
      if (infix === undefined) {
        this.error(this.peekToken.line, 'no infix parse function for token type. ')
        return leftExpr
      }
      this.nextToken()
      leftExpr = infix(this, leftExpr, depth)
      if (leftExpr === null) return null
    }
    return leftExpr
  }

  curPrecedence() {
    return A.binopPrecMap[this.curToken.type] ?? A.Precedence.Lowest
  }

  peekPrecedence() {
    return A.binopPrecMap[this.peekToken.type] ?? A.Precedence.Lowest
  }

  // 常量折叠的单一入口。挂在 parseUnaryOpExpr / parseBinaryOpExpr 的构造末尾
  // （见那两处），**不要**改成把 parseExpr 包一层。
  optimizeInPlace(e) {
    if (!this.constFolding) return e
    return optimize(e)
  }

  // ================================ 基础设施 ================================
  nextToken() {
    this.curToken = this.peekToken
    this.peekToken = this.lexer.NextToken(this.custom)
  }

  error(line, msg) {
    // 嵌套超限中止之后的一切错误（缺 "}"、expected ")" 之类）都是连锁反应，
    // 不再记账 —— 否则一个 12000 层的块嵌套能刷出上万条噪音。
    if (this.aborted) return
    this.errors.push(`line ${line}: ${msg}`)
  }

  abortTooDeep(line) {
    this.error(line, `nesting too deep (max ${this.maxDepth}). `) // 必须在置位之前记账
    this.aborted = true
  }

  hasErr() {
    return this.errors.length > 0
  }
}

// ================================ 前缀 ================================
function parseIdentExpr(p, _depth) {
  return new A.IdentExpr(p.curToken.line, p.curToken.parsed)
}
function parseNullExpr(p, _depth) {
  return new A.NullExpr(p.curToken.line)
}
function parseBoolExpr(p, _depth) {
  return new A.BoolExpr(p.curToken.line, p.curToken.type === TokenType.True)
}
function parseIntExpr(p, _depth) {
  return new A.IntExpr(p.curToken.line, p.curToken.value)
}
function parseFloatExpr(p, _depth) {
  return new A.FloatExpr(p.curToken.line, p.curToken.value)
}
function parseStringExpr(p, _depth) {
  // 取 parsed：转义已完成（lexeme 是未转义的原文）
  return new A.StringExpr(p.curToken.line, p.curToken.parsed)
}
function parseBinArrExpr(p, _depth) {
  const e = new A.BinArrExpr(p.curToken.line)
  // 取 lexeme：二进制数组不做转义，解析到一半失败也要保留前半段（报错但继续）
  const bytes = []
  const rc = p.binArrParser.parseBinaryArray(p.curToken.lexeme, bytes)
  e.value = Uint8Array.from(bytes)
  if (rc !== Result.Success) p.error(p.curToken.line, 'invalid binary array. ')
  return e
}
function parseArgcExpr(p, _depth) {
  return new A.ArgcExpr(p.curToken.line)
}

function parseUnaryOpExpr(p, depth) {
  const e = new A.UnaryOpExpr(p.curToken.line)
  e.op = p.curToken.type
  p.nextToken()
  e.expr = p.parseExpr(A.Precedence.Prefix, depth + 1)
  return p.optimizeInPlace(e) // 自底向上：子表达式已折好，这里折自己
}

function parseParenExpr(p, depth) {
  p.nextToken()
  const e = p.parseExpr(A.Precedence.Lowest, depth + 1)
  p.nextToken()
  if (p.curToken.type !== TokenType.RParen) p.error(p.curToken.line, 'expected ")". ')
  return e // 停在 )
}

function parseCustomOpcodeExpr(p, depth) {
  const e = new A.CustomOpcodeExpr(p.curToken.line)
  e.opcodeName = p.curToken.parsed
  p.nextToken() // 到达 (
  if (p.curToken.type !== TokenType.LParen) {
    p.error(p.curToken.line, 'expected "(" after custom opcode. ')
    p.nextToken()
    return e
  }
  p.nextToken()
  if (p.curToken.type === TokenType.RParen) {
    // 空参数表，cur 停在 )
  } else {
    // expr ("," expr)*
    e.args.push(p.parseExpr(A.Precedence.Lowest, depth + 1))
    while (p.peekToken.type === TokenType.Comma) {
      p.nextToken()
      p.nextToken()
      e.args.push(p.parseExpr(A.Precedence.Lowest, depth + 1))
    }
    if (p.peekToken.type !== TokenType.RParen) p.error(p.curToken.line, 'expected ")". ')
    p.nextToken() // 到达 )
  }
  return e
}

function parseArgsExpr(p, depth) {
  const e = new A.ArgsExpr(p.curToken.line)
  if (p.peekToken.type !== TokenType.LBrack) {
    // 不推进（cur 停在 "args"）：把后续 token 留给下一条语句，避免吞掉
    p.error(p.peekToken.line, 'expected "[" after "args". ')
    return e
  }
  p.nextToken() // 到达 [
  p.nextToken()
  e.keyExpr = p.parseExpr(A.Precedence.Lowest, depth + 1)
  p.nextToken()
  if (p.curToken.type !== TokenType.RBrack) p.error(p.curToken.line, 'expected "]". ')
  return e
}

// ================================ 中缀 ================================
function parseBinaryOpExpr(p, leftExpr, depth) {
  if (leftExpr === null) return null // 左操作数已中止（正常路径进不来）
  const e = new A.BinaryOpExpr(leftExpr.line)
  e.leftExpr = leftExpr
  e.op = p.curToken.type
  let prec = p.curPrecedence()
  // ^ 右结合：优先级 -1 让右侧继续吃同级的 ^（2^3^2 = 2^(3^2)）。
  if (e.op === TokenType.Pow) prec -= 1
  p.nextToken()
  e.rightExpr = p.parseExpr(prec, depth + 1)
  return p.optimizeInPlace(e) // 两侧都已折好，折叠只在最深的节点先发生
}

function parseCallExpr(p, callee, depth) {
  if (callee === null) return null
  const e = new A.CallExpr(callee.line)
  e.callee = callee
  // 外层已保证此处是 (
  if (p.peekToken.type !== TokenType.RParen) {
    // expr ("," expr)*
    p.nextToken() // 到达第一个表达式
    e.args.push(p.parseExpr(A.Precedence.Lowest, depth + 1))
    while (p.peekToken.type === TokenType.Comma) {
      p.nextToken() // 到达 ","
      p.nextToken() // 到达下一个表达式
      e.args.push(p.parseExpr(A.Precedence.Lowest, depth + 1))
    }
  }
  if (p.peekToken.type === TokenType.RParen) {
    p.nextToken() // 跳过 )
  } else {
    // 缺 ")" 时不推进，避免吞掉后面的 token
    p.error(p.peekToken.line, 'expected ")". ')
  }
  return e
}

function parseAtExpr(p, container, depth) {
  if (container === null) return null
  const e = new A.AtExpr(container.line)
  e.container = container
  if (p.peekToken.type !== TokenType.RBrack) {
    // expr ("," expr)*
    p.nextToken() // 到达第一个表达式
    e.keyExprs.push(p.parseExpr(A.Precedence.Lowest, depth + 1))
    while (p.peekToken.type === TokenType.Comma) {
      p.nextToken() // 到达 ","
      p.nextToken() // 到达下一个表达式
      e.keyExprs.push(p.parseExpr(A.Precedence.Lowest, depth + 1))
    }
  }
  if (p.peekToken.type === TokenType.RBrack) {
    p.nextToken() // 跳过 ]
  } else {
    // 缺 "]" 时不推进，避免吞掉后面的 token
    p.error(p.peekToken.line, 'expected "]". ')
  }
  return e
}

// 表在模块加载后一次性填好（与 Parser 构造函数里的 registerParseFns 等价）
prefixFns.set(TokenType.Ident, parseIdentExpr)
prefixFns.set(TokenType.Null, parseNullExpr)
prefixFns.set(TokenType.False, parseBoolExpr)
prefixFns.set(TokenType.True, parseBoolExpr)
prefixFns.set(TokenType.Integer, parseIntExpr)
prefixFns.set(TokenType.Float, parseFloatExpr)
prefixFns.set(TokenType.String, parseStringExpr)
prefixFns.set(TokenType.BinArr, parseBinArrExpr)
prefixFns.set(TokenType.Argc, parseArgcExpr)
prefixFns.set(TokenType.Sub, parseUnaryOpExpr)
prefixFns.set(TokenType.Not, parseUnaryOpExpr)
prefixFns.set(TokenType.LParen, parseParenExpr)
prefixFns.set(TokenType.Custom, parseCustomOpcodeExpr)
prefixFns.set(TokenType.Args, parseArgsExpr)

for (const t of [
  TokenType.Or,
  TokenType.And,
  TokenType.EQ,
  TokenType.NE,
  TokenType.LT,
  TokenType.LE,
  TokenType.GT,
  TokenType.GE,
  TokenType.Add,
  TokenType.Sub,
  TokenType.Mul,
  TokenType.Div,
  TokenType.IDiv,
  TokenType.Mod,
  TokenType.Pow,
])
  infixFns.set(t, parseBinaryOpExpr)
infixFns.set(TokenType.LParen, parseCallExpr) // () 函数调用
infixFns.set(TokenType.LBrack, parseAtExpr) // [] 取元素

export { Parser }
