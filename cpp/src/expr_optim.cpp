#include <stope/expr_optim.hpp>

#include <cmath>
#include <cstdint>
#include <string>
#include <vector>

namespace Stope {

AST::Expr* ExpressionOptimizer::Optimize(AST::Expr* expr) {
  if (expr == nullptr)
    return nullptr;
  if (expr->type == AST::NodeType::UnaryOpExpr)
    return optimizeUnaryOpExpr(static_cast<AST::UnaryOpExpr*>(expr));
  if (expr->type == AST::NodeType::BinaryOpExpr)
    return optimizeBinaryOpExpr(static_cast<AST::BinaryOpExpr*>(expr));
  return expr;
}

void ExpressionOptimizer::OptimizeInPlace(AST::Expr*& expr) { expr = Optimize(expr); }

ExpressionOptimizer::ConstKind ExpressionOptimizer::kindOf(const AST::Expr* e) {
  if (e == nullptr)
    return ConstKind::NotConst;
  if (e->type == AST::NodeType::NullExpr)
    return ConstKind::Null;
  if (e->type == AST::NodeType::BoolExpr)
    return ConstKind::Bool;
  if (e->type == AST::NodeType::IntExpr)
    return ConstKind::Int;
  if (e->type == AST::NodeType::FloatExpr)
    return ConstKind::Float;
  if (e->type == AST::NodeType::StringExpr)
    return ConstKind::String;
  if (e->type == AST::NodeType::BinArrExpr)
    return ConstKind::BinArr;
  return ConstKind::NotConst;
}

bool ExpressionOptimizer::isConst(ConstKind k) { return k != ConstKind::NotConst; }

bool ExpressionOptimizer::isNumeric(ConstKind k) {
  return k == ConstKind::Int || k == ConstKind::Float;
}

bool ExpressionOptimizer::bothInt(ConstKind lk, ConstKind rk) {
  return lk == ConstKind::Int && rk == ConstKind::Int;
}

bool ExpressionOptimizer::isSeq(ConstKind k) {
  return k == ConstKind::String || k == ConstKind::BinArr;
}

bool ExpressionOptimizer::isNumLike(ConstKind k) {
  return k == ConstKind::Bool || isNumeric(k);
}

bool ExpressionOptimizer::bothNumInt(ConstKind lk, ConstKind rk) {
  return isNumLike(lk) && isNumLike(rk) && lk != ConstKind::Float &&
         rk != ConstKind::Float;
}

bool ExpressionOptimizer::boolVal(const AST::Expr* e) {
  return static_cast<const AST::BoolExpr*>(e)->value;
}

int64_t ExpressionOptimizer::asInt(const AST::Expr* e) {
  return static_cast<const AST::IntExpr*>(e)->value;
}

double ExpressionOptimizer::doubleVal(const AST::Expr* e) {
  return static_cast<const AST::FloatExpr*>(e)->value;
}

int64_t ExpressionOptimizer::numAsInt(const AST::Expr* e) {
  if (e->type == AST::NodeType::BoolExpr)
    return boolVal(e) ? 1 : 0;
  return asInt(e);
}

double ExpressionOptimizer::asDouble(const AST::Expr* e) {
  if (e->type == AST::NodeType::BoolExpr)
    return boolVal(e) ? 1.0 : 0.0;
  if (e->type == AST::NodeType::IntExpr)
    return static_cast<double>(asInt(e));
  return doubleVal(e);
}

size_t ExpressionOptimizer::seqSize(const AST::Expr* e) {
  if (e->type == AST::NodeType::StringExpr)
    return static_cast<const AST::StringExpr*>(e)->value.size();
  return static_cast<const AST::BinArrExpr*>(e)->value.size();
}

bool ExpressionOptimizer::seqEqual(const AST::Expr* a, const AST::Expr* b) {
  if (a->type == AST::NodeType::StringExpr)
    return static_cast<const AST::StringExpr*>(a)->value ==
           static_cast<const AST::StringExpr*>(b)->value;
  return static_cast<const AST::BinArrExpr*>(a)->value ==
         static_cast<const AST::BinArrExpr*>(b)->value;
}

AST::Expr* ExpressionOptimizer::makeSeq(int line, ConstKind k) {
  if (k == ConstKind::String) {
    AST::StringExpr* e = new AST::StringExpr();
    e->line = line;
    return e;
  }
  AST::BinArrExpr* e = new AST::BinArrExpr();
  e->line = line;
  return e;
}

void ExpressionOptimizer::seqReserve(AST::Expr* e, size_t n) {
  if (e->type == AST::NodeType::StringExpr)
    static_cast<AST::StringExpr*>(e)->value.reserve(n);
  else
    static_cast<AST::BinArrExpr*>(e)->value.reserve(n);
}

void ExpressionOptimizer::seqAppend(AST::Expr* dst, const AST::Expr* src) {
  if (dst->type == AST::NodeType::StringExpr) {
    auto& d = static_cast<AST::StringExpr*>(dst)->value;
    const auto& s = static_cast<const AST::StringExpr*>(src)->value;
    d.insert(d.end(), s.begin(), s.end());
    return;
  }
  auto& d = static_cast<AST::BinArrExpr*>(dst)->value;
  const auto& s = static_cast<const AST::BinArrExpr*>(src)->value;
  d.insert(d.end(), s.begin(), s.end());
}

bool ExpressionOptimizer::truthy(const AST::Expr* e) {
  if (e->type == AST::NodeType::NullExpr)
    return false;
  if (e->type == AST::NodeType::BoolExpr)
    return boolVal(e);
  if (e->type == AST::NodeType::IntExpr)
    return asInt(e) != 0;
  if (e->type == AST::NodeType::FloatExpr)
    return doubleVal(e) != 0.0;
  if (isSeq(kindOf(e)))
    return seqSize(e) != 0;
  return false;
}

// ---------- 整数运算：一律按 64 位补码回绕，不做溢出检查 ----------
int64_t ExpressionOptimizer::intAdd(int64_t a, int64_t b) {
  return static_cast<int64_t>(static_cast<uint64_t>(a) +
                              static_cast<uint64_t>(b));
}

int64_t ExpressionOptimizer::intSub(int64_t a, int64_t b) {
  return static_cast<int64_t>(static_cast<uint64_t>(a) -
                              static_cast<uint64_t>(b));
}

int64_t ExpressionOptimizer::intMul(int64_t a, int64_t b) {
  return static_cast<int64_t>(static_cast<uint64_t>(a) *
                              static_cast<uint64_t>(b));
}

int64_t ExpressionOptimizer::intNeg(int64_t a) {
  return static_cast<int64_t>(static_cast<uint64_t>(0) -
                              static_cast<uint64_t>(a));
}

// 除法 / 取模先取绝对值再算，只为避开 INT64_MIN / -1 的硬件陷阱；
// 商的符号按「向零取整」、余数的符号跟被除数（C 语义）。
int64_t ExpressionOptimizer::intDiv(int64_t a, int64_t b) {
  const bool neg = (a < 0) != (b < 0);
  const uint64_t ua = a < 0 ? 0u - static_cast<uint64_t>(a)
                            : static_cast<uint64_t>(a);
  const uint64_t ub = b < 0 ? 0u - static_cast<uint64_t>(b)
                            : static_cast<uint64_t>(b);
  const uint64_t q = ua / ub;
  return neg ? static_cast<int64_t>(0u - q) : static_cast<int64_t>(q);
}

int64_t ExpressionOptimizer::intMod(int64_t a, int64_t b) {
  const bool neg = a < 0;
  const uint64_t ua = a < 0 ? 0u - static_cast<uint64_t>(a)
                            : static_cast<uint64_t>(a);
  const uint64_t ub = b < 0 ? 0u - static_cast<uint64_t>(b)
                            : static_cast<uint64_t>(b);
  const uint64_t r = ua % ub;
  return neg ? static_cast<int64_t>(0u - r) : static_cast<int64_t>(r);
}

int64_t ExpressionOptimizer::intPow(int64_t base, int64_t exp) {
  int64_t result = 1;
  uint64_t b = static_cast<uint64_t>(base);
  while (exp > 0) {
    if (exp & 1)
      result = static_cast<int64_t>(static_cast<uint64_t>(result) * b);
    exp >>= 1;
    if (exp > 0)
      b = b * b;
  }
  return result;
}

AST::Expr* ExpressionOptimizer::makeBool(int line, bool v) {
  AST::BoolExpr* e = new AST::BoolExpr();
  e->line = line;
  e->value = v;
  return e;
}

AST::Expr* ExpressionOptimizer::makeInt(int line, int64_t v) {
  AST::IntExpr* e = new AST::IntExpr();
  e->line = line;
  e->value = v;
  return e;
}

AST::Expr* ExpressionOptimizer::makeFloat(int line, double v) {
  AST::FloatExpr* e = new AST::FloatExpr();
  e->line = line;
  e->value = v;
  return e;
}

AST::Expr* ExpressionOptimizer::negateConst(int line, const AST::Expr* e) {
  if (e->type == AST::NodeType::BoolExpr)
    return makeInt(line, -static_cast<int64_t>(boolVal(e)));
  if (e->type == AST::NodeType::IntExpr)
    return makeInt(line, intNeg(asInt(e)));  // 回绕，不检查溢出
  if (e->type == AST::NodeType::FloatExpr)
    return makeFloat(line, -doubleVal(e));
  return nullptr;
}

AST::Expr* ExpressionOptimizer::repeatSeq(int line, const AST::Expr* base, int64_t times) {
  if (times < 0)
    return nullptr;  // 负次重复无定义 → 不折叠
  const int64_t unit = static_cast<int64_t>(seqSize(base));
  if (unit == 0)
    return makeSeq(line, kindOf(base));  // 空串 / 空数组的任意次重复仍是空
  if (times > kMaxRepeatElem / unit)
    return nullptr;  // 结果过大 → 不折叠，避免造出巨型常量节点
  AST::Expr* r = makeSeq(line, kindOf(base));
  seqReserve(r, static_cast<size_t>(unit * times));
  for (int64_t i = 0; i < times; ++i)
    seqAppend(r, base);
  return r;
}

template <class T> bool ExpressionOptimizer::cmpOf(TokenType op, T a, T b) {
  if (op == TokenType::LT)
    return a < b;
  if (op == TokenType::LE)
    return a <= b;
  if (op == TokenType::GT)
    return a > b;
  return a >= b;
}

AST::Expr* ExpressionOptimizer::optimizeUnaryOpExpr(AST::UnaryOpExpr* e) {
  if (e == nullptr || e->expr == nullptr)
    return e;
  const int line = e->line;
  const AST::Expr* in = e->expr.get();
  const ConstKind ck = kindOf(in);
  if (!isConst(ck))
    return e;  // 非常量 → 不折叠

  // `!` 走 truthy：null / 0 / 0.0 → true；序列的 `!` 未定义 → 不折叠（§4.3）
  // `-` 走 negateConst：Bool 折算成 Int；null / 序列不可取负 → 不折叠
  AST::Expr* ret = nullptr;
  if (e->op == TokenType::Not) {
    if (ck == ConstKind::Null || isNumLike(ck))
      ret = makeBool(line, !truthy(in));
  } else if (e->op == TokenType::Sub) {
    ret = negateConst(line, in);
  }
  if (ret == nullptr)
    return e;
  delete e;  // 所有对 e 的读取都已在上面完成
  return ret;
}

AST::Expr* ExpressionOptimizer::optimizeBinaryOpExpr(AST::BinaryOpExpr* e) {
  if (e == nullptr || e->leftExpr == nullptr || e->rightExpr == nullptr)
    return e;
  const int line = e->line;
  const TokenType op = e->op;
  AST::Expr* L = e->leftExpr.get();
  AST::Expr* R = e->rightExpr.get();
  const ConstKind lk = kindOf(L);
  const ConstKind rk = kindOf(R);
  // L0 两侧必须都是字面量常量：否则既算不出值，也可能吞掉 Call/Custom 的副作用
  if (!isConst(lk) || !isConst(rk))
    return e;

  AST::Expr* ret = nullptr;
  // ---------- L1 and / or：结果与类型无关，恒返回 Bool ----------
  if (op == TokenType::And) {
    ret = makeBool(line, truthy(L) && truthy(R));
  } else if (op == TokenType::Or) {
    ret = makeBool(line, truthy(L) || truthy(R));

    // ---------- L2 null 参与 ----------
    // null 不是数字，也不参与算术：`+ - * / idiv % ^` 一律不折叠，交给后端报错
    // （参考实现 basic_vm.hpp 同样是报错）。只有 `==` `!=` 有确定结论：
    // null 只与 null 相等。< <= > >= 本该是类型错误 → 不折叠。
  } else if (lk == ConstKind::Null || rk == ConstKind::Null) {
    const bool bothNull = (lk == ConstKind::Null && rk == ConstKind::Null);
    if (op == TokenType::EQ) {
      ret = makeBool(line, bothNull);
    } else if (op == TokenType::NE) {
      ret = makeBool(line, !bothNull);
    }

    // ---------- L3 相等与大小比较 ----------
    // 到这里两侧都非 null；跨类型一律不折叠（强制转换规则未定，见 §4.5）
  } else if (op == TokenType::EQ || op == TokenType::NE) {
    bool decided = false;
    bool eq = false;
    if (lk == ConstKind::Bool && rk == ConstKind::Bool) {
      decided = true;
      eq = boolVal(L) == boolVal(R);
    } else if (isNumeric(lk) && isNumeric(rk)) {  // Bool ⊕ 数字 → 不折
      decided = true;
      eq = bothInt(lk, rk) ? (asInt(L) == asInt(R))
                           : (asDouble(L) == asDouble(R));
    } else if (isSeq(lk) && lk == rk) {  // 串相等 / 字节相等
      decided = true;
      eq = seqEqual(L, R);
    }
    if (decided)
      ret = makeBool(line, (op == TokenType::EQ) ? eq : !eq);
  } else if (op == TokenType::LT || op == TokenType::LE ||
             op == TokenType::GT || op == TokenType::GE) {
    // Bool 与序列不参与数值比较 → 两侧都必须是 Int / Float
    if (isNumeric(lk) && isNumeric(rk))
      ret = makeBool(line,
                     bothInt(lk, rk) ? cmpOf(op, asInt(L), asInt(R))
                                     : cmpOf(op, asDouble(L), asDouble(R)));

    // ---------- L4 算术 + - * / idiv % ^ ----------
    // 到这里两侧都非 null，左值只剩两类：数值（Bool 折算成 0/1）与序列
  } else if (isNumLike(lk)) {
    // ===== L4a 左值是 Bool / Int / Float =====
    if (op == TokenType::Add || op == TokenType::Sub ||
        op == TokenType::Mul) {
      if (isNumLike(rk)) {
        if (bothNumInt(lk, rk)) {  // 两侧都没有 Float → 整数路径
          const int64_t a = numAsInt(L), b = numAsInt(R);
          int64_t r = 0;  // 回绕，不检查溢出
          if (op == TokenType::Add)
            r = intAdd(a, b);
          else if (op == TokenType::Sub)
            r = intSub(a, b);
          else
            r = intMul(a, b);
          ret = makeInt(line, r);
        } else {  // 任一侧是 Float → 浮点路径
          const double x = asDouble(L), y = asDouble(R);
          double v = 0.0;
          if (op == TokenType::Add)
            v = x + y;
          else if (op == TokenType::Sub)
            v = x - y;
          else
            v = x * y;
          ret = makeFloat(line, v);
        }
      } else if (op == TokenType::Mul && isSeq(rk) &&
                 lk != ConstKind::Float) {
        ret = repeatSeq(line, R, numAsInt(L));  // 数字 * 串 == 串重复
      }
    } else if (op == TokenType::Div) {
      if (isNumLike(rk)) {
        if (bothNumInt(lk, rk)) {
          const int64_t a = numAsInt(L), b = numAsInt(R);
          // 除零 → 不折叠（后端报错）；除不尽 → 浮点数
          if (b != 0)
            ret = (intMod(a, b) == 0)
                      ? makeInt(line, intDiv(a, b))
                      : makeFloat(line, static_cast<double>(a) /
                                            static_cast<double>(b));
        } else {
          const double b = asDouble(R);
          if (b != 0.0)
            ret = makeFloat(line, asDouble(L) / b);
        }
      }
    } else if (op == TokenType::IDiv) {
      if (bothNumInt(lk, rk)) {  // 含浮点 → float→int 收窄，不折叠
        const int64_t a = numAsInt(L), b = numAsInt(R);
        if (b != 0)
          ret = makeInt(line, intDiv(a, b));  // 向零取整
      }
    } else if (op == TokenType::Mod) {
      if (isNumLike(rk)) {
        if (bothNumInt(lk, rk)) {
          const int64_t a = numAsInt(L), b = numAsInt(R);
          if (b != 0)
            ret = makeInt(line, intMod(a, b));
        } else {
          const double b = asDouble(R);
          if (b != 0.0)
            ret = makeFloat(line, std::fmod(asDouble(L), b));
        }
      }
    } else if (op == TokenType::Pow) {
      if (isNumLike(rk)) {
        bool foldedAsInt = false;
        if (bothNumInt(lk, rk)) {
          const int64_t b = numAsInt(R);
          if (b >= 0) {  // 非负整数指数走快速幂（回绕，不检查溢出）
            ret = makeInt(line, intPow(numAsInt(L), b));
            foldedAsInt = true;  // 已定型，不再走浮点分支
          }
        }
        if (!foldedAsInt) {  // 负指数 / 含浮点 → 浮点
          const double r = std::pow(asDouble(L), asDouble(R));
          if (std::isfinite(r))  // NaN / Inf → 不折叠
            ret = makeFloat(line, r);
        }
      }
    }

    // ===== L4b 左值是序列（String / BinArr）=====
  } else if (isSeq(lk)) {
    if (op == TokenType::Add) {
      if (rk == lk) {  // 同类才连接：字符串拼接 / 字节连接（跨类型不折）
        ret = makeSeq(line, lk);
        seqReserve(ret, seqSize(L) + seqSize(R));
        seqAppend(ret, L);
        seqAppend(ret, R);
      }
    } else if (op == TokenType::Mul) {
      if (rk == ConstKind::Int || rk == ConstKind::Bool)
        ret = repeatSeq(line, L, numAsInt(R));  // 串 * 整数 == 串重复
    }
    // 其余运算符（`Sub` 等）对序列无定义 → 不折叠
  }
  if (ret == nullptr)
    return e;  // 不折叠：原节点与 line 均不变
  delete e;  // 所有对 e 的读取都已在上面完成
  return ret;
}

}  // namespace Stope
