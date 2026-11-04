// Package basicvm 是内置的参考执行器 —— 端口 cpp/include/stope/basic_vm.hpp 与
// python/stope/basic_vm.py。**这不是标准**：Stope 只规定语言、STML 与编译产物
// Program；执行器的接口、值的表示、栈布局、宿主函数约定全属实现自由。
//
// 值的 Go 表示（对应 C++ 的 Value::Type）：
//
//	Null         nil
//	Integer      int64（溢出回绕：Go 规范保证有符号溢出 wrap）
//	Float        float64
//	String       string（下标 / 长度按 UTF-16 码元）
//	BinArr       []byte
//	HostFunction HostFunction（func(argv []Value) Value）
//	Identifier   Identifier 实例（PushId 压的槽位引用，只有 Assign 认它）
//
// ⚠ C++ 里没有 Bool 值类型：PushTrue / PushFalse 压的是 Integer 1 / 0，所以
// true == 1 在运行期为真。宿主函数返回 Go 的 bool 时由 Normalize 归一成整数。
package basicvm

import (
	"strconv"
	"unicode/utf16"

	"stope"
)

// Value 运行期值。
type Value = any

// HostFunction 宿主函数 —— 一个值，直接放变量槽，Call 指令就能调到它。
// 返回 Go 的 bool 会被归一成整数 1 / 0。
type HostFunction func(argv []Value) Value

// Identifier 槽位引用。PushId 压它（左值），Assign 靠它取槽位；其余指令当普通值。
type Identifier struct{ Index int }

// Arguments 宿主的实参表。取不到就自己报错：At 里先调 state.Error(...) 再返回 nil。
type Arguments interface {
	At(state *State, key Value) Value
	Num() int
}

// Normalize 宿主可能返回 bool（宿主语言里有这个类型，Stope 没有）：折成整数 1 / 0。
func Normalize(v Value) Value {
	switch x := v.(type) {
	case bool:
		if x {
			return int64(1)
		}
		return int64(0)
	case int:
		return int64(x)
	}
	return v
}

// ============================== 类型判定 ==============================

func isInt(v Value) bool    { _, ok := v.(int64); return ok }
func isFloat(v Value) bool  { _, ok := v.(float64); return ok }
func isNumber(v Value) bool { return isInt(v) || isFloat(v) }
func isString(v Value) bool { _, ok := v.(string); return ok }
func isBinarr(v Value) bool { _, ok := v.([]byte); return ok }
func isFunc(v Value) bool   { _, ok := v.(HostFunction); return ok }
func isSequence(v Value) bool { return isString(v) || isBinarr(v) }
func isNull(v Value) bool   { return v == nil }

func asDouble(v Value) float64 {
	if i, ok := v.(int64); ok {
		return float64(i)
	}
	return v.(float64)
}

// ============================== 真值 / 相等 ==============================

// Truely null→假；整数/宿主函数→非零/真；浮点→非 0；序列→非空；其余→真。
func Truely(val Value) bool {
	switch x := val.(type) {
	case nil:
		return false
	case int64:
		return x != 0
	case HostFunction:
		return true
	case float64:
		return x != 0.0
	case string:
		return len(x) != 0
	case []byte:
		return len(x) != 0
	}
	return true
}

// Equals 类型不同一律不等（不借宿主的 ==）。
func Equals(left, right Value) bool {
	if left == nil || right == nil {
		return left == nil && right == nil
	}
	li, lok := left.(int64)
	ri, rok := right.(int64)
	lf, lfok := left.(float64)
	rf, rfok := right.(float64)
	if lok && rok {
		return li == ri
	}
	if lok && rfok {
		return float64(li) == rf
	}
	if lfok && rok {
		return lf == float64(ri)
	}
	if lfok && rfok {
		return lf == rf
	}
	ls, lsok := left.(string)
	rs, rsok := right.(string)
	if lsok && rsok {
		return ls == rs
	}
	lb, lbok := left.([]byte)
	rb, rbok := right.([]byte)
	if lbok && rbok {
		return string(lb) == string(rb)
	}
	lfn, lfok2 := left.(HostFunction)
	rfn, rfok2 := right.(HostFunction)
	if lfok2 && rfok2 {
		// Go 的函数值不可比较；这里比较指针语义由调用方保证，取 false 与
		// 「不同实例」一致（同一实例的相等在 Stope 里没有用例依赖）。
		_ = lfn
		_ = rfn
		return false
	}
	return false
}

func lessThan(s *State, left, right Value) bool {
	if isNumber(left) && isNumber(right) {
		return asDouble(left) < asDouble(right)
	}
	s.Error("only on integer or float can be compared. ")
	return false
}

func greaterThan(s *State, left, right Value) bool {
	return lessThan(s, right, left)
}

func checkArith(s *State, op string, left, right Value) bool {
	if left == nil || right == nil {
		s.Error("\"" + op + "\" cannot operate on null. ")
		return false
	}
	if !isNumber(left) || !isNumber(right) {
		s.Error("\"" + op + "\" can only operate on integer or float. ")
		return false
	}
	return true
}

// checkIntZero 整数除以 0 → 报错（不做除法）。判定看运算走哪条路径：只有两侧都是
// 整数才是整数除法；任一侧是 Float 就走 IEEE，不拦。
func checkIntZero(s *State, op string, left, right Value) bool {
	if isInt(left) && isInt(right) && right.(int64) == 0 {
		s.Error("\"" + op + "\" division by zero. ")
		return false
	}
	return true
}

// ============================== State ==============================

// State 指令指针 + 变量槽 + 求值栈 + 错误列表。
type State struct {
	Api       *Api
	Program   *stope.Program
	Args      Arguments
	Returns   []Value
	I         int
	Variables []Value
	Stack     []Value
	Errors    []string
}

// SetApi 绑定指令表。
func (s *State) SetApi(api *Api) { s.Api = api }

// SetProgram 绑定程序：按 VariableNum 开好槽位、I 归零、清运行态。
//（C++ 侧那句必写的 state.variables.resize(...) 在这里由 SetProgram 代做。）
func (s *State) SetProgram(program *stope.Program) {
	s.Program = program
	s.Returns = nil
	s.I = 0
	s.Variables = make([]Value, program.VariableNum)
	s.Stack = nil
	s.Errors = nil
}

// SetArguments 换实参表。
func (s *State) SetArguments(args Arguments) { s.Args = args }

// Error 宿主的报错入口："<指令下标>: msg"。
func (s *State) Error(msg string) {
	s.Errors = append(s.Errors, strconv.Itoa(s.I)+": "+msg)
}

// HasError 是否已有错误。
func (s *State) HasError() bool { return len(s.Errors) > 0 }

// Step 执行一条指令。RSuccess = 这条跑完了且没出错，可以接着 step。
//
// 返回 RError 有两种情况，靠 Errors 区分：
//   - Errors 非空 —— 出错了，I 停在出错的那条指令上；
//   - Errors 为空 —— 指令流已经走完（I 越过末尾）。
func (s *State) Step() stope.Result {
	if len(s.Errors) > 0 {
		return stope.RError
	}
	if s.I >= len(s.Program.Opcodes) {
		return stope.RSuccess
	}
	s.Api.OpMap[s.Program.Opcodes[s.I]](s)
	if len(s.Errors) > 0 {
		return stope.RError
	}
	s.I++
	return stope.RSuccess
}

// Run 一直执行到指令流结束；出错立即停。与 Step 是【两份独立实现】
//（热循环里不套一层函数调用），由测试锁两条路径一致。
func (s *State) Run() stope.Result {
	ops := s.Program.Opcodes // 执行中不会变长（Return 只是把 I 拨到末尾）
	n := len(ops)
	opMap := s.Api.OpMap
	for s.I < n {
		opMap[ops[s.I]](s)
		if len(s.Errors) > 0 {
			return stope.RError
		}
		s.I++
	}
	return stope.RSuccess
}

// 栈顶下标一律「从栈顶数、1 起算」：atTop(1) 就是 Stack[len-1]
func (s *State) atTop(k int) Value {
	return s.Stack[len(s.Stack)-k]
}

func (s *State) pop() { s.Stack = s.Stack[:len(s.Stack)-1] }

func (s *State) popN(num int) { s.Stack = s.Stack[:len(s.Stack)-num] }

func (s *State) pushInt(v int64) { s.Stack = append(s.Stack, v) }

// storeBinary 二元算术统一的收尾：弹出右操作数，结果写回左操作数的位置。
func (s *State) storeBinary(result Value) {
	s.pop()
	s.Stack[len(s.Stack)-1] = result
}

// ⚠ 这里没有「解引用」helper：编译器保证 PushId 只出现在赋值左端，其余读变量一律
// PushValue。收到 Identifier 就是产物错了，该让它当场暴露。

// ============================== 指令 ==============================

func opAssign(s *State) {
	if len(s.Stack) < 2 {
		s.Error("stack underflow. ")
		return
	}
	target, ok := s.atTop(2).(Identifier)
	if !ok {
		s.Error("no implement for value type. ")
		return
	}
	s.Variables[target.Index] = s.Stack[len(s.Stack)-1]
	s.popN(2)
}

func opPushNull(s *State)  { s.Stack = append(s.Stack, nil) }
func opPushFalse(s *State) { s.pushInt(0) }
func opPushTrue(s *State)  { s.pushInt(1) }

func opPushInt(s *State) {
	s.I++
	s.Stack = append(s.Stack, s.Program.IntConsts[s.Program.Opcodes[s.I]])
}

func opPushFloat(s *State) {
	s.I++
	s.Stack = append(s.Stack, s.Program.FloatConsts[s.Program.Opcodes[s.I]])
}

func opPushString(s *State) {
	s.I++
	s.Stack = append(s.Stack, s.Program.StringConsts[s.Program.Opcodes[s.I]])
}

func opPushBinarr(s *State) {
	s.I++
	s.Stack = append(s.Stack, s.Program.BinarrConsts[s.Program.Opcodes[s.I]])
}

func opPushValue(s *State) {
	s.I++
	s.Stack = append(s.Stack, s.Variables[s.Program.Opcodes[s.I]]) // 压【值】
}

func opPushId(s *State) {
	s.I++
	s.Stack = append(s.Stack, Identifier{s.Program.Opcodes[s.I]}) // 不能是值，否则无法 Assign
}

func opCall(s *State) {
	// 不检查栈下溢：参数个数在编译期就定了
	s.I++
	argNum := s.Program.Opcodes[s.I]
	callee := s.atTop(argNum + 1)
	fn, ok := callee.(HostFunction)
	if !ok {
		s.Error("\"Call\" can only call a function. ")
		return
	}
	argv := make([]Value, argNum)
	for k := 0; k < argNum; k++ {
		argv[k] = s.atTop(argNum - k)
	}
	out := Normalize(fn(argv)) // 参数整包进来，由宿主自己拆
	s.popN(argNum)
	s.Stack[len(s.Stack)-1] = out
}

// strUnits 按 UTF-16 码元取值（C++ 是 u16string、C# 是 UTF-16 char，六份一致）。
func strUnits(text string) []uint16 {
	return utf16.Encode([]rune(text))
}

func opAt(s *State) {
	// 不检查栈下溢：key 个数在编译期就定了
	s.I++
	keyNum := s.Program.Opcodes[s.I]
	if keyNum != 1 {
		s.Error("no implement for key num != 1. ")
		return
	}
	container := s.atTop(2)
	key := s.atTop(1)
	if !isInt(key) {
		s.Error("index must be integer. ")
		return
	}
	index := key.(int64)
	var result Value
	if b, ok := container.([]byte); ok {
		if index < 0 || index >= int64(len(b)) {
			s.Error("index out of range. ")
			return
		}
		result = int64(b[index])
	} else if str, ok := container.(string); ok {
		units := strUnits(str)
		if index < 0 || int64(len(units)) <= index {
			s.Error("index out of range. ")
			return
		}
		// 取的是【码元】（UTF-16），不是单字符子串 —— 与 C++ / C# 一致。
		result = int64(units[index])
	} else {
		s.Error("no implement for container type. ")
		return
	}
	s.popN(keyNum + 1)
	s.Stack = append(s.Stack, result)
}

func opPop(s *State) { s.pop() }

func opMinus(s *State) {
	val := s.Stack[len(s.Stack)-1]
	switch x := val.(type) {
	case int64:
		s.Stack[len(s.Stack)-1] = -x // 回绕（MinInt64 → MinInt64），不检查溢出
	case float64:
		s.Stack[len(s.Stack)-1] = -x
	default:
		s.Error("\"Minus\" can only operate on integer or float. ")
	}
}

func opNot(s *State) {
	val := s.Stack[len(s.Stack)-1]
	switch x := val.(type) {
	case nil:
		s.Stack[len(s.Stack)-1] = int64(1)
	case int64:
		if x == 0 {
			s.Stack[len(s.Stack)-1] = int64(1)
		} else {
			s.Stack[len(s.Stack)-1] = int64(0)
		}
	case float64:
		if x == 0.0 {
			s.Stack[len(s.Stack)-1] = int64(1)
		} else {
			s.Stack[len(s.Stack)-1] = int64(0)
		}
	default:
		s.Error("\"Not\" can only operate on integer or float. ")
	}
}

func opPow(s *State) {
	left, right := s.atTop(2), s.atTop(1)
	if !checkArith(s, "Pow", left, right) {
		return
	}
	// 两个整数且指数 >= 0 → 整数结果；负指数（2 ^ -1）→ Float(0.5)。
	// 与常量折叠的 Pow 分支一致。
	if li, lok := left.(int64); lok {
		if ri, rok := right.(int64); rok && ri >= 0 {
			s.storeBinary(stope.IntPow(li, ri))
			return
		}
	}
	s.storeBinary(stope.FPow(asDouble(left), asDouble(right)))
}

func opMul(s *State) {
	left, right := s.atTop(2), s.atTop(1)
	if left == nil || right == nil {
		s.Error("\"Mul\" cannot operate on null. ")
		return
	}
	if isNumber(left) && isNumber(right) {
		if li, lok := left.(int64); lok {
			if ri, rok := right.(int64); rok {
				s.storeBinary(li * ri) // 回绕
				return
			}
		}
		s.storeBinary(asDouble(left) * asDouble(right))
		return
	}
	if (isSequence(left) && isInt(right)) || (isInt(left) && isSequence(right)) {
		// 序列重复：2 * "ab" 与 "ab" * 2 都要成立 —— 取序列那一侧
		var seq Value
		var times int64
		if isSequence(left) {
			seq, times = left, right.(int64)
		} else {
			seq, times = right, left.(int64)
		}
		if times < 0 {
			s.Error("\"Mul\" cannot repeat a sequence by a negative number. ")
			return
		}
		switch x := seq.(type) {
		case string:
			if uint64(len(x))*uint64(times) > 1<<32 {
				s.Error("sequence result too large. ")
				return
			}
			s.storeBinary(repeatString(x, times))
		case []byte:
			if uint64(len(x))*uint64(times) > 1<<32 {
				s.Error("sequence result too large. ")
				return
			}
			out := make([]byte, 0, int64(len(x))*times)
			for i := int64(0); i < times; i++ {
				out = append(out, x...)
			}
			s.storeBinary(out)
		}
		return
	}
	s.Error("\"Mul\" can only operate on numbers, or repeat a string / bin array by an integer. ")
}

func repeatString(x string, times int64) string {
	out := make([]byte, 0, int64(len(x))*times)
	for i := int64(0); i < times; i++ {
		out = append(out, x...)
	}
	return string(out)
}

func opDiv(s *State) {
	left, right := s.atTop(2), s.atTop(1)
	if !checkArith(s, "Div", left, right) || !checkIntZero(s, "Div", left, right) {
		return
	}
	if li, lok := left.(int64); lok {
		if ri, rok := right.(int64); rok {
			// 除不尽 → 浮点数（7 / 2 是 Float(3.5)）；整除要用 idiv。
			if stope.IntMod(li, ri) == 0 {
				s.storeBinary(stope.IntDiv(li, ri))
			} else {
				s.storeBinary(stope.FDiv(float64(li), float64(ri)))
			}
			return
		}
	}
	s.storeBinary(stope.FDiv(asDouble(left), asDouble(right)))
}

func opIDiv(s *State) {
	left, right := s.atTop(2), s.atTop(1)
	if !checkArith(s, "IDiv", left, right) || !checkIntZero(s, "IDiv", left, right) {
		return
	}
	if li, lok := left.(int64); lok {
		if ri, rok := right.(int64); rok {
			s.storeBinary(stope.IntDiv(li, ri)) // 向零取整
			return
		}
	}
	// 含浮点：仍按数值整除（向零取整），结果保持浮点，不做 float→int 收窄
	s.storeBinary(stope.Trunc(stope.FDiv(asDouble(left), asDouble(right))))
}

func opMod(s *State) {
	left, right := s.atTop(2), s.atTop(1)
	if !checkArith(s, "Mod", left, right) || !checkIntZero(s, "Mod", left, right) {
		return
	}
	if li, lok := left.(int64); lok {
		if ri, rok := right.(int64); rok {
			s.storeBinary(stope.IntMod(li, ri)) // 余数符号跟被除数
			return
		}
	}
	// 用 FMod：Go 的 math.Mod 与 C++ fmod 语义一致（符号跟被除数）
	s.storeBinary(stope.FMod(asDouble(left), asDouble(right)))
}

func opAdd(s *State) {
	left, right := s.atTop(2), s.atTop(1)
	// null 不是「加法单位元」，也不与任何值做算术 —— 一律报错
	if left == nil || right == nil {
		s.Error("\"Add\" cannot operate on null. ")
		return
	}
	if li, lok := left.(int64); lok {
		if ri, rok := right.(int64); rok {
			s.storeBinary(li + ri) // 回绕
		} else if rf, rok := right.(float64); rok {
			s.storeBinary(float64(li) + rf)
		} else {
			s.Error("integer can only add integer or float. ")
		}
		return
	}
	if lf, lok := left.(float64); lok {
		if isNumber(right) {
			s.storeBinary(lf + asDouble(right))
		} else {
			s.Error("float can only add integer or float. ")
		}
		return
	}
	if ls, lok := left.(string); lok {
		if rs, rok := right.(string); rok {
			s.storeBinary(ls + rs)
			return
		}
	}
	if lb, lok := left.([]byte); lok {
		if rb, rok := right.([]byte); rok {
			out := make([]byte, 0, len(lb)+len(rb))
			out = append(out, lb...)
			out = append(out, rb...)
			s.storeBinary(out)
			return
		}
	}
	s.Error("\"Add\" can only operate on numbers, strings or bin arrays. ")
}

func opSub(s *State) {
	left, right := s.atTop(2), s.atTop(1)
	if !checkArith(s, "Sub", left, right) {
		return
	}
	if li, lok := left.(int64); lok {
		if ri, rok := right.(int64); rok {
			s.storeBinary(li - ri) // 回绕
		} else if rf, rok := right.(float64); rok {
			s.storeBinary(float64(li) - rf)
		} else {
			s.Error("integer can only subtract integer or float. ")
		}
		return
	}
	if lf, lok := left.(float64); lok {
		if isNumber(right) {
			s.storeBinary(lf - asDouble(right))
		} else {
			s.Error("float can only subtract integer or float. ")
		}
		return
	}
	s.Error("\"Sub\" can only operate on integer or float. ")
}

func opEQ(s *State) {
	if Equals(s.atTop(2), s.atTop(1)) {
		s.storeBinary(int64(1))
	} else {
		s.storeBinary(int64(0))
	}
}

func opNE(s *State) {
	if Equals(s.atTop(2), s.atTop(1)) {
		s.storeBinary(int64(0))
	} else {
		s.storeBinary(int64(1))
	}
}

func opLT(s *State) {
	if lessThan(s, s.atTop(2), s.atTop(1)) {
		s.storeBinary(int64(1))
	} else {
		s.storeBinary(int64(0))
	}
}

func opLE(s *State) {
	if greaterThan(s, s.atTop(2), s.atTop(1)) {
		s.storeBinary(int64(0))
	} else {
		s.storeBinary(int64(1))
	}
}

func opGT(s *State) {
	if greaterThan(s, s.atTop(2), s.atTop(1)) {
		s.storeBinary(int64(1))
	} else {
		s.storeBinary(int64(0))
	}
}

func opGE(s *State) {
	if lessThan(s, s.atTop(2), s.atTop(1)) {
		s.storeBinary(int64(0))
	} else {
		s.storeBinary(int64(1))
	}
}

func opIf(s *State) {
	yes := Truely(s.Stack[len(s.Stack)-1])
	s.pop()  // 条件用完即弹，不再留在栈上
	s.I++    // 跳过操作数；条件成立时 step/run 的 +1 正好落到下一句
	target := s.Program.Opcodes[s.I]
	if !yes {
		s.I = target - 1
	}
}

func opGoTo(s *State) {
	s.I = s.Program.Opcodes[s.I+1] - 1 // 操作数在 i+1
}

func opGetArg(s *State) {
	if s.Args == nil {
		s.Error("no args. ")
		return
	}
	// 先弹 key 再取参：实参表可能拿 key 做准备
	key := s.Stack[len(s.Stack)-1]
	s.Stack = s.Stack[:len(s.Stack)-1] // 栈上一定是值：读变量走 PushValue
	s.Stack = append(s.Stack, Normalize(s.Args.At(s, key)))
}

func opArgNum(s *State) {
	if s.Args == nil {
		s.Error("no args. ")
		return
	}
	s.pushInt(int64(s.Args.Num()))
}

func opReturn(s *State) {
	s.I++
	num := s.Program.Opcodes[s.I]
	s.Returns = make([]Value, num)
	for k := 0; k < num; k++ {
		s.Returns[k] = s.atTop(num - k)
	}
	s.I = len(s.Program.Opcodes)
}

func opUnimplemented(s *State) {
	// 占位处理函数：指令表被 SetOpcode 撑出来但那一格没注册。
	s.Error("no implement for opcode " + strconv.Itoa(s.Program.Opcodes[s.I]) + ". ")
}

// ============================== Api ==============================

// Api 指令分派表。OpMap 的下标就是指令编号，稠密（与 C++ 的
// std::array<OpFunc, kOpCount> 同形）。要跑自定义指令必须自己扩表 —— 用 SetOpcode，
// 它会先把中间补齐，否则中间的空格会在 Run 时静默走到占位函数上。
type Api struct {
	OpMap []func(*State)
}

// NewApi 构造内置 33 条指令的分派表。
func NewApi() *Api {
	return &Api{OpMap: []func(*State){
		opAssign, opPushNull, opPushFalse, opPushTrue, opPushInt,
		opPushFloat, opPushString, opPushBinarr, opPushValue, opPushId,
		opCall, opAt, opPop, opMinus, opNot,
		opPow, opMul, opDiv, opIDiv, opMod,
		opAdd, opSub, opEQ, opNE, opLT,
		opLE, opGT, opGE, opIf, opGoTo,
		opGetArg, opArgNum, opReturn,
	}}
}

// SetOpcode 装一条自定义指令的处理函数：fn(state)。会先把中间补成占位函数。
func (a *Api) SetOpcode(opcode int, fn func(*State)) {
	for len(a.OpMap) <= opcode {
		a.OpMap = append(a.OpMap, opUnimplemented)
	}
	a.OpMap[opcode] = fn
}
