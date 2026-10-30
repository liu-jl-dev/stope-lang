// STML 的公共类型：元素与 Token —— 对应 cpp/include/stope/stml.hpp。
// 契约见 docs/zh-cn/stml-test-plan.md，权威实现是 C++ 的
// stml_lexer.hpp + stml_parser.hpp。
//
// 元素模型只有 6 个字段（与 C++ 的 STML::Element 一一对应），不要加字段：
// 形状串与跨实现比对都按这 6 项来。

// 12 项，与 C++ 的 STML::TokenType 一一对应：**值和名字都一样**。
// 所以打印类型名直接用 TokenType[t]，不需要再映射一层。
export const TokenType = {}
TokenType[TokenType['Invalid'] = 0] = 'Invalid'
TokenType[TokenType['Eof'] = 1] = 'Eof'
TokenType[TokenType['LAngle'] = 2] = 'LAngle' // <
TokenType[TokenType['RAngle'] = 3] = 'RAngle' // >
TokenType[TokenType['CLAngle'] = 4] = 'CLAngle' // </>
TokenType[TokenType['CRAngle'] = 5] = 'CRAngle' // />
TokenType[TokenType['EQ'] = 6] = 'EQ' // =
TokenType[TokenType['Word'] = 7] = 'Word' // ^[a-zA-Z_:][a-zA-Z0-9_:-]*$（不含 '.'）
TokenType[TokenType['String'] = 8] = 'String' // "" '' —— Xml 属性串，不转义
TokenType[TokenType['Text'] = 9] = 'Text' // 元素内普通文本
TokenType[TokenType['NevextSrc'] = 10] = 'NevextSrc' // Nevext 代码
TokenType[TokenType['StopeSrc'] = 11] = 'StopeSrc' // Stope 代码
Object.freeze(TokenType)

class Element {
  constructor() {
    this.line = -1
    this.tag = '' // 标签名
    this.attrs = new Map() // attributes，无值属性的值是空串
    this.selfClosing = false
    this.children = []
    this.text = '' // 与 children 互斥；只有一段，不拼接
  }

  // 调试用：不一定与源文本逐字符相同（属性顺序、自闭合写法都不保留）
  toStr(level = 0) {
    const sp = '  '.repeat(level)
    let o = sp + '<' + this.tag
    for (const [name, value] of this.attrs) {
      o += ' ' + name + (value !== '' ? `="${value}"` : '')
    }
    if (this.selfClosing) {
      o += ' />\n'
    } else {
      o += '>\n' + this.text
      for (const c of this.children) o += c.toStr(level + 1)
      o += sp + '</' + this.tag + '>\n'
    }
    return o
  }
}

class Token {
  constructor() {
    this.line = -1
    this.type = TokenType.Invalid
    this.lexeme = '' // 词素、词位，表示具体字符序列
  }
  set(t, l) {
    this.type = t
    this.lexeme = l
  }
}

export { Element, Token }
