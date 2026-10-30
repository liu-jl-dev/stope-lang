// Stope Node.js 实现的公共入口。
//
// 约定：本文件只做 re-export，不放任何实现。新增模块后在这里加一行导出，
// 对外暴露的 API 面就只有这一个文件。
//
// 分层与另外两个实现一一对应（cpp/include/stope/*.hpp、gdscript/addons/stope/*.gd）：
//
//   标准层：Result / Token / TokenType / Opcode / CustomOpcodeConfig
//           Lexer / Parser / AST / ASTVisitor / ExpressionOptimizer
//           Compiler / Program / BinaryArrayParser / Debug
//           STML 三件套（Lexer / Parser / Element）
//   示例层：BasicVM 的 Api / State / Arguments / Identifier —— **不是标准**
//
// 「标准」的含义见仓库根 README：Stope 只规定语言、STML 与编译产物 Program；
// 虚拟机只是参考实现，换一个执行器这些名字可能一个都不存在。

export { Result } from './common.js'
export { Token, TokenType } from './token.js'
export { Opcode, CustomOpcode, CustomOpcodeConfig, kFirstCustomOpcode } from './opcode.js'
export { Lexer } from './lexer.js'

// AST：节点类 + 形状串（shapeProg / shapeExpr）+ 优先级表 + 节点类型枚举
export * as AST from './ast.js'
export { ASTVisitor, visitMap } from './ast_visitor.js'
export { Parser } from './parser.js'
export { optimize } from './expr_optim.js'
export { Compiler } from './compiler.js'
export { Program } from './program.js'
export { BinaryArrayParser } from './binarr_parser.js'
export { Disasm, DisasmNoCustom, OpcodeHasArg, CustomOpcodeHasArg } from './debug.js'

// STML：树的形状归解析器，内容怎么切归宿主（Parse 的第二个参数）
export { Element as StmlElement, Token as StmlToken, TokenType as StmlTokenType } from './stml.js'
export { Lexer as StmlLexer, State as StmlState } from './stml_lexer.js'
export { Parser as StmlParser } from './stml_parser.js'

// 参考执行器（不是标准）
export * as BasicVM from './basic_vm.js'
