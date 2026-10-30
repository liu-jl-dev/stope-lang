// Demo 02: STML —— 解析一份内嵌的标记文档，把里面的代码段原样切出来。
// 对应 cpp/demo/02-stml.cpp 与 gdscript/demo/demo_02.gd：**只解析**，不编译也不执行 ——
// 接过 text 之后干什么完全是宿主的事。
//
// 运行：node demo/02-stml.js
//
// STML 是「两半」：树的形状由 StmlParser 管（标签名、属性、嵌套、结束标签是否配对），
// 内容怎么切由宿主管 —— 就是传给 Parse() 的那个 stateFunc 回调，它决定
// 「这个标签的内容是子元素 / 纯文本 / Nevext 代码 / Stope 代码」。

import {
  StmlLexer,
  StmlParser,
  StmlElement,
  StmlState,
  Result,
} from '../src/index.js'

const doc = `
<stml package="MyPkg">

<config>
  windowTitle "demo";
  windowSize 1280, 720
</config>
<func name="myFunc" stope>
  let a = 1;
  return a + argc;
</func>
<class name="Person">
  <property name="name" />
  <property name="age" />
  <method name="greet" />
</class>

</stml>
`

// 宿主回调：读完开始标签、还没进内容时调用一次，返回值决定这段内容怎么扫。
//   <config>             -> Nevext 代码
//   带 stope 属性的元素   -> Stope 代码
//   其余                 -> Xml（按子元素列表解析）
function stateFunc(tag, attrs) {
  if (tag === 'config') return StmlState.Nevext
  if (attrs.has('stope')) return StmlState.Stope
  return StmlState.Xml
}

// 按名字找，别写死下标 —— 下标会随空行/注释变。
function childByTag(ele, tag) {
  for (const c of ele.children) if (c.tag === tag) return c
  return null
}

const lexer = new StmlLexer(doc)
const parser = new StmlParser(lexer)
const root = new StmlElement()
if (parser.Parse(root, stateFunc) !== Result.Success) {
  for (const e of lexer.errors) console.error('[lex] ' + e)
  for (const e of parser.errors) console.error('[parse] ' + e)
  process.exit(1)
}

console.log(`[1] 根元素 <${root.tag}>，属性 package="${root.attrs.get('package')}"`)
console.log('[2] 它的直接子元素：')
for (const c of root.children) console.log('  ' + c.tag)

const funcEle = childByTag(root, 'func')
const classEle = childByTag(root, 'class')
console.log('[3] <class> 的子元素：')
for (const c of classEle.children) {
  console.log('  ' + c.tag + (c.selfClosing ? '(自闭合)' : ''))
}

// 代码段原样切出来：换行是真的换行，缩进也保留（尾部空白已被词法裁掉）。
// 拿到它交给 Lexer 就能编译执行（见 01-quick-start.js）—— STML 不管代码写得对不对。
console.log('[4] <func> 里的 Stope 代码段：')
console.log(funcEle.text)
