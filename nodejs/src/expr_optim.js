// 常量折叠 —— 端口 cpp/src/expr_optim.cpp（C++ 为权威实现）。
//
// 契约：
//   - 只做「单节点」变换，不递归。挂在 parser 构造 UnaryOpExpr / BinaryOpExpr 的末尾，
//     子节点返回时就已折好，整棵树自底向上折叠完毕。
//   - optimize() 成功折叠时返回【新】节点（原节点不再使用），未折叠时返回入参本身。
//   - 拿不准就一律不折叠：除零、含浮点的 idiv、跨类型 ==、null 参与比较、
//     Bool 参与比较 —— 全部保留原节点。折叠后的节点沿用运算符节点的 line。
//
// 本项目自定的三条算术规则（详见 cpp/docs/expr-optim.md §4.9）：
//   1. BinArr + BinArr == 字节连接；
//   2. String / BinArr * 非负整数 == 串重复（整数 * 串 同理）；
//   3. `+ - * / idiv % ^` 里 Bool 视作 0 / 1，但 `< <= > >=` 与 `== !=` 仍按类型区分。
//
// 判断顺序与 C++ 一一对应（层号同 expr-optim.md §4.2 / §4.7）：
//   L0 两侧必须都是字面量常量 -> L1 and/or -> L2 任一侧 null -> L3 比较 -> L4 算术
// 刻意【不】拆成 foldXxx 分派函数，保持「一个格子 = 一个分支」，方便两边对照。
//
// ⚠ 整数一律是 BigInt，且**溢出不检查、按 64 位补码回绕**（与 C++ 的 unsigned 乘法、
//    intNeg/intDiv/intMod 等价）：统一走 `BigInt.asIntN(64, …)`，不要改成抛错。

import { TokenType } from './token.js'
import * as A from './ast.js'

const NT = A.NodeType

const INT64_MIN = -(2n ** 63n)
const MAX_REPEAT_ELEM = 1 << 20 // 串重复的元素数上限：1 M

const ConstKind = {
  NotConst: 0,
  Null: 1,
  Bool: 2,
  Int: 3,
  Float: 4,
  String: 5,
  BinArr: 6,
}

const wrap64 = (v) => BigInt.asIntN(64, v)

// ==================== 入口 ====================
// 返回一个（可能是新的）节点：成功折叠时是新常量节点，否则是入参本身。
export function optimize(e) {
  if (e === null || e === undefined) return null
  if (e.nodeType === NT.UnaryOpExpr) return foldUnary(e)
  if (e.nodeType === NT.BinaryOpExpr) return foldBinary(e)
  return e
}

// ==================== 常量分类与取值 ====================
// 只有 6 种字面量是「常量」。Ident / Call / At / Args / Argc / Custom 都不是
// （值要运行期才知道，且 Call / Custom 可能有副作用）。
function kindOf(e) {
  if (e === null || e === undefined) return ConstKind.NotConst
  switch (e.nodeType) {
    case NT.NullExpr:
      return ConstKind.Null
    case NT.BoolExpr:
      return ConstKind.Bool
    case NT.IntExpr:
      return ConstKind.Int
    case NT.FloatExpr:
      return ConstKind.Float
    case NT.StringExpr:
      return ConstKind.String
    case NT.BinArrExpr:
      return ConstKind.BinArr
    default:
      return ConstKind.NotConst
  }
}

const isConst = (k) => k !== ConstKind.NotConst
// 真正的 Int / Float（不含 Bool）
const isNumeric = (k) => k === ConstKind.Int || k === ConstKind.Float
const bothInt = (lk, rk) => lk === ConstKind.Int && rk === ConstKind.Int
// String / BinArr 统称「序列」：连接、重复、相等的规则一致
const isSeq = (k) => k === ConstKind.String || k === ConstKind.BinArr
// ---------- 「算术上下文」里的 Bool：视作 0 / 1 的整数 ----------
// 只对 `+ - * / idiv % ^` 生效；`< <= > >=` 与 `== !=` 仍按各自的类型规则
const isNumLike = (k) => k === ConstKind.Bool || isNumeric(k)
// 两侧都参与整数运算（Bool 算整数），只有出现 Float 才走浮点分支
const bothNumInt = (lk, rk) =>
  isNumLike(lk) && isNumLike(rk) && lk !== ConstKind.Float && rk !== ConstKind.Float

// ---------- 取值：numAsInt / asDouble 会把 Bool 折算成 0 / 1 ----------
const asInt = (e) => e.value // BigInt
const numAsInt = (e) => (e.nodeType === NT.BoolExpr ? (e.value ? 1n : 0n) : e.value)
function asDouble(e) {
  if (e.nodeType === NT.BoolExpr) return e.value ? 1.0 : 0.0
  if (e.nodeType === NT.IntExpr) return Number(e.value)
  return e.value
}

// ==================== 序列（String / BinArr）的载荷读写 ====================
// 两者载荷类型不同（字符串 / Uint8Array），但需要的操作只有下面 4 个，
// 集中在这里分发，二元的每个格子就不必为 String 与 BinArr 各写一套分支。
function seqSize(e) {
  return e.nodeType === NT.StringExpr ? e.value.length : e.value.length
}
function seqEqual(a, b) {
  if (a.nodeType === NT.StringExpr) return a.value === b.value
  if (a.value.length !== b.value.length) return false
  for (let i = 0; i < a.value.length; ++i) if (a.value[i] !== b.value[i]) return false
  return true
}
function makeSeq(line, k) {
  return k === ConstKind.String ? new A.StringExpr(line) : new A.BinArrExpr(line)
}
function seqAppend(dst, src) {
  if (dst.nodeType === NT.StringExpr) {
    dst.value += src.value
  } else {
    const out = new Uint8Array(dst.value.length + src.value.length)
    out.set(dst.value, 0)
    out.set(src.value, dst.value.length)
    dst.value = out
  }
}

// 真值规则：null -> 假；bool -> 自身；int/float -> 非零；序列 -> 非空
function truthy(e) {
  if (e.nodeType === NT.NullExpr) return false
  if (e.nodeType === NT.BoolExpr) return e.value
  if (e.nodeType === NT.IntExpr) return e.value !== 0n
  if (e.nodeType === NT.FloatExpr) return e.value !== 0.0
  if (isSeq(kindOf(e))) return seqSize(e) !== 0
  return false
}

// ==================== 有符号整数运算（64 位回绕） ====================
// + - * 按 64 位补码回绕；除法 / 取模向零取整，INT64_MIN / -1 也回绕（不报错），
// 与 C++ 的 intDiv/intMod（先取绝对值走 unsigned）等价。
const intAdd = (a, b) => wrap64(a + b)
const intSub = (a, b) => wrap64(a - b)
const intMul = (a, b) => wrap64(a * b)
const intDiv = (a, b) => wrap64(a / b) // BigInt 的 / 已经是向零取整
const intMod = (a, b) => wrap64(a % b)
const intNeg = (a) => wrap64(-a)

// 整数快速幂，exp >= 0；溢出不检测、按 64 位回绕（与 C++ 的 unsigned 乘法一致）
function intPow(base, exp) {
  let result = 1n
  let b = base
  let e = exp
  while (e > 0n) {
    if (e & 1n) result = wrap64(result * b)
    e >>= 1n
    if (e > 0n) b = wrap64(b * b)
  }
  return result
}

// ==================== 造节点 / 拷贝常量 / 取负 / 串重复 ====================
const makeBool = (line, v) => new A.BoolExpr(line, v)
const makeInt = (line, v) => new A.IntExpr(line, v)
const makeFloat = (line, v) => new A.FloatExpr(line, v)

// 拷贝一个字面量常量节点（用于 null + X -> X 这类规则），非常量返回 null
function cloneConst(line, e) {
  switch (e.nodeType) {
    case NT.NullExpr:
      return new A.NullExpr()
    case NT.BoolExpr:
      return makeBool(line, e.value)
    case NT.IntExpr:
      return makeInt(line, asInt(e))
    case NT.FloatExpr:
      return makeFloat(line, e.value)
  }
  const k = kindOf(e)
  if (!isSeq(k)) return null
  const r = makeSeq(line, k)
  seqAppend(r, e)
  return r
}

// 取负：Int/Float -> 同类型取负；Bool -> 转成 Int 取负。
// 不可取负（null / 序列）返回 null。整数按 64 位回绕（-INT64_MIN == INT64_MIN）。
function negateConst(line, e) {
  switch (e.nodeType) {
    case NT.BoolExpr:
      return makeInt(line, e.value ? -1n : 0n)
    case NT.IntExpr:
      return makeInt(line, intNeg(asInt(e)))
    case NT.FloatExpr:
      return makeFloat(line, -e.value)
  }
  return null
}

// 串重复：`"ab" * 3` / `'x 41' * 3`。times 必须是非负整数（Bool 已在调用侧折算）；
// 负次或结果元素数超过上限 -> null。
function repeatSeq(line, base, times) {
  if (times < 0n) return null // 负次重复无定义 -> 不折叠
  const unit = seqSize(base)
  if (unit === 0) return makeSeq(line, kindOf(base)) // 空串/空数组的任意次重复仍是空
  if (times > BigInt(Math.floor(MAX_REPEAT_ELEM / unit))) return null // 结果过大 -> 不折叠
  const r = makeSeq(line, kindOf(base))
  for (let i = 0n; i < times; ++i) seqAppend(r, base)
  return r
}

// `<` `<=` `>` `>=` 的四分支（整数与浮点共用一套）
function cmpOf(op, a, b) {
  if (op === TokenType.LT) return a < b
  if (op === TokenType.LE) return a <= b
  if (op === TokenType.GT) return a > b
  return a >= b
}

// ==================== 一元 ====================
function foldUnary(e) {
  if (e === null || e.expr === null) return e
  const line = e.line
  const inn = e.expr
  const ck = kindOf(inn)
  if (!isConst(ck)) return e // 非常量 -> 不折叠
  // `!` 走 truthy；`-` 走 negateConst（Bool 折算成 Int，null / 序列不可取负 -> 不折叠）
  let ret = null
  if (e.op === TokenType.Not) {
    if (ck === ConstKind.Null || isNumLike(ck)) ret = makeBool(line, !truthy(inn))
  } else if (e.op === TokenType.Sub) {
    ret = negateConst(line, inn)
  }
  return ret ?? e
}

// ==================== 二元 ====================
function foldBinary(e) {
  if (e === null || e.leftExpr === null || e.rightExpr === null) return e
  const ret = tryFoldBinary(e)
  return ret ?? e
}

function tryFoldBinary(e) {
  const line = e.line
  const op = e.op
  const L = e.leftExpr
  const R = e.rightExpr
  const lk = kindOf(L)
  const rk = kindOf(R)
  // L0 两侧必须都是字面量常量：否则既算不出值，也可能吞掉 Call/Custom 的副作用
  if (!isConst(lk) || !isConst(rk)) return null

  // ---------- L1 and / or：结果与类型无关，恒返回 Bool ----------
  if (op === TokenType.And) return makeBool(line, truthy(L) && truthy(R))
  if (op === TokenType.Or) return makeBool(line, truthy(L) || truthy(R))

  // ---------- L2 null 参与 ----------
  // null 不是数字，也不参与算术：`+ - * / idiv % ^` 一律不折叠，交给后端报错。
  // 只有 `==` `!=` 有确定结论：null 只与 null 相等。< <= > >= 本该是类型错误 -> 不折叠。
  if (lk === ConstKind.Null || rk === ConstKind.Null) {
    const bothNull = lk === ConstKind.Null && rk === ConstKind.Null
    if (op === TokenType.EQ) return makeBool(line, bothNull)
    if (op === TokenType.NE) return makeBool(line, !bothNull)
    return null
  }

  // ---------- L3 相等与大小比较 ----------
  // 到这里两侧都非 null；跨类型一律不折叠（强制转换规则未定，见 expr-optim.md §4.5）
  if (op === TokenType.EQ || op === TokenType.NE) {
    let decided = false
    let eq = false
    if (lk === ConstKind.Bool && rk === ConstKind.Bool) {
      decided = true
      eq = L.value === R.value
    } else if (isNumeric(lk) && isNumeric(rk)) {
      // Bool ⊕ 数字 -> 不折
      decided = true
      eq = bothInt(lk, rk) ? asInt(L) === asInt(R) : asDouble(L) === asDouble(R)
    } else if (isSeq(lk) && lk === rk) {
      decided = true
      eq = seqEqual(L, R)
    }
    if (decided) return makeBool(line, op === TokenType.EQ ? eq : !eq)
    return null
  }
  if (op === TokenType.LT || op === TokenType.LE || op === TokenType.GT || op === TokenType.GE) {
    // Bool 与序列不参与数值比较 -> 两侧都必须是 Int / Float
    if (isNumeric(lk) && isNumeric(rk)) {
      return makeBool(
        line,
        bothInt(lk, rk) ? cmpOf(op, asInt(L), asInt(R)) : cmpOf(op, asDouble(L), asDouble(R)),
      )
    }
    return null
  }

  // ---------- L4 算术 + - * / idiv % ^ ----------
  // 到这里两侧都非 null，左值只剩两类：数值（Bool 折算成 0/1）与序列
  if (isNumLike(lk)) {
    // ===== L4a 左值是 Bool / Int / Float =====
    if (op === TokenType.Add || op === TokenType.Sub || op === TokenType.Mul) {
      if (isNumLike(rk)) {
        if (bothNumInt(lk, rk)) {
          // 两侧都没有 Float -> 整数路径，溢出不检查、按 64 位回绕
          const a = numAsInt(L)
          const b = numAsInt(R)
          if (op === TokenType.Add) return makeInt(line, intAdd(a, b))
          if (op === TokenType.Sub) return makeInt(line, intSub(a, b))
          return makeInt(line, intMul(a, b))
        }
        // 任一侧是 Float -> 浮点路径
        const x = asDouble(L)
        const y = asDouble(R)
        const v = op === TokenType.Add ? x + y : op === TokenType.Sub ? x - y : x * y
        return makeFloat(line, v)
      } else if (op === TokenType.Mul && isSeq(rk) && lk !== ConstKind.Float) {
        return repeatSeq(line, R, numAsInt(L)) // 数字 * 串 == 串重复
      }
    } else if (op === TokenType.Div) {
      if (isNumLike(rk)) {
        if (bothNumInt(lk, rk)) {
          const a = numAsInt(L)
          const b = numAsInt(R)
          // 除零 -> 不折叠；除不尽 -> 浮点数
          if (b !== 0n) {
            return intMod(a, b) === 0n
              ? makeInt(line, intDiv(a, b))
              : makeFloat(line, Number(a) / Number(b))
          }
        } else {
          const bb = asDouble(R)
          if (bb !== 0.0) return makeFloat(line, asDouble(L) / bb)
        }
      }
    } else if (op === TokenType.IDiv) {
      if (bothNumInt(lk, rk)) {
        // 含浮点 -> float->int 收窄，不折叠
        const a = numAsInt(L)
        const b = numAsInt(R)
        if (b !== 0n) return makeInt(line, intDiv(a, b)) // 向零取整
      }
    } else if (op === TokenType.Mod) {
      if (isNumLike(rk)) {
        if (bothNumInt(lk, rk)) {
          const a = numAsInt(L)
          const b = numAsInt(R)
          if (b !== 0n) return makeInt(line, intMod(a, b))
        } else {
          const bb = asDouble(R)
          if (bb !== 0.0) return makeFloat(line, asDouble(L) % bb)
        }
      }
    } else if (op === TokenType.Pow) {
      if (isNumLike(rk)) {
        if (bothNumInt(lk, rk)) {
          const b = numAsInt(R)
          // 非负整数指数走快速幂（溢出回绕）；负指数落到浮点分支
          if (b >= 0n) return makeInt(line, intPow(numAsInt(L), b))
        }
        const rr = Math.pow(asDouble(L), asDouble(R)) // 负指数 / 含浮点
        if (Number.isFinite(rr)) return makeFloat(line, rr) // NaN / Inf -> 不折叠
      }
      // ===== L4b 左值是序列（String / BinArr）=====
    }
  } else if (isSeq(lk)) {
    if (op === TokenType.Add) {
      if (rk === lk) {
        // 同类才连接：字符串拼接 / 字节连接（跨类型不折）
        const ret = makeSeq(line, lk)
        seqAppend(ret, L)
        seqAppend(ret, R)
        return ret
      }
    } else if (op === TokenType.Mul) {
      if (rk === ConstKind.Int || rk === ConstKind.Bool) {
        return repeatSeq(line, L, numAsInt(R)) // 串 * 整数 == 串重复
      }
    }
    // 其余运算符（Sub 等）对序列无定义 -> 不折叠
  }
  return null
}

export { ConstKind, INT64_MIN, kindOf, truthy }
