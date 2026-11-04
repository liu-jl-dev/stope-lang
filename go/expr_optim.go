package stope

// 常量折叠 —— 端口 cpp/src/expr_optim.cpp（C++ 为权威实现）。
//
// 只做「单节点」变换，不递归；挂在 parser 构造 UnaryOpExpr / BinaryOpExpr 的末尾，
// 子节点返回时就已折好。Optimize 成功折叠时返回新节点，否则返回入参本身。
// 拿不准就一律不折叠。折叠后的节点沿用运算符节点的 line。
//
// 整数溢出不检查、按 64 位补码回绕（Go 的 int64 算术本身回绕）。

// 常量折叠结果上限：串重复的元素数上限 1 M。
const maxRepeatElem = 1 << 20

// 常量分类
const (
	kNotConst = iota
	kNull
	kBool
	kInt
	kFloat
	kString
	kBinArr
)

// Optimize 返回一个（可能是新的）节点：成功折叠时是新常量节点，否则是入参本身。
func Optimize(e Node) Node {
	if e == nil {
		return nil
	}
	switch n := e.(type) {
	case *UnaryOpExpr:
		return foldUnary(n)
	case *BinaryOpExpr:
		return foldBinary(n)
	}
	return e
}

// kindOf 只有 6 种字面量是「常量」。Ident / Call / At / Args / Argc / Custom 都不是。
func kindOf(e Node) int {
	switch e.(type) {
	case nil:
		return kNotConst
	case *NullExpr:
		return kNull
	case *BoolExpr:
		return kBool
	case *IntExpr:
		return kInt
	case *FloatExpr:
		return kFloat
	case *StringExpr:
		return kString
	case *BinArrExpr:
		return kBinArr
	}
	return kNotConst
}

func isConst(k int) bool     { return k != kNotConst }
func isNumeric(k int) bool   { return k == kInt || k == kFloat } // 不含 Bool
func bothInt(lk, rk int) bool { return lk == kInt && rk == kInt }
func isSeq(k int) bool       { return k == kString || k == kBinArr }

// isNumLike 「算术上下文」里的 Bool：视作 0 / 1 的整数（只对 + - * / idiv % ^ 生效）。
func isNumLike(k int) bool { return k == kBool || isNumeric(k) }

// bothNumInt 两侧都参与整数运算（Bool 算整数），只有出现 Float 才走浮点分支。
func bothNumInt(lk, rk int) bool {
	return isNumLike(lk) && isNumLike(rk) && lk != kFloat && rk != kFloat
}

func numAsInt(e Node) int64 {
	if b, ok := e.(*BoolExpr); ok {
		if b.Value {
			return 1
		}
		return 0
	}
	return e.(*IntExpr).Value
}

func asDouble(e Node) float64 {
	switch n := e.(type) {
	case *BoolExpr:
		if n.Value {
			return 1.0
		}
		return 0.0
	case *IntExpr:
		return float64(n.Value)
	case *FloatExpr:
		return n.Value
	}
	return 0
}

// seqSize String 按 UTF-16 码元计长，BinArr 按字节。
func seqSize(e Node) int {
	switch n := e.(type) {
	case *StringExpr:
		return SeqSize(n.Value)
	case *BinArrExpr:
		return len(n.Value)
	}
	return 0
}

func seqEqual(a, b Node) bool {
	if sa, ok := a.(*StringExpr); ok {
		return sa.Value == b.(*StringExpr).Value
	}
	ab := a.(*BinArrExpr).Value
	bb := b.(*BinArrExpr).Value
	if len(ab) != len(bb) {
		return false
	}
	for i := range ab {
		if ab[i] != bb[i] {
			return false
		}
	}
	return true
}

func makeSeq(line int, k int) Node {
	if k == kString {
		return &StringExpr{NodeBase{line}, ""}
	}
	return &BinArrExpr{NodeBase{line}, nil}
}

// seqAppend dst + src（str + str / bytes + bytes）。
func seqAppend(dst, src Node) {
	switch d := dst.(type) {
	case *StringExpr:
		d.Value += src.(*StringExpr).Value
	case *BinArrExpr:
		d.Value = append(d.Value, src.(*BinArrExpr).Value...)
	}
}

// truthy 真值规则：null 假；bool 自身；int/float 非零；序列非空。
func truthy(e Node) bool {
	switch n := e.(type) {
	case *NullExpr:
		return false
	case *BoolExpr:
		return n.Value
	case *IntExpr:
		return n.Value != 0
	case *FloatExpr:
		return n.Value != 0.0
	case *StringExpr:
		return SeqSize(n.Value) != 0
	case *BinArrExpr:
		return len(n.Value) != 0
	}
	return false
}

func makeBool(line int, v bool) Node  { return &BoolExpr{NodeBase{line}, v} }
func makeInt(line int, v int64) Node  { return &IntExpr{NodeBase{line}, v} }
func makeFloat(line int, v float64) Node { return &FloatExpr{NodeBase{line}, v} }

// cloneConst 拷贝一个字面量常量节点（用于 null + X -> X 这类规则）。
func cloneConst(line int, e Node) Node {
	switch n := e.(type) {
	case *NullExpr:
		return &NullExpr{NodeBase{line}}
	case *BoolExpr:
		return makeBool(line, n.Value)
	case *IntExpr:
		return makeInt(line, n.Value)
	case *FloatExpr:
		return makeFloat(line, n.Value)
	}
	k := kindOf(e)
	if !isSeq(k) {
		return nil
	}
	r := makeSeq(line, k)
	seqAppend(r, e)
	return r
}

// negateConst 取负：Int/Float 同类型取负；Bool 转成 Int 取负；null / 序列不可取负。
func negateConst(line int, e Node) Node {
	switch n := e.(type) {
	case *BoolExpr:
		if n.Value {
			return makeInt(line, -1)
		}
		return makeInt(line, 0)
	case *IntExpr:
		return makeInt(line, -n.Value) // int64 取负回绕（MinInt64 → MinInt64）
	case *FloatExpr:
		return makeFloat(line, -n.Value)
	}
	return nil
}

// repeatSeq 串重复："ab" * 3 / 'x 41' * 3；负次或结果过大 → nil（不折叠）。
func repeatSeq(line int, base Node, times int64) Node {
	if times < 0 {
		return nil
	}
	unit := int64(seqSize(base))
	if unit == 0 {
		return makeSeq(line, kindOf(base)) // 空串/空数组的任意次重复仍是空
	}
	if times > maxRepeatElem/unit {
		return nil
	}
	r := makeSeq(line, kindOf(base))
	for i := int64(0); i < times; i++ {
		seqAppend(r, base)
	}
	return r
}

func cmpOf(op TokenType, a, b float64) bool {
	switch op {
	case TLT:
		return a < b
	case TLE:
		return a <= b
	case TGT:
		return a > b
	}
	return a >= b
}

// ==================== 一元 ====================

func foldUnary(e *UnaryOpExpr) Node {
	if e.Expr == nil {
		return e
	}
	line := e.Line_
	inn := e.Expr
	ck := kindOf(inn)
	if !isConst(ck) {
		return e // 非常量 → 不折叠
	}
	var ret Node
	if e.Op == TNot {
		// ! 走 truthy
		if ck == kNull || isNumLike(ck) {
			ret = makeBool(line, !truthy(inn))
		}
	} else if e.Op == TSub {
		ret = negateConst(line, inn)
	}
	if ret == nil {
		return e
	}
	return ret
}

// ==================== 二元 ====================

func foldBinary(e *BinaryOpExpr) Node {
	if e.LeftExpr == nil || e.RightExpr == nil {
		return e
	}
	ret := tryFoldBinary(e)
	if ret == nil {
		return e
	}
	return ret
}

func tryFoldBinary(e *BinaryOpExpr) Node {
	line := e.Line_
	op := e.Op
	L, R := e.LeftExpr, e.RightExpr
	lk, rk := kindOf(L), kindOf(R)
	// L0 两侧必须都是字面量常量
	if !isConst(lk) || !isConst(rk) {
		return nil
	}

	// ---------- L1 and / or：结果与类型无关，恒返回 Bool ----------
	if op == TAnd {
		return makeBool(line, truthy(L) && truthy(R))
	}
	if op == TOr {
		return makeBool(line, truthy(L) || truthy(R))
	}

	// ---------- L2 null 参与 ----------
	// null 不参与算术；只有 == != 有确定结论：null 只与 null 相等。
	if lk == kNull || rk == kNull {
		bothNull := lk == kNull && rk == kNull
		if op == TEQ {
			return makeBool(line, bothNull)
		}
		if op == TNE {
			return makeBool(line, !bothNull)
		}
		return nil
	}

	// ---------- L3 相等与大小比较 ----------
	// 到这里两侧都非 null；跨类型一律不折叠。
	if op == TEQ || op == TNE {
		decided := false
		eq := false
		if lk == kBool && rk == kBool {
			decided = true
			eq = L.(*BoolExpr).Value == R.(*BoolExpr).Value
		} else if isNumeric(lk) && isNumeric(rk) {
			// Bool ⊕ 数字 → 不折
			decided = true
			if bothInt(lk, rk) {
				eq = L.(*IntExpr).Value == R.(*IntExpr).Value
			} else {
				eq = asDouble(L) == asDouble(R)
			}
		} else if isSeq(lk) && lk == rk {
			decided = true
			eq = seqEqual(L, R)
		}
		if decided {
			return makeBool(line, (op == TEQ) == eq)
		}
		return nil
	}
	if op == TLT || op == TLE || op == TGT || op == TGE {
		// Bool 与序列不参与数值比较 → 两侧都必须是 Int / Float
		if isNumeric(lk) && isNumeric(rk) {
			if bothInt(lk, rk) {
				return makeBool(line, cmpOf(op, float64(L.(*IntExpr).Value), float64(R.(*IntExpr).Value)))
			}
			return makeBool(line, cmpOf(op, asDouble(L), asDouble(R)))
		}
		return nil
	}

	// ---------- L4 算术 + - * / idiv % ^ ----------
	if isNumLike(lk) {
		// ===== L4a 左值是 Bool / Int / Float =====
		switch op {
		case TAdd, TSub, TMul:
			if isNumLike(rk) {
				if bothNumInt(lk, rk) {
					a, b := numAsInt(L), numAsInt(R)
					switch op {
					case TAdd:
						return makeInt(line, a+b)
					case TSub:
						return makeInt(line, a-b)
					}
					return makeInt(line, a*b)
				}
				// 任一侧是 Float → 浮点路径
				x, y := asDouble(L), asDouble(R)
				switch op {
				case TAdd:
					return makeFloat(line, x+y)
				case TSub:
					return makeFloat(line, x-y)
				}
				return makeFloat(line, x*y)
			} else if op == TMul && isSeq(rk) && lk != kFloat {
				return repeatSeq(line, R, numAsInt(L)) // 数字 * 串 == 串重复
			}
		case TDiv:
			if isNumLike(rk) {
				if bothNumInt(lk, rk) {
					a, b := numAsInt(L), numAsInt(R)
					// 除零 → 不折叠；除不尽 → 浮点数
					if b != 0 {
						if IntMod(a, b) == 0 {
							return makeInt(line, IntDiv(a, b))
						}
						return makeFloat(line, float64(a)/float64(b))
					}
				} else {
					bb := asDouble(R)
					if bb != 0.0 {
						return makeFloat(line, asDouble(L)/bb)
					}
				}
			}
		case TIDiv:
			if bothNumInt(lk, rk) {
				// 含浮点 → 收窄成整数，不折叠（bothNumInt 已保证无 Float）
				a, b := numAsInt(L), numAsInt(R)
				if b != 0 {
					return makeInt(line, IntDiv(a, b)) // 向零取整
				}
			}
		case TMod:
			if isNumLike(rk) {
				if bothNumInt(lk, rk) {
					a, b := numAsInt(L), numAsInt(R)
					if b != 0 {
						return makeInt(line, IntMod(a, b))
					}
				} else {
					bb := asDouble(R)
					if bb != 0.0 {
						// 必须 FMod：余数符号跟被除数
						return makeFloat(line, FMod(asDouble(L), bb))
					}
				}
			}
		case TPow:
			if isNumLike(rk) {
				if bothNumInt(lk, rk) {
					b := numAsInt(R)
					// 非负整数指数走快速幂（溢出回绕）；负指数落到浮点分支
					if b >= 0 {
						return makeInt(line, IntPow(numAsInt(L), b))
					}
				}
				// 负指数 / 含浮点：必须 FPow
				rr := FPow(asDouble(L), asDouble(R))
				if !IsSpecial(rr) {
					return makeFloat(line, rr) // NaN / Inf → 不折叠
				}
			}
		}
	} else if isSeq(lk) {
		// ===== L4b 左值是序列（String / BinArr）=====
		switch op {
		case TAdd:
			if rk == lk {
				// 同类才连接：字符串拼接 / 字节连接（跨类型不折）
				ret := makeSeq(line, lk)
				seqAppend(ret, L)
				seqAppend(ret, R)
				return ret
			}
		case TMul:
			if rk == kInt || rk == kBool {
				return repeatSeq(line, L, numAsInt(R)) // 串 * 整数 == 串重复
			}
		}
		// 其余运算符（Sub 等）对序列无定义 → 不折叠
	}
	return nil
}
