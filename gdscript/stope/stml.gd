class_name STML

class Element:
	var line:int
	var tag:String  # 标签名，tag name
	var attrs:Dictionary[String,String] # attributes
	var self_closing:bool
	var children:Array[Element]
	var text:String = ''
	var text_begin_line:int = -1
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
	enum Type {
		Invalid,
		Eof,
		LAngle, #  <
		RAngle, #  >
		CLAngle, #  </
		CRAngle, #  />
		EQ,     #  =
		Word,   # ^[a-zA-Z_:][a-zA-Z0-9_.:-]*$
		Str,    #  ""  ''
		Text,   # 一般元素中的文本
		NevSrc,  #  Nevext 脚本
		StoSrc,  #  Stope 脚本
	}
	static func type_name(enu:int) -> String: return Type.keys()[enu]
	
	var line:int
	var type:int
	var lexeme:String # 词素、词位，表示具体字符序列
	func set_(t:int, l:String): type = t; lexeme = l






























