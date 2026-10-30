// nodejs 侧 Lexer 的单元测试。
//
// 用例编号沿用 C++ 侧（cpp/test/test_lexer_*.cpp），两边可以逐条对照：
//   I-xx 整数  F-xx 浮点  D-xx 标识符  K-xx 关键字  S-xx 字符串  B-xx 二进制串
//   P-xx 标点  W-xx 空白与注释  L-xx 行号  E-xx 错误  R-xx 健壮性
//   C-xx 自定义指令  G-xx 端到端
// 用例清单与覆盖矩阵见 ../docs/lexer-test-plan.md。
//
// 与 C++ 的唯一有意差异：C++ 里标识符与标点的 lexeme 恒为空（它有两个未修缺陷
// D-8 / D-9），nodejs 侧对所有 token 都填了 lexeme。涉及这两处的断言按 nodejs
// 行为写，并在用例名后标了「C++ 未修」。

import { test, describe } from 'node:test'

import { Lexer } from '../src/lexer.js'
import { TokenType } from '../src/token.js'
import { CustomOpcodeConfig } from '../src/opcode.js'
import { Result } from '../src/common.js'
import {
  lexAll,
  expectType,
  expectLex,
  expectParsed,
  expectInt,
  expectDbl,
  expectLine,
  expectCount,
  expectSeq,
  expectErrCount,
  expectErrHas,
  expectNoErrors,
} from './helpers.js'

describe('T3 整数 (LEX-N-I)', () => {
  test('I-01 十进制与前导零', () => {
    const r = lexAll('0 00 0009')
    expectCount(r, 4, 'I-01')
    expectInt(r, 0, 0, 'I-01')
    expectInt(r, 1, 0, 'I-01')
    expectInt(r, 2, 9, 'I-01')
    expectParsed(r, 2, '0009', 'I-01')
    expectNoErrors(r, 'I-01')
  })
  test('I-02 下划线', () => {
    const r = lexAll('1_000 1_ 0_1')
    expectCount(r, 4, 'I-02')
    expectInt(r, 0, 1000, 'I-02')
    expectParsed(r, 0, '1000', 'I-02')
    expectInt(r, 1, 1, 'I-02')
    expectParsed(r, 1, '1', 'I-02')
    expectInt(r, 2, 1, 'I-02')
    expectParsed(r, 2, '01', 'I-02')
  })
  test('I-03 数字紧跟标识符', () => {
    const r = lexAll('123abc')
    expectSeq(r, 'Integer Ident Eof', 'I-03')
    expectInt(r, 0, 123, 'I-03')
    expectParsed(r, 1, 'abc', 'I-03')
  })
  test('I-04 十进制边界值（int64 上限，BigInt 不丢精度）', () => {
    const r = lexAll('9223372036854775807')
    expectInt(r, 0, 9223372036854775807n, 'I-04')
    expectNoErrors(r, 'I-04')
  })
  test('I-05 十进制溢出', () => {
    const r = lexAll('9223372036854775808')
    expectType(r, 0, TokenType.Invalid, 'I-05')
    expectErrHas(r, 'invalid integer.', 'I-05')
  })
  test('I-06 各进制取值', () => {
    const r = lexAll('0x1F 0X1f 0b101 0B101 0o17 0O17 0xFF')
    expectCount(r, 8, 'I-06')
    expectInt(r, 0, 31, 'I-06')
    expectInt(r, 1, 31, 'I-06')
    expectInt(r, 2, 5, 'I-06')
    expectInt(r, 3, 5, 'I-06')
    expectInt(r, 4, 15, 'I-06')
    expectInt(r, 5, 15, 'I-06')
    expectInt(r, 6, 255, 'I-06')
    expectLex(r, 0, '0x1F', 'I-06')
    expectNoErrors(r, 'I-06')
  })
  test('I-07 各进制溢出', () => {
    expectInt(lexAll('0x7FFFFFFFFFFFFFFF'), 0, 9223372036854775807n, 'I-07')
    const r2 = lexAll('0xFFFFFFFFFFFFFFFF')
    expectType(r2, 0, TokenType.Invalid, 'I-07')
    expectErrHas(r2, 'invalid integer.', 'I-07')
    expectType(lexAll('0xFFFFFFFFFFFFFFFFF'), 0, TokenType.Invalid, 'I-07')
  })
  test('I-08 空前缀', () => {
    const r = lexAll('0b 0x 0o 0b_ 0x_ 0o_')
    expectCount(r, 7, 'I-08')
    for (let i = 0; i < 6; ++i) expectType(r, i, TokenType.Invalid, 'I-08')
    expectErrCount(r, 6, 'I-08')
    expectErrHas(r, 'invalid integer.', 'I-08')
  })
  test('I-09 前缀后仅下划线（延后到转换阶段判定，属合法）', () => {
    const r = lexAll('0b_1 0x_1 0o_7')
    expectCount(r, 4, 'I-09')
    expectInt(r, 0, 1, 'I-09')
    expectInt(r, 1, 1, 'I-09')
    expectInt(r, 2, 7, 'I-09')
    expectNoErrors(r, 'I-09')
  })
  test('I-10 前缀后非法字符：分词边界', () => {
    expectSeq(lexAll('0xG'), 'Invalid Ident Eof', 'I-10')
    expectSeq(lexAll('0b2'), 'Invalid Integer Eof', 'I-10')
    expectSeq(lexAll('0o8'), 'Invalid Integer Eof', 'I-10')
  })
})

describe('T4 浮点 (LEX-N-F)', () => {
  test('F-01 基本小数', () => {
    const r = lexAll('1.0 1.5 .5 0.0')
    expectCount(r, 5, 'F-01')
    expectDbl(r, 0, 1.0, 'F-01')
    expectDbl(r, 1, 1.5, 'F-01')
    expectDbl(r, 2, 0.5, 'F-01')
    expectDbl(r, 3, 0.0, 'F-01')
    expectNoErrors(r, 'F-01')
  })
  test('F-02 指数（含指数一律浮点）', () => {
    const r = lexAll('1e5 1E5 1e+3 1E-3 .5e3')
    expectCount(r, 6, 'F-02')
    for (let i = 0; i < 5; ++i) expectType(r, i, TokenType.Float, 'F-02')
    expectDbl(r, 0, 100000.0, 'F-02')
    expectDbl(r, 1, 100000.0, 'F-02')
    expectDbl(r, 2, 1000.0, 'F-02')
    expectDbl(r, 3, 0.001, 'F-02')
    expectDbl(r, 4, 500.0, 'F-02')
  })
  test('F-03 小数部分下划线', () => {
    const r = lexAll('1_.5')
    expectDbl(r, 0, 1.5, 'F-03')
    expectParsed(r, 0, '1.5', 'F-03')
  })
  test('F-04 1..2 切成两个浮点', () => {
    const r = lexAll('1..2')
    expectCount(r, 3, 'F-04')
    expectDbl(r, 0, 1.0, 'F-04')
    expectDbl(r, 1, 0.2, 'F-04')
  })
  test('F-05 1.5.5 切成两个浮点', () => {
    const r = lexAll('1.5.5')
    expectCount(r, 3, 'F-05')
    expectDbl(r, 0, 1.5, 'F-05')
    expectDbl(r, 1, 0.5, 'F-05')
  })
  test('F-06 指数后无数字', () => {
    const r = lexAll('1e 1e+ .5e 1ex')
    expectCount(r, 6, 'F-06')
    for (let i = 0; i < 4; ++i) expectType(r, i, TokenType.Invalid, 'F-06')
    expectType(r, 4, TokenType.Ident, 'F-06')
    expectErrCount(r, 4, 'F-06')
    expectErrHas(r, 'invalid float.', 'F-06')
  })
  test('F-07 非法浮点', () => {
    const r = lexAll('. .e5 ._')
    expectCount(r, 4, 'F-07')
    for (let i = 0; i < 3; ++i) expectType(r, i, TokenType.Invalid, 'F-07')
    expectErrCount(r, 3, 'F-07')
  })
  test('F-08 小数部分以 _ 结尾：当前仍接受（C++ D-7 未修）', () => {
    expectDbl(lexAll('1._'), 0, 1.0, 'F-08-current')
  })
  test('F-09 浮点上溢/下溢', () => {
    const r = lexAll('1e999 1e-999')
    expectCount(r, 3, 'F-09')
    expectType(r, 0, TokenType.Invalid, 'F-09')
    expectType(r, 1, TokenType.Invalid, 'F-09')
    expectErrCount(r, 2, 'F-09')
  })
})

describe('T5 标识符与 : 命名空间 (LEX-I)', () => {
  test('D-01 合法标识符', () => {
    const r = lexAll('abc _x A9 _ __9')
    expectCount(r, 6, 'D-01')
    for (let i = 0; i < 5; ++i) expectType(r, i, TokenType.Ident, 'D-01')
    expectParsed(r, 0, 'abc', 'D-01')
    expectParsed(r, 3, '_', 'D-01')
    expectParsed(r, 4, '__9', 'D-01')
    expectNoErrors(r, 'D-01')
  })
  test('D-02 数字开头不是标识符', () => {
    expectSeq(lexAll('9a'), 'Integer Ident Eof', 'D-02')
  })
  test('D-03/D-04 : 分组', () => {
    expectParsed(lexAll('a:b'), 0, 'a:b', 'D-03')
    expectCount(lexAll('a:b'), 2, 'D-03')
    expectParsed(lexAll('a:b:c'), 0, 'a:b:c', 'D-04')
  })
  test('D-05 : 前后允许空白、换行、注释', () => {
    expectParsed(lexAll('a : b'), 0, 'a:b', 'D-05')
    const r2 = lexAll('a\n:b')
    expectCount(r2, 2, 'D-05')
    expectParsed(r2, 0, 'a:b', 'D-05')
    expectParsed(lexAll('a // c\n:b'), 0, 'a:b', 'D-05')
    expectParsed(lexAll('a :/*x*/ b'), 0, 'a:b', 'D-05')
  })
  test('D-06 a::b 的错误恢复', () => {
    const r = lexAll('a::b')
    expectSeq(r, 'Invalid Invalid Ident Eof', 'D-06')
    expectParsed(r, 0, 'a:', 'D-06')
    expectErrHas(r, 'unclosed identifier.', 'D-06')
    expectErrHas(r, 'unknown token.', 'D-06')
  })
  test('D-07 a:1', () => {
    const r = lexAll('a:1')
    expectSeq(r, 'Invalid Integer Eof', 'D-07')
    expectErrHas(r, 'unclosed identifier.', 'D-07')
  })
  test('D-08 输入末尾的 :', () => {
    const r = lexAll('a:')
    expectType(r, 0, TokenType.Invalid, 'D-08')
    expectErrHas(r, 'unclosed identifier.', 'D-08')
  })
  test('D-09 标识符的 lexeme 是源文本（C++ D-8 未修，那边恒为空）', () => {
    expectLex(lexAll('abc'), 0, 'abc', 'D-09')
  })
})

describe('T6 关键字 (LEX-K)', () => {
  test('K-01 全部关键字映射', () => {
    const cases = [
      ['idiv', TokenType.IDiv], ['not', TokenType.Not],
      ['and', TokenType.And], ['or', TokenType.Or],
      ['if', TokenType.If], ['elif', TokenType.Elif],
      ['else', TokenType.Else], ['let', TokenType.Let],
      ['return', TokenType.Return], ['while', TokenType.While],
      ['break', TokenType.Break], ['continue', TokenType.Continue],
      ['null', TokenType.Null], ['false', TokenType.False],
      ['true', TokenType.True], ['args', TokenType.Args],
      ['argc', TokenType.Argc], ['export', TokenType.Export],
    ]
    for (const [text, type] of cases) {
      expectType(lexAll(text), 0, type, `K-01 ${text}`)
    }
  })
  test('K-02 大小写敏感、全字匹配', () => {
    const r = lexAll('IF If iff if2')
    expectCount(r, 5, 'K-02')
    for (let i = 0; i < 4; ++i) expectType(r, i, TokenType.Ident, 'K-02')
  })
  test('K-03 关键字与符号写法同类型', () => {
    const kw = lexAll('not and or')
    const sym = lexAll('! && ||')
    expectType(kw, 0, TokenType.Not, 'K-03')
    expectType(kw, 1, TokenType.And, 'K-03')
    expectType(kw, 2, TokenType.Or, 'K-03')
    expectType(sym, 0, TokenType.Not, 'K-03')
    expectType(sym, 1, TokenType.And, 'K-03')
    expectType(sym, 2, TokenType.Or, 'K-03')
  })
})

describe('T7 字符串 (LEX-S)', () => {
  test('S-01/S-02 基本与空串', () => {
    const r = lexAll('"abc"')
    expectCount(r, 2, 'S-01')
    expectType(r, 0, TokenType.String, 'S-01')
    expectLex(r, 0, 'abc', 'S-01')
    const r2 = lexAll('""')
    expectType(r2, 0, TokenType.String, 'S-02')
    expectLex(r2, 0, '', 'S-02')
  })
  test('S-03/S-04 转义引号与反斜杠不终止字符串', () => {
    const r = lexAll('"a\\"b"')
    expectCount(r, 2, 'S-03')
    expectType(r, 0, TokenType.String, 'S-03')
    expectLex(r, 0, 'a\\"b', 'S-03')
    expectType(lexAll('"a\\\\b"'), 0, TokenType.String, 'S-04')
  })
  test('S-05 未闭合字符串', () => {
    const r = lexAll('"abc')
    expectType(r, 0, TokenType.Invalid, 'S-05')
    expectErrHas(r, 'unclosed string literal.', 'S-05')
  })
  test('S-06 反斜杠结尾：只报一次', () => {
    const r = lexAll('"abc\\')
    expectErrCount(r, 1, 'S-06')
    expectErrHas(r, 'unclosed string literal.', 'S-06')
  })
  test('S-07/S-08 转义解码', () => {
    expectParsed(lexAll('"a\\nb"'), 0, 'a\nb', 'S-08')
    expectErrHas(lexAll('"a\\qb"'), 'invalid escape character.', 'S-07')
  })
  test('S-09 非法转义后 parsed 截断且未置 Invalid（C++ D-14 未修）', () => {
    const r = lexAll('"a\\qb"')
    expectType(r, 0, TokenType.String, 'S-09-current')
    expectParsed(r, 0, 'a', 'S-09-current')
  })
  test('S-10 全部合法转义序列', () => {
    const r = lexAll('"\\\\ \\" \\\' \\b \\r \\t \\v \\n \\f"')
    expectType(r, 0, TokenType.String, 'S-10')
    expectParsed(r, 0, '\\ " \' \b \r \t \v \n \f', 'S-10')
    expectNoErrors(r, 'S-10')
  })
})

describe('T8 二进制数组 (LEX-B)', () => {
  test('B-01/B-02', () => {
    const r = lexAll("'abc'")
    expectType(r, 0, TokenType.BinArr, 'B-01')
    expectLex(r, 0, 'abc', 'B-01')
    const r2 = lexAll("''")
    expectType(r2, 0, TokenType.BinArr, 'B-02')
    expectLex(r2, 0, '', 'B-02')
  })
  test('B-03 相邻两个不合并', () => {
    expectSeq(lexAll("'a' 'b'"), 'BinArr BinArr Eof', 'B-03')
  })
  test('B-04 未闭合', () => {
    const r = lexAll("'abc")
    expectType(r, 0, TokenType.Invalid, 'B-04')
    expectErrHas(r, 'unclosed binary array.', 'B-04')
    expectType(r, 1, TokenType.Eof, 'B-04')
  })
  test('B-05 跨行累加 line', () => {
    const r = lexAll("'a\nb' c")
    expectType(r, 0, TokenType.BinArr, 'B-05')
    expectLine(r, 1, 2, 'B-05')
  })
  test('B-06 单引号内无转义机制', () => {
    const r = lexAll("'\\'' x")
    expectType(r, 0, TokenType.BinArr, 'B-06')
    expectLex(r, 0, '\\', 'B-06')
    expectType(r, 1, TokenType.Invalid, 'B-06')
    expectErrHas(r, 'unclosed binary array.', 'B-06')
  })
})

describe('T9 标点与运算符 (LEX-P)', () => {
  test('P-01 分隔符', () => {
    expectSeq(lexAll(', ; ( ) [ ] { }'),
      'Comma Semi LParen RParen LBrack RBrack LBrace RBrace Eof', 'P-01')
  })
  test('P-02 算术运算符', () => {
    expectSeq(lexAll('+ - * / % ^'), 'Add Sub Mul Div Mod Pow Eof', 'P-02')
  })
  test('P-03 赋值与相等', () => {
    expectSeq(lexAll('= == ==='), 'Assign EQ EQ Assign Eof', 'P-03')
  })
  test('P-04 非与不等', () => {
    expectSeq(lexAll('! != !=='), 'Not NE NE Assign Eof', 'P-04')
  })
  test('P-05 比较运算符：两字符优先', () => {
    expectSeq(lexAll('< <= > >='), 'LT LE GT GE Eof', 'P-05')
  })
  test('P-06 逻辑运算两种写法', () => {
    expectSeq(lexAll('&& and || or'), 'And And Or Or Eof', 'P-06')
  })
  test('P-07 单个 & 与 | 非法', () => {
    const r = lexAll('& |')
    expectSeq(r, 'Invalid Invalid Eof', 'P-07')
    expectErrCount(r, 2, 'P-07')
    expectErrHas(r, 'unknown token.', 'P-07')
  })
  test('P-08 非语言字符：每个码元一个 Invalid，且必须推进', () => {
    const r = lexAll('@ $ # ~ ?')
    expectCount(r, 6, 'P-08')
    for (let i = 0; i < 5; ++i) expectType(r, i, TokenType.Invalid, 'P-08')
    expectErrCount(r, 5, 'P-08')
    const r2 = lexAll('中文') // 两个 UTF-16 码元
    expectCount(r2, 3, 'P-08')
    expectErrCount(r2, 2, 'P-08')
  })
  test('P-09 标点 token 的 lexeme 是符号本身（C++ D-9 未修，那边恒为空）', () => {
    expectLex(lexAll('=='), 0, '==', 'P-09')
  })
  test('P-10 无空白相邻标点不粘连', () => {
    const r = lexAll('()')
    expectCount(r, 3, 'P-10')
    expectType(r, 0, TokenType.LParen, 'P-10')
    expectType(r, 1, TokenType.RParen, 'P-10')
  })
})

describe('T1 空白字符与注释 (LEX-W)', () => {
  test('W-01 空输入', () => {
    const r = lexAll('')
    expectCount(r, 1, 'W-01')
    expectType(r, 0, TokenType.Eof, 'W-01')
    expectNoErrors(r, 'W-01')
  })
  test('W-02 纯空白（含 \\v \\f \\r）', () => {
    const r = lexAll('   \t\v\f\r\n  ')
    expectCount(r, 1, 'W-02')
    expectType(r, 0, TokenType.Eof, 'W-02')
  })
  test('W-03/W-04 单行注释', () => {
    const r = lexAll('a // c\nb')
    expectSeq(r, 'Ident Ident Eof', 'W-03')
    expectLine(r, 0, 1, 'W-03')
    expectLine(r, 1, 2, 'W-03')
    expectSeq(lexAll('a // c'), 'Ident Eof', 'W-04')
  })
  test('W-05/W-06 多行注释', () => {
    expectSeq(lexAll('a /* x */ b'), 'Ident Ident Eof', 'W-05')
    const r2 = lexAll('a /*\nx\n*/ b')
    expectSeq(r2, 'Ident Ident Eof', 'W-06')
    expectLine(r2, 1, 3, 'W-06')
  })
  test('W-07 块注释不嵌套', () => {
    expectSeq(lexAll('/* a /* b */ c'), 'Ident Eof', 'W-07')
  })
  test('W-08 未闭合块注释：静默到 EOF（C++ D-6 未修）', () => {
    const r = lexAll('/* abc')
    expectCount(r, 1, 'W-08-current')
    expectType(r, 0, TokenType.Eof, 'W-08-current')
    expectNoErrors(r, 'W-08-current')
  })
  test('W-09/W-10 退化注释', () => {
    expectCount(lexAll('//'), 1, 'W-09')
    const r2 = lexAll('/*/')
    expectCount(r2, 1, 'W-10')
    expectType(r2, 0, TokenType.Eof, 'W-10')
  })
})

describe('T2 行号 (LEX-L)', () => {
  test('L-01 只有 \\n 计数（\\r 不计数）', () => {
    const r = lexAll('1\n2\n\n3\r\n4')
    expectCount(r, 5, 'L-01')
    expectLine(r, 0, 1, 'L-01')
    expectLine(r, 1, 2, 'L-01')
    expectLine(r, 2, 4, 'L-01')
    expectLine(r, 3, 5, 'L-01')
  })
  test('L-02 尾部换行', () => {
    expectLine(lexAll('a\nb\n'), 2, 3, 'L-02')
  })
  test('L-03 跨行 BinArr 累加行', () => {
    expectLine(lexAll("'a\nb' c"), 1, 2, 'L-03')
  })
  test('L-04 跨行字符串不累加行（C++ D-13 未修）', () => {
    expectLine(lexAll('"a\nb" c'), 1, 1, 'L-04-current')
  })
  test('L-05 跨行标识符', () => {
    const r = lexAll('a\n:b c')
    expectParsed(r, 0, 'a:b', 'L-05')
    expectLine(r, 1, 2, 'L-05')
  })
  test('L-06 错误行号', () => {
    const r = lexAll('1\n@')
    expectLine(r, 1, 2, 'L-06')
    expectErrHas(r, 'line 2: unknown token.', 'L-06')
  })
})

describe('T11 错误处理与恢复 (LEX-E)', () => {
  test('E-01 七条 error 文案全覆盖', () => {
    const cases = [
      ['@', 'unknown token.'],
      ['"abc', 'unclosed string literal.'],
      ["'abc", 'unclosed binary array.'],
      ['9223372036854775808', 'invalid integer.'],
      ['.', 'invalid float.'],
      ['a:', 'unclosed identifier.'],
      ['"a\\qb"', 'invalid escape character.'],
    ]
    for (const [src, msg] of cases) {
      expectErrHas(lexAll(src), msg, `E-01 ${JSON.stringify(src)}`)
    }
  })
  test('E-02 错误累加且带行号前缀', () => {
    const r = lexAll('@ @ @')
    expectErrCount(r, 3, 'E-02')
    if (!r.errors[0].startsWith('line 1: ')) {
      throw new Error(`[E-02] 期望 errors[0] 以 'line 1: ' 开头，实际 ${JSON.stringify(r.errors[0])}`)
    }
  })
  test('E-03 出错后必须继续推进到 Eof（不死循环）', () => {
    const r = lexAll('@$#~?@$#')
    expectType(r, r.tokens.length - 1, TokenType.Eof, 'E-03')
  })
  test('E-04 代理对（emoji）按 UTF-16 码元计数', () => {
    expectErrCount(lexAll('\u{1F600}'), 2, 'E-04')
  })
})

describe('T12 Token 状态与生命周期 (LEX-T)', () => {
  test('T12-1 连续取词不得串味', () => {
    const lx = new Lexer('alpha beta gamma')
    if (lx.NextToken().parsed !== 'alpha') throw new Error('[T12-1] 第一个 token 不是 alpha')
    if (lx.NextToken().parsed !== 'beta') throw new Error('[T12-1] 第二个 token 不是 beta')
    if (lx.NextToken().parsed !== 'gamma') throw new Error('[T12-1] 第三个 token 不是 gamma')
    const eof = lx.NextToken()
    if (eof.parsed !== '' || eof.type !== TokenType.Eof) throw new Error('[T12-1] 结尾不是空 Eof')
  })
  test('T12-2 复用 Lexer 实例跑第二条输入', () => {
    const lx = new Lexer('abc')
    lx.NextToken()
    lx.Reset('123')
    if (lx.NextToken().type === TokenType.Invalid) throw new Error('[T12-2] 复用后取词失败')
  })
  test('T12-4 Eof token 的字段', () => {
    const t = lexAll('').tokens[0]
    if (t.type !== TokenType.Eof) throw new Error('[T12-4] type 不是 Eof')
    if (t.lexeme !== '' || t.parsed !== '') throw new Error('[T12-4] lexeme/parsed 应为空')
  })
})

describe('T14 健壮性下限 (LEX-R)', () => {
  test('R-01 空/空白/纯注释', () => {
    expectType(lexAll(''), 0, TokenType.Eof, 'R-01')
    expectType(lexAll('   '), 0, TokenType.Eof, 'R-01')
    const r3 = lexAll('// x\n/* y */')
    expectType(r3, 0, TokenType.Eof, 'R-01')
    expectNoErrors(r3, 'R-01')
  })
  test('R-02 超长标识符', () => {
    const r = lexAll('a'.repeat(10000))
    expectCount(r, 2, 'R-02')
    expectType(r, 0, TokenType.Ident, 'R-02')
  })
  test('R-03 深嵌套括号不栈溢出', () => {
    const r = lexAll('('.repeat(1000))
    expectCount(r, 1001, 'R-03')
    expectNoErrors(r, 'R-03')
  })
  test('R-04 未闭合引号交替：不死循环、error 数有限', () => {
    const r = lexAll('"\''.repeat(100))
    expectType(r, r.tokens.length - 1, TokenType.Eof, 'R-04')
    if (r.errors.length >= 500) throw new Error(`[R-04] error 过多：${r.errors.length}`)
  })
  test('R-05 孤立 :', () => {
    const r = lexAll(':')
    expectType(r, 0, TokenType.Invalid, 'R-05')
    expectErrHas(r, 'unknown token.', 'R-05')
  })
})

describe('T10 自定义指令 (LEX-C)', () => {
  test('C-01 不传配置也能正常工作', () => {
    const r = lexAll('myop')
    expectType(r, 0, TokenType.Ident, 'C-01')
    expectNoErrors(r, 'C-01')
  })
  test('C-02/C-04 命中与未命中', () => {
    const cfg = new CustomOpcodeConfig()
    cfg.addCustomOpcode('myop', 100, 2) // 编号照 C++ 侧用例取 100
    const r = lexAll('myop', cfg)
    expectType(r, 0, TokenType.Custom, 'C-02')
    expectParsed(r, 0, 'myop', 'C-02')
    expectType(lexAll('other', cfg), 0, TokenType.Ident, 'C-04')
  })
  test('C-03 含 : 的自定义指令名（含空白写法）', () => {
    const cfg = new CustomOpcodeConfig()
    cfg.addCustomOpcode('a:b', 103, 1)
    expectType(lexAll('a:b', cfg), 0, TokenType.Custom, 'C-03')
    expectType(lexAll('a : b', cfg), 0, TokenType.Custom, 'C-03')
  })
  test('C-05 关键字优先于自定义指令', () => {
    const cfg = new CustomOpcodeConfig()
    cfg.addCustomOpcode('if', 101, 1)
    expectType(lexAll('if', cfg), 0, TokenType.If, 'C-05')
  })
  test('C-06 重复注册返回 DuplicateWithBuiltinOpcode', () => {
    const cfg = new CustomOpcodeConfig()
    cfg.addCustomOpcode('myop', 100, 2)
    if (cfg.addCustomOpcode('myop', 102, 1) !== Result.DuplicateWithBuiltinOpcode) {
      throw new Error('[C-06] 重复注册没有返回 DuplicateWithBuiltinOpcode')
    }
  })
})

describe('T13 端到端 token 流 (LEX-E2E)', () => {
  test('G-01', () => {
    const r = lexAll('let a = 1 + 2 * 3;')
    expectSeq(r, 'Let Ident Assign Integer Add Integer Mul Integer Semi Eof', 'G-01')
    expectNoErrors(r, 'G-01')
  })
  test('G-02', () => {
    expectSeq(lexAll('if a >= 1 and b != 2 { return; } elif c { } else { }'),
      'If Ident GE Integer And Ident NE Integer LBrace Return Semi RBrace ' +
      'Elif Ident LBrace RBrace Else LBrace RBrace Eof', 'G-02')
  })
  test('G-03', () => {
    expectSeq(lexAll('while true { break; continue; }'),
      'While True LBrace Break Semi Continue Semi RBrace Eof', 'G-03')
  })
  test('G-04 各进制与字面量混排', () => {
    const r = lexAll('export foo:bar = "s", \'x\', null, argc, args;')
    expectSeq(r, 'Export Ident Assign String Comma BinArr Comma Null Comma Argc Comma Args Semi Eof',
      'G-04')
    expectParsed(r, 0, 'export', 'G-04')
    expectParsed(r, 1, 'foo:bar', 'G-04')
  })
  test('G-05 混合片段：注释、空行、跨行标识符、行号', () => {
    const r = lexAll('// head\nlet a\n:b = 0x10;\n\n/* mid */ return .5e2;')
    expectSeq(r, 'Let Ident Assign Integer Semi Return Float Semi Eof', 'G-05')
    expectParsed(r, 1, 'a:b', 'G-05')
    expectInt(r, 3, 16, 'G-05')
    expectDbl(r, 6, 50.0, 'G-05')
    expectLine(r, 6, 5, 'G-05')
    expectNoErrors(r, 'G-05')
  })
})
