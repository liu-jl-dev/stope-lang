// 手写类型声明。
//
// 约定：不引入 TypeScript 工具链。源码用 JSDoc 描述类型，对外 API 在这里手写声明，
// `package.json` 的 exports.types 指向本文件。
//
// 值模型（与 src/basic_vm.js 的注释一致）：
//   Null -> null，Integer -> bigint，Float -> number，String -> string，
//   BinArr -> Uint8Array，宿主函数 -> (args: Value[]) => Value

export type ResultCode = 0 | 1 | 2 | 3

export const Result: {
  readonly Success: 0
  readonly Error: 1
  readonly UnknownError: 2
  readonly DuplicateWithBuiltinOpcode: 3
}

export const TokenType: Record<string, number> & Record<number, string>

export class Token {
  line: number
  type: number
  lexeme: string
  parsed: string
  value?: bigint | number
}

export class Lexer {
  constructor(input: string)
  input: string
  line: number
  errors: string[]
  Reset(input: string): void
  NextToken(custom?: CustomOpcodeConfig | null): Token
}

export class CustomOpcode {
  opcode: number
  isVarArg: boolean
  argNum: number
}

export class CustomOpcodeConfig {
  constructor()
  opcodes: Map<string, CustomOpcode>
  addCustomOpcode(name: string, opcode: number, argNum?: number): ResultCode
}

export const Opcode: Record<string, number> & Record<number, string>
export const kFirstCustomOpcode: number

export type Node = { line: number; nodeType: number }

// AST 命名空间：节点类 + 形状串 + 优先级表。其余节点类的字段见
// docs/zh-cn/syntax-impl.md §3，这里只展开最常用的几个。
export const AST: {
  NodeType: Record<string, number> & Record<number, string>
  Precedence: Record<string, number>
  shapeProg(p: Node | null): string
  shapeExpr(e: Node | null): string
  shapeStmt(s: Node | null): string
  fmtG(v: number): string
  esc(s: string): string
  new (): never
  Prog: new (line?: number) => Node & { stmts: Node[] }
  IntExpr: new (line?: number, v?: bigint) => Node & { value: bigint }
  FloatExpr: new (line?: number, v?: number) => Node & { value: number }
  StringExpr: new (line?: number, v?: string) => Node & { value: string }
  BinArrExpr: new (line?: number, v?: Uint8Array) => Node & { value: Uint8Array }
  IdentExpr: new (line?: number, v?: string) => Node & { ident: string }
}

export class ASTVisitor {
  curLine: number
  readonly visitMap: Record<number, string>
  visit(n: Node | null): void
}

export class Parser {
  constructor(lexer: Lexer, custom?: CustomOpcodeConfig | null)
  errors: string[]
  constFolding: boolean
  maxDepth: number
  Reset(lexer: Lexer, custom?: CustomOpcodeConfig | null): void
  ParseProgram(prog: Node): void
  HasErr(): boolean
}

export function optimize(e: Node | null): Node | null

export class Program {
  opcodes: number[]
  variableNum: number
  exports: Map<string, number>
  intConsts: bigint[]
  floatConsts: number[]
  stringConsts: string[]
  binArrConsts: Uint8Array[]
  maxReturnNum: number
  requiredStackSize: number
  toMap(): Record<string, unknown>
  toJsonString(): string
}

export class Compiler {
  constructor(custom?: CustomOpcodeConfig | null)
  errors: string[]
  Reset(custom?: CustomOpcodeConfig | null): void
  Compile(ast: Node, out: Program): ResultCode
}

export class BinaryArrayParser {
  parseBinaryArray(input: string, output: number[]): ResultCode
}

export function Disasm(prog: Program, config?: CustomOpcodeConfig | null): string
export function DisasmNoCustom(prog: Program): string
export function OpcodeHasArg(op: number): boolean
export function CustomOpcodeHasArg(raw: number, config: CustomOpcodeConfig | null): boolean

// ---------------- STML ----------------
export class StmlElement {
  line: number
  tag: string
  attrs: Map<string, string>
  selfClosing: boolean
  children: StmlElement[]
  text: string
  toStr(level?: number): string
}

export class StmlToken {
  line: number
  type: number
  lexeme: string
}

export const StmlTokenType: Record<string, number> & Record<number, string>
export const StmlState: { readonly Xml: 0; readonly Text: 1; readonly Nevext: 2; readonly Stope: 3 }

export class StmlLexer {
  constructor(source?: string)
  state: number
  line: number
  errors: string[]
  NextToken(): StmlToken
}

export class StmlParser {
  constructor(lex: StmlLexer)
  errors: string[]
  Parse(
    root: StmlElement,
    stateFunc?: ((tag: string, attrs: Map<string, string>) => number) | null,
  ): ResultCode
}

// ---------------- 参考执行器（不是标准） ----------------
export type Value = null | bigint | number | string | Uint8Array | ((args: Value[]) => Value)

export const BasicVM: {
  Identifier: new (index: number) => { index: number }
  Arguments: new () => { at(state: unknown, indexOrKey: Value): Value; num(): number }
  Api: new () => { opMap: Array<(s: unknown) => void> }
  State: new () => {
    api: unknown
    program: Program
    args: unknown
    returns: Value[]
    i: number
    variables: Value[]
    stack: Value[]
    errors: string[]
    Reset(api: unknown, program: Program, args?: unknown): void
    SetArguments(args: unknown): void
    Error(msg: string): void
    error(msg: string): void
    HasError(): boolean
    Step(): ResultCode
    Run(): ResultCode
    AtTop(k: number): Value
    Pop(): void
    PopN(num: number): void
    PushInt(v: bigint | number): void
  }
}
