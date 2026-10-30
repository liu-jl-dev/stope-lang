// 二进制数组字面量【内容】的解析 —— 端口 cpp/src/parse_binarr.cpp。
//
// 规则见 docs/zh-cn/syntax-reference.md §2.6，与 C++ 逐条一致：
//   - b/B o/O d/D x/X 前缀选进制；没有前缀按 16（首字符就是数据本身，不能被吃掉）
//   - 每段数字产生一个字节，依次追加；段内可含 '_'，段之间用空白分隔
//   - 超出一个字节的值【静默截断】到低 8 位且不报错：'d 300' -> 0x2C
//   - 出现该进制不允许的字符（如 'x zz'）-> 返回 Error，由上层报 invalid binary array.
//   - 空内容合法，得到零长数组；只有前缀没有数据（如 'b'）同样是零长数组
//
// 注意岔路：'b 0100 0001' 是两个字节 04 01，不是 0x41 —— 二进制前缀下要写满 8 位。
//
// 与 C++ 的 BinaryArrayParser::parseBinaryArray(input, output) -> Result 同形：
//   const bytes = []
//   if (new BinaryArrayParser().parseBinaryArray('x 41 42', bytes) !== Result.Success) …
// 失败时 bytes 可能已经写入了前半段，调用方负责丢弃（parser 走「报错但继续」的路径）。

import { Result } from './common.js'

const INT_MAX = 2147483647

const isWs = (c) =>
  c === ' ' || c === '\t' || c === '\n' || c === '\r' || c === '\v' || c === '\f'

// 返回该进制下的数值；不是该进制的字符返回 -1
function digitOf(c, base) {
  const code = c.charCodeAt(0)
  let d = -1
  if (code >= 48 && code <= 57) d = code - 48
  else if (code >= 97 && code <= 102) d = code - 97 + 10
  else if (code >= 65 && code <= 70) d = code - 65 + 10
  return d >= 0 && d < base ? d : -1
}

class BinaryArrayParser {
  constructor() {
    this.input = ''
    this.pos = 0
  }

  // 解析 input（不含单引号），字节按顺序 push 进 output（普通数组，元素 0..255）
  parseBinaryArray(input, output) {
    this.input = input
    this.pos = 0
    this.skipWs()
    if (this.eof()) return Result.Success
    const c = this.input[this.pos]
    let base = 16
    if (c === 'b' || c === 'B') {
      this.pos += 1
      base = 2
    } else if (c === 'o' || c === 'O') {
      this.pos += 1
      base = 8
    } else if (c === 'd' || c === 'D') {
      this.pos += 1
      base = 10
    } else if (c === 'x' || c === 'X') {
      this.pos += 1
      base = 16
    }
    return this.parseByBase(output, base)
  }

  parseByBase(output, base) {
    this.skipWs()
    while (!this.eof()) {
      const iv = this.parseInteger(base)
      if (!iv.ok) return Result.Error
      output.push(iv.value & 0xff) // 超 0xFF 静默截断，等价于 C++ 的 static_cast<char>
      this.skipWs()
    }
    return Result.Success
  }

  // 空段（只有下划线）与超出 int 范围的段都判失败 —— 与 std::stoi 抛异常等价。
  parseInteger(base) {
    let n = 0
    let any = false
    while (!this.eof()) {
      const c = this.input[this.pos]
      if (isWs(c)) break
      const d = digitOf(c, base)
      if (d >= 0) {
        if (n > (INT_MAX - d) / base) return { ok: false, value: 0 }
        n = n * base + d
        this.pos += 1
        any = true
      } else if (c === '_') {
        this.pos += 1
      } else {
        this.pos += 1
        return { ok: false, value: 0 }
      }
    }
    if (!any) return { ok: false, value: 0 }
    return { ok: true, value: n }
  }

  eof() {
    return this.pos >= this.input.length
  }

  skipWs() {
    while (!this.eof() && isWs(this.input[this.pos])) this.pos += 1
  }
}

export { BinaryArrayParser }
