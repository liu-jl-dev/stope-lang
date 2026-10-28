class_name STML

# STML 的公共类型：元素与 Token。契约见 docs/zh-cn/stml-test-plan.md，
# 权威实现是 cpp/include/stope/stml_lexer.hpp + stml_parser.hpp。
#
# 元素模型只有 6 个字段（与 C++ 的 STML::Element 一一对应），不要加字段：
# 形状串与两侧比对都按这 6 项来。
class Element:
	var line:int = -1
	var tag:String  # 标签名，tag name
	var attrs:Dictionary[String,String] # attributes，无值属性的值是空串
	var self_closing:bool
	var children:Array[Element]
	var text:String = ''  # 与 children 互斥；只有一段，不拼接
	# 调试用：不一定与源文本逐字符相同（属性顺序、自闭合写法都不保留）
	func to_str(level:int=0) -> String:
		var sp := ''; for i in range(level): sp += '  '
		var o := str(sp,'<',tag,)
		for name in attrs: o += str(' ',name,str('="',attrs[name],'"') if attrs[name]!='' else '')
		if self_closing: o += ' />\n'
		else:
			o += str('>\n',text)
			for c in children: o += c.to_str(level + 1)
			o += str(sp,'</',tag,'>\n')
		return o

class Token:
	# 12 项，与 C++ 的 STML::TokenType 一一对应：**值和名字都一样**。
	# 所以打印类型名直接 Type.keys()[t] 就是 C++ 那套拼写，不需要再映射一层。
	enum Type {
		Invalid,
		Eof,
		LAngle,     #  <
		RAngle,     #  >
		CLAngle,    #  </
		CRAngle,    #  />
		EQ,         #  =
		Word,       # ^[a-zA-Z_:][a-zA-Z0-9_:-]*$  （不含 '.'）
		String,     #  ""  '' —— Xml 属性串，不转义
		Text,       # 元素内普通文本
		NevextSrc,  #  Nevext 代码
		StopeSrc,   #  Stope 代码
	}

	var line:int
	var type:int
	var lexeme:String # 词素、词位，表示具体字符序列
	func set_(t:int, l:String): type = t; lexeme = l
