// Demo 02：STML —— 解析一份标记文档，把里面的代码段原样切出来。
//
// STML 是「两半」：树的形状（标签、属性、嵌套、结束标签是否配对）由 StmlParser 管；
// 「某个元素的内容怎么切」由宿主的回调决定 —— 是子元素、纯文本，还是一段代码。
//
// 只解析，不编译也不执行：拿到 text 之后干什么完全是宿主的事。
//
// 运行：go run ./cmd/demo02
package main

import (
	"fmt"
	"os"
	"strings"

	"stope/stml"
)

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

// contentKind 宿主回调：读完开始标签、还没进内容时调用一次，返回值决定这段内容怎么扫。
func contentKind(tag string, attrs map[string]string) stml.LexerState {
	if tag == "config" {
		return stml.NevextState // 一段 Nevext 代码，整段原样保留
	}
	if _, ok := attrs["stope"]; ok {
		return stml.StopeState // 一段 Stope 代码
	}
	return stml.XmlState // 默认：内容是子元素列表
}

// childByName 按名字找子元素 —— 别写死下标，空行和注释都会让它变。
func childByName(ele *stml.Element, tag string) *stml.Element {
	for _, c := range ele.Children {
		if c.Tag == tag {
			return c
		}
	}
	return nil
}

func main() {
	lexer := stml.NewLexer(doc, stml.XmlState)
	parser := stml.NewParser(lexer)
	root := stml.NewElement()
	if parser.Parse(root, contentKind) != stml.Success {
		var all []string
		all = append(all, lexer.Errors...)
		all = append(all, parser.Errors...)
		fmt.Fprintln(os.Stderr, strings.Join(all, "\n"))
		os.Exit(1)
	}

	fmt.Printf("[1] 根元素 <%s>，属性 package=\"%s\"\n", root.Tag, root.Attr("package"))
	fmt.Println("[2] 它的直接子元素：")
	for _, c := range root.Children {
		fmt.Println("  " + c.Tag)
	}

	fmt.Println("[3] <class> 的子元素：")
	for _, c := range childByName(root, "class").Children {
		suffix := ""
		if c.SelfClosing {
			suffix = "(自闭合)"
		}
		fmt.Println("  " + c.Tag + suffix)
	}

	// 代码段是原样的一整段字符串：换行是真的换行、缩进保留（只有尾部空白被词法裁掉）。
	// 拿到它交给 stope.Lexer 就能编译执行（见 01）—— STML 不管代码写得对不对。
	fmt.Println("[4] <func> 里的 Stope 代码段：")
	fmt.Println(childByName(root, "func").Text)
}
