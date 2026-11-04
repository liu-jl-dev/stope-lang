package stope

// 指令集与自定义指令登记表。33 条内置指令，编号与 C++ 的 stope::Opcode 逐项相同（0..32）。

// Opcode 内置指令编号。
type Opcode int

const (
	OpAssign Opcode = iota
	OpPushNull
	OpPushFalse
	OpPushTrue
	OpPushInt
	OpPushFloat
	OpPushString
	OpPushBinArr
	OpPushValue
	OpPushId

	OpCall
	OpAt
	OpPop
	OpMinus
	OpNot
	OpPow
	OpMul
	OpDiv
	OpIDiv
	OpMod

	OpAdd
	OpSub
	OpEQ
	OpNE
	OpLT
	OpLE
	OpGT
	OpGE
	OpIf
	OpGoTo

	OpGetArg
	OpArgNum
	OpReturn

	// KOpCount 内置指令总数（33）。
	KOpCount
)

// KFirstCustomOpcode 第一个可用的自定义指令编号（= Return + 1）。
const KFirstCustomOpcode = int(OpReturn) + 1

// OpcodeName 下标即编号，与枚举逐项对应（反汇编用）。
var OpcodeName = []string{
	"Assign", "PushNull", "PushFalse", "PushTrue", "PushInt",
	"PushFloat", "PushString", "PushBinArr", "PushValue", "PushId",
	"Call", "At", "Pop", "Minus", "Not",
	"Pow", "Mul", "Div", "IDiv", "Mod",
	"Add", "Sub", "EQ", "NE", "LT",
	"LE", "GT", "GE", "If", "GoTo",
	"GetArg", "ArgNum", "Return",
}

// CustomOpcode 一条自定义指令的登记项。
//
// ArgNum < 0 表示变长（产物里不带参数）；定长时产物紧跟一个操作数（参数个数）。
type CustomOpcode struct {
	Opcode    int
	ArgNum    int
	IsVarArg  bool
}

// CustomOpcodeConfig 名字 → CustomOpcode 的登记表。
//
// Lexer / Parser / Compiler 必须共用同一个对象。名字是普通标识符或命名空间形式
// a:b（词法器保证），且关键字优先 —— 注册一个叫 if 的指令是无效的。
type CustomOpcodeConfig struct {
	Opcodes map[string]CustomOpcode
	// Order 登记顺序（demo 打印用；golden 比对不受影响，它们按名字排序）。
	Order []string
}

// NewCustomOpcodeConfig 构造空表。
func NewCustomOpcodeConfig() *CustomOpcodeConfig {
	return &CustomOpcodeConfig{Opcodes: make(map[string]CustomOpcode)}
}

// AddCustomOpcode 登记一条自定义指令；同名重复返回 RDuplicateWithBuiltinOpcode 且不插入。
func (c *CustomOpcodeConfig) AddCustomOpcode(name string, opcode int, argNum int) Result {
	if _, ok := c.Opcodes[name]; ok {
		return RDuplicateWithBuiltinOpcode
	}
	c.Opcodes[name] = CustomOpcode{Opcode: opcode, ArgNum: argNum, IsVarArg: argNum < 0}
	c.Order = append(c.Order, name)
	return RSuccess
}
