class_name StopeExprOptim
# 常量折叠 —— 端口 cpp/stope/expr_optim.hpp（2026-10-18）。
#
# 契约与 C++ 完全一致：
#   - 只做「单节点」变换，不递归。挂在 parser 构造 UnaryOpExpr / BinaryOpExpr 的末尾，
#     子节点返回时就已折好，整棵树自底向上折叠完毕。
#   - optimize() 成功折叠时返回【新】节点（原节点不再被引用），未折叠时返回入参本身。
#   - 拿不准就一律不折叠：除零、整数溢出、含浮点的 idiv、跨类型 ==、null 参与比较、
#     Bool 参与比较 —— 全部保留原节点。折叠后的节点沿用运算符节点的 line。
#
# 本项目自定的三条算术规则（详见 cpp/stope/expr_optim.md §4.9）：
#   1. BinArr + BinArr == 字节连接；
#   2. String / BinArr * 非负整数 == 串重复（整数 * 串 同理）；
#   3. `+ - * / idiv % ^` 里 Bool 视作 0 / 1，但 `< <= > >=` 与 `== !=` 仍按类型区分。
#
# 判断顺序与 C++ 一一对应（层号同 expr_optim.md §4.2 / §4.7）：
#   L0 两侧必须都是字面量常量 -> L1 and/or -> L2 任一侧 null -> L3 比较 -> L4 算术
# 刻意【不】拆成 foldXxx 分派函数，保持「一个格子 = 一个分支」，方便两边对照。

const TokenType = StopeLexer.Token.Type

const INT64_MAX := 9223372036854775807
const INT64_MIN := -9223372036854775807 - 1
const MAX_REPEAT_ELEM := 1 << 20	# 串重复的元素数上限：1 M

enum ConstKind { NotConst, Null, Bool, Int, Float, String, BinArr }

# ==================== 入口 ====================
# 返回一个（可能是新的）节点：成功折叠时是新常量节点，否则是入参本身。
static func optimize(e) -> StopeAst.Expr:
	if e == null: return null
	if e.node_type == StopeAst.NodeType.UnaryOpExpr: return fold_unary(e)
	if e.node_type == StopeAst.NodeType.BinaryOpExpr: return fold_binary(e)
	return e

# ==================== 常量分类与取值 ====================
# 只有 6 种字面量是「常量」。Ident / Call / At / Args / Argc / Custom 都不是
# （值要运行期才知道，且 Call / Custom 可能有副作用）。
static func kind_of(e) -> ConstKind:
	if e == null: return ConstKind.NotConst
	match e.node_type:
		StopeAst.NodeType.NullExpr: return ConstKind.Null
		StopeAst.NodeType.BoolExpr: return ConstKind.Bool
		StopeAst.NodeType.IntExpr: return ConstKind.Int
		StopeAst.NodeType.FloatExpr: return ConstKind.Float
		StopeAst.NodeType.StringExpr: return ConstKind.String
		StopeAst.NodeType.BinArrExpr: return ConstKind.BinArr
	return ConstKind.NotConst

static func is_const(k:ConstKind) -> bool: return k != ConstKind.NotConst
# 真正的 Int / Float（不含 Bool）
static func is_numeric(k:ConstKind) -> bool:
	return k == ConstKind.Int or k == ConstKind.Float
static func both_int(lk:ConstKind, rk:ConstKind) -> bool:
	return lk == ConstKind.Int and rk == ConstKind.Int
# String / BinArr 统称「序列」：连接、重复、相等的规则一致
static func is_seq(k:ConstKind) -> bool:
	return k == ConstKind.String or k == ConstKind.BinArr
# ---------- 「算术上下文」里的 Bool：视作 0 / 1 的整数 ----------
# 只对 `+ - * / idiv % ^` 生效；`< <= > >=` 与 `== !=` 仍按各自的类型规则
static func is_num_like(k:ConstKind) -> bool:
	return k == ConstKind.Bool or is_numeric(k)
# 两侧都参与整数运算（Bool 算整数），只有出现 Float 才走浮点分支
static func both_num_int(lk:ConstKind, rk:ConstKind) -> bool:
	return is_num_like(lk) and is_num_like(rk) and lk != ConstKind.Float and rk != ConstKind.Float

# ---------- 取值：num_as_int / as_double 会把 Bool 折算成 0 / 1 ----------
static func bool_val(e) -> bool: return e.value
static func as_int(e) -> int: return e.value
static func double_val(e) -> float: return e.value
static func num_as_int(e) -> int:
	if e.node_type == StopeAst.NodeType.BoolExpr: return 1 if bool_val(e) else 0
	return as_int(e)
static func as_double(e) -> float:
	if e.node_type == StopeAst.NodeType.BoolExpr: return 1.0 if bool_val(e) else 0.0
	if e.node_type == StopeAst.NodeType.IntExpr: return float(as_int(e))
	return double_val(e)

# ==================== 序列（String / BinArr）的载荷读写 ====================
# 两者载荷类型不同（String / PackedByteArray），但需要的操作只有下面 4 个，
# 集中在这里分发，二元的每个格子就不必为 String 与 BinArr 各写一套分支。
static func seq_size(e) -> int:
	if e.node_type == StopeAst.NodeType.StringExpr: return e.value.length()
	return e.value.size()
static func seq_equal(a, b) -> bool: return a.value == b.value
static func make_seq(line:int, k:ConstKind) -> StopeAst.Expr:
	if k == ConstKind.String: return StopeAst.StringExpr.new(line)
	return StopeAst.BinArrExpr.new(line)
static func seq_append(dst, src) -> void:
	if dst.node_type == StopeAst.NodeType.StringExpr: dst.value += src.value
	else: dst.value.append_array(src.value)

# 真值规则：null -> 假；bool -> 自身；int/float -> 非零；序列 -> 非空
static func truthy(e) -> bool:
	if e.node_type == StopeAst.NodeType.NullExpr: return false
	if e.node_type == StopeAst.NodeType.BoolExpr: return bool_val(e)
	if e.node_type == StopeAst.NodeType.IntExpr: return as_int(e) != 0
	if e.node_type == StopeAst.NodeType.FloatExpr: return double_val(e) != 0.0
	if is_seq(kind_of(e)): return seq_size(e) != 0
	return false

# ==================== 有符号整数溢出检查 ====================
# + - * 一律按 64 位回绕（与 C++ 的 intAdd/intSub/intMul 一致，GD 的 int 也是回绕），
# 所以只有两类地方需要显式挡：除法/取模的 INT64_MIN / -1，以及快速幂的中间结果。
static func div_mod_overflow(a:int, b:int) -> bool:
	return a == INT64_MIN and b == -1	# 除法/取模唯一的溢出组合

# 整数乘的溢出检测，只给快速幂用（+ - * 本身按 64 位回绕，不检测）
static func mul_overflow(a:int, b:int) -> Array:
	if a == 0: return [false, 0]
	if a == -1: return [true, 0] if b == INT64_MIN else [false, -b]
	var r:int = a * b
	return [r / a != b, r]

# 整数快速幂，exp >= 0；溢出返回 [true, 0]
static func int_pow(base:int, exp:int) -> Array:
	var result:int = 1
	var b:int = base
	var e:int = exp
	while e > 0:
		if e % 2 != 0:
			var r := mul_overflow(result, b)
			if r[0]: return [true, 0]
			result = r[1]
		e = e / 2
		if e > 0:
			var s := mul_overflow(b, b)
			if s[0]: return [true, 0]
			b = s[1]
	return [false, result]

# ==================== 造节点 / 拷贝常量 / 取负 / 串重复 ====================
static func make_bool(line:int, v:bool) -> StopeAst.BoolExpr: return StopeAst.BoolExpr.new(line, v)
static func make_int(line:int, v:int) -> StopeAst.IntExpr: return StopeAst.IntExpr.new(line, v)
static func make_float(line:int, v:float) -> StopeAst.FloatExpr: return StopeAst.FloatExpr.new(line, v)
static func make_null(line:int) -> StopeAst.Expr: return StopeAst.NullExpr.new()

# 拷贝一个字面量常量节点（用于 null + X -> X 这类规则），非常量返回 null
static func clone_const(line:int, e) -> StopeAst.Expr:
	match e.node_type:
		StopeAst.NodeType.NullExpr: return StopeAst.NullExpr.new()
		StopeAst.NodeType.BoolExpr: return make_bool(line, bool_val(e))
		StopeAst.NodeType.IntExpr: return make_int(line, as_int(e))
		StopeAst.NodeType.FloatExpr: return make_float(line, double_val(e))
	var k := kind_of(e)
	if not is_seq(k): return null
	var r := make_seq(line, k)
	seq_append(r, e)
	return r

# 取负：Int/Float -> 同类型取负；Bool -> 转成 Int 取负。
# 不可取负（null / 序列）返回 null。整数按 64 位回绕（-INT64_MIN == INT64_MIN），
# 所以走 `~a + 1` 而不是 `-a`：后者在 GD 里对 INT64_MIN 会直接崩，前者等价且安全。
static func negate_const(line:int, e) -> StopeAst.Expr:
	match e.node_type:
		StopeAst.NodeType.BoolExpr: return make_int(line, -1 if bool_val(e) else 0)
		StopeAst.NodeType.IntExpr:
			var v:int = as_int(e)
			return make_int(line, ~v + 1)
		StopeAst.NodeType.FloatExpr: return make_float(line, -double_val(e))
	return null

# 串重复：`"ab" * 3` / `'x 41' * 3`。times 必须是非负整数（Bool 已在调用侧折算）；
# 负次或结果元素数超过上限 -> null。
static func repeat_seq(line:int, base, times:int) -> StopeAst.Expr:
	if times < 0: return null	# 负次重复无定义 -> 不折叠
	var unit:int = seq_size(base)
	if unit == 0: return make_seq(line, kind_of(base))	# 空串/空数组的任意次重复仍是空
	if times > MAX_REPEAT_ELEM / unit: return null	# 结果过大 -> 不折叠
	var r := make_seq(line, kind_of(base))
	for i in range(times): seq_append(r, base)
	return r

# `<` `<=` `>` `>=` 的四分支（整数与浮点共用一套）
static func cmp_of(op:int, a, b) -> bool:
	if op == TokenType.LT: return a < b
	if op == TokenType.LE: return a <= b
	if op == TokenType.GT: return a > b
	return a >= b

# ==================== 一元 ====================
static func fold_unary(e) -> StopeAst.Expr:
	if e == null or e.expr == null: return e
	var line:int = e.line
	var inn = e.expr
	var ck := kind_of(inn)
	if not is_const(ck): return e	# 非常量 -> 不折叠
	# `!` 走 truthy；`-` 走 negate_const（Bool 折算成 Int，null / 序列不可取负 -> 不折叠）
	var ret = null
	if e.op == TokenType.Not:
		if ck == ConstKind.Null or is_num_like(ck):
			ret = make_bool(line, not truthy(inn))
	elif e.op == TokenType.Sub:
		ret = negate_const(line, inn)
	return ret if ret else e

# ==================== 二元 ====================
static func fold_binary(e) -> StopeAst.Expr:
	if e == null or e.left_expr == null or e.right_expr == null: return e
	var ret = try_fold_binary(e)
	return ret if ret else e

static func try_fold_binary(e) -> StopeAst.Expr:
	var line:int = e.line
	var op:int = e.op
	var L = e.left_expr
	var R = e.right_expr
	var lk := kind_of(L)
	var rk := kind_of(R)
	# L0 两侧必须都是字面量常量：否则既算不出值，也可能吞掉 Call/Custom 的副作用
	if not is_const(lk) or not is_const(rk): return null

	# ---------- L1 and / or：结果与类型无关，恒返回 Bool ----------
	if op == TokenType.And:
		return make_bool(line, truthy(L) and truthy(R))
	if op == TokenType.Or:
		return make_bool(line, truthy(L) or truthy(R))

	# ---------- L2 null 参与 ----------
	# null 不是数字，也不参与算术：`+ - * / idiv % ^` 一律不折叠，交给后端报错
	# （basic_vm 同样是报错）。只有 `==` `!=` 有确定结论：null 只与 null 相等。
	# < <= > >= 本该是类型错误 -> 不折叠。
	if lk == ConstKind.Null or rk == ConstKind.Null:
		var both_null:bool = (lk == ConstKind.Null and rk == ConstKind.Null)
		if op == TokenType.EQ:
			return make_bool(line, both_null)
		elif op == TokenType.NE:
			return make_bool(line, not both_null)
		return null

	# ---------- L3 相等与大小比较 ----------
	# 到这里两侧都非 null；跨类型一律不折叠（强制转换规则未定，见 §4.5）
	if op == TokenType.EQ or op == TokenType.NE:
		var decided := false
		var eq := false
		if lk == ConstKind.Bool and rk == ConstKind.Bool:
			decided = true
			eq = bool_val(L) == bool_val(R)
		elif is_numeric(lk) and is_numeric(rk):	# Bool ⊕ 数字 -> 不折
			decided = true
			eq = (as_int(L) == as_int(R)) if both_int(lk, rk) else (as_double(L) == as_double(R))
		elif is_seq(lk) and lk == rk:	# 串相等 / 字节相等
			decided = true
			eq = seq_equal(L, R)
		if decided: return make_bool(line, eq if op == TokenType.EQ else not eq)
		return null
	if (op == TokenType.LT or op == TokenType.LE
			or op == TokenType.GT or op == TokenType.GE):
		# Bool 与序列不参与数值比较 -> 两侧都必须是 Int / Float
		if is_numeric(lk) and is_numeric(rk):
			return make_bool(line, cmp_of(op, as_int(L), as_int(R)) if both_int(lk, rk)
					else cmp_of(op, as_double(L), as_double(R)))
		return null

	# ---------- L4 算术 + - * / idiv % ^ ----------
	# 到这里两侧都非 null，左值只剩两类：数值（Bool 折算成 0/1）与序列
	if is_num_like(lk):
		# ===== L4a 左值是 Bool / Int / Float =====
		if (op == TokenType.Add or op == TokenType.Sub
				or op == TokenType.Mul):
			if is_num_like(rk):
				if both_num_int(lk, rk):	# 两侧都没有 Float -> 整数路径
					var a:int = num_as_int(L)
					var b:int = num_as_int(R)
					# 整数溢出不检查，按 64 位回绕（与 C++ 的 intAdd/intSub/intMul 一致）
					if op == TokenType.Add: return make_int(line, a + b)
					elif op == TokenType.Sub: return make_int(line, a - b)
					else: return make_int(line, a * b)
				else:	# 任一侧是 Float -> 浮点路径
					var x:float = as_double(L)
					var y:float = as_double(R)
					var v:float = 0.0
					if op == TokenType.Add: v = x + y
					elif op == TokenType.Sub: v = x - y
					else: v = x * y
					return make_float(line, v)
			elif op == TokenType.Mul and is_seq(rk) and lk != ConstKind.Float:
				return repeat_seq(line, R, num_as_int(L))	# 数字 * 串 == 串重复
		elif op == TokenType.Div:
			if is_num_like(rk):
				if both_num_int(lk, rk):
					var a:int = num_as_int(L)
					var b:int = num_as_int(R)
					# 除零 / 溢出 -> 不折叠；能整除才保持整数
					if b != 0 and not div_mod_overflow(a, b):
						return make_int(line, a / b) if a % b == 0 \
								else make_float(line, float(a) / float(b))
				else:
					var bb:float = as_double(R)
					if bb != 0.0: return make_float(line, as_double(L) / bb)
		elif op == TokenType.IDiv:
			if both_num_int(lk, rk):	# 含浮点 -> float->int 收窄，不折叠
				var a:int = num_as_int(L)
				var b:int = num_as_int(R)
				if b != 0 and not div_mod_overflow(a, b):
					return make_int(line, a / b)	# 向零取整
		elif op == TokenType.Mod:
			if is_num_like(rk):
				if both_num_int(lk, rk):
					var a:int = num_as_int(L)
					var b:int = num_as_int(R)
					if b != 0:
						# INT64_MIN % -1 数学上为 0（GD 里直接算会溢出）
						return make_int(line, 0 if div_mod_overflow(a, b) else a % b)
				else:
					var bb:float = as_double(R)
					if bb != 0.0: return make_float(line, fmod(as_double(L), bb))
		elif op == TokenType.Pow:
			if is_num_like(rk):
				var folded_as_int := false
				if both_num_int(lk, rk):
					var b:int = num_as_int(R)
					if b >= 0:	# 非负整数指数走快速幂；溢出 -> 不折叠
						var r := int_pow(num_as_int(L), b)
						if not r[0]: return make_int(line, r[1])
						folded_as_int = true	# 已定型，不再走浮点分支
				if not folded_as_int:	# 负指数 / 含浮点
					var rr:float = pow(as_double(L), as_double(R))
					if is_finite(rr): return make_float(line, rr)	# NaN / Inf -> 不折叠

	# ===== L4b 左值是序列（String / BinArr）=====
	elif is_seq(lk):
		if op == TokenType.Add:
			if rk == lk:	# 同类才连接：字符串拼接 / 字节连接（跨类型不折）
				var ret := make_seq(line, lk)
				seq_append(ret, L)
				seq_append(ret, R)
				return ret
		elif op == TokenType.Mul:
			if rk == ConstKind.Int or rk == ConstKind.Bool:
				return repeat_seq(line, L, num_as_int(R))	# 串 * 整数 == 串重复
		# 其余运算符（`Sub` 等）对序列无定义 -> 不折叠
	return null
