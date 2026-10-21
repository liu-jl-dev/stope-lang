#pragma once
#include <cmath>
#include <cstdint>
#include <string>
#include <vector>
#include <stope/ast.hpp>

namespace Stope {

// 常量折叠：在构造 AST 节点时就地求值，把「操作数全是字面量」的子树替换成一个
// 字面量节点。完整行为说明（含可调整的行为矩阵）见同目录的 expr_optim.md。
//
// 【调用契约】Optimize 成功折叠时会 delete 入参并返回一个**新**指针；未折叠时
//            原样返回入参。因此调用方必须重新赋值：  e = opt.Optimize(e);
//            更推荐 OptimizeInPlace(e)：引用入参，不可能忘记接收返回值。
//
// 【必须自底向上调用】本实现只做「单节点」变换，不递归处理子节点。把它挂在
//            parseUnaryOpExpr / parseBinaryOpExpr 的构造末尾（或 parseExpr 的
//            唯一出口），子节点返回时就已折叠好，整棵树的折叠自然完成。
//
// 【拿不准就一律不折叠】除零、float→int 收窄等情况保留原节点，交给后端按自身
//            语义去执行或报错。不折叠永远只是「少一次优化」，不改变程序语义。
//
// 【整数溢出不检查】`+ - * / idiv % ^` 的整数结果一律按 64 位补码回绕，与参考
//            实现 basic_vm.hpp 保持一致（详见 expr_optim.md §5）。
//
// 【本项目自定的三条算术规则】（2026-10-16 定夺，详见 expr_optim.md §4.9）
//            1. BinArr + BinArr == 字节连接；
//            2. String / BinArr * 非负整数 == 串重复（`整数 * 串` 同理）；
//            3. `+ - * / idiv % ^` 的算术上下文里 Bool 视作 0 / 1（含 Bool⊕Bool），
//               但 `< <= > >=` 与 `== !=` 仍按类型区分（Bool 与数字比较 / 相等
//               一律不折）。
struct ExpressionOptimizer {
  AST::Expr* Optimize(AST::Expr* expr);

  // 原地替换：调用方不可能漏掉返回值。
  void OptimizeInPlace(AST::Expr*& expr);

 private:
  // ==================== 常量分类与取值 ====================
  // 只有这 6 种是「字面量常量」。Ident / Call / At / Args / Argc / Custom 都不是
  // （值要到运行期才知道，且 Call / Custom 可能有副作用）。
  enum class ConstKind { NotConst, Null, Bool, Int, Float, String, BinArr };

  static ConstKind kindOf(const AST::Expr* e);
  static bool isConst(ConstKind k);
  // 真正的 Int / Float（不含 Bool）
  static bool isNumeric(ConstKind k);
  static bool bothInt(ConstKind lk, ConstKind rk);
  // String / BinArr 统称「序列」：连接、重复、相等的规则一致
  static bool isSeq(ConstKind k);
  // ---------- 「算术上下文」里的 Bool：视作 0 / 1 的整数 ----------
  // 只对 `+ - * / idiv % ^` 生效；`< <= > >=` 与 `== !=` 仍按各自的类型规则
  // （即 Bool 与数字比较、相等一律不折叠），详见 expr_optim.md §4.5 / §4.9。
  static bool isNumLike(ConstKind k);
  // 两侧都参与整数运算（Bool 算整数），只有出现 Float 才走浮点分支
  static bool bothNumInt(ConstKind lk, ConstKind rk);
  // ---------- 取值 ----------
  // numAsInt / asDouble 会把 Bool 折算成 0 / 1；asInt / xxVal 不折算
  static bool boolVal(const AST::Expr* e);
  static int64_t asInt(const AST::Expr* e);
  static double doubleVal(const AST::Expr* e);
  static int64_t numAsInt(const AST::Expr* e);
  static double asDouble(const AST::Expr* e);

  // ==================== 序列（String / BinArr）的载荷读写 ====================
  // 两者载荷类型不同（u16string / vector<char>），但需要的操作只有下面 5 个，
  // 集中在这里分发，二元的每个格子就不必为 String 与 BinArr 各写一套分支。
  static size_t seqSize(const AST::Expr* e);
  static bool seqEqual(const AST::Expr* a, const AST::Expr* b);
  static AST::Expr* makeSeq(int line, ConstKind k);
  static void seqReserve(AST::Expr* e, size_t n);
  // 把 src 的载荷追加到 dst 末尾（两者必须同为 String 或同为 BinArr）
  static void seqAppend(AST::Expr* dst, const AST::Expr* src);

  // 真值规则：null → 假；bool → 自身；int/float → 非零；序列 → 非空。
  static bool truthy(const AST::Expr* e);

  // ==================== 整数运算：不检查溢出，按 64 位补码回绕 ====================
  // 全程用无符号运算（C++20 起 uint64→int64 的转换是取模，不是 UB）。
  // 除法 / 取模也走无符号，只为躲开 INT64_MIN / -1 的硬件陷阱 —— 那不是「溢出
  // 检查」，只是不让进程崩；结果仍然是回绕后的值。
  static int64_t intAdd(int64_t a, int64_t b);
  static int64_t intSub(int64_t a, int64_t b);
  static int64_t intMul(int64_t a, int64_t b);
  static int64_t intNeg(int64_t a);
  // 向零取整 / 取余；调用方保证 b != 0
  static int64_t intDiv(int64_t a, int64_t b);
  static int64_t intMod(int64_t a, int64_t b);
  // 整数快速幂，exp >= 0；回绕
  static int64_t intPow(int64_t base, int64_t exp);

  // ==================== 造节点 / 取负 / 串重复 ====================
  // 只留确实用得上的三种字面量工厂：null 不参与算术，没有折出 Null 的场合。
  static AST::Expr* makeBool(int line, bool v);
  static AST::Expr* makeInt(int line, int64_t v);
  static AST::Expr* makeFloat(int line, double v);
  // 取负：Int/Float → 同类型取负；Bool → 转成 Int 取负。
  // 不可取负（null / 序列）返回 nullptr；整数取负按补码回绕（`-INT64_MIN` 也得
  // `INT64_MIN`），不再因为溢出放弃折叠。
  static AST::Expr* negateConst(int line, const AST::Expr* e);
  // 串重复：`"ab" * 3` / `'x 41' * 3`。times 必须是非负整数
  // （Bool 已在调用侧折算成 0 / 1）；负次或结果元素数超过上限 → 返回 nullptr。
  static constexpr int64_t kMaxRepeatElem = 1 << 20;  // 元素数上限：1 M
  static AST::Expr* repeatSeq(int line, const AST::Expr* base, int64_t times);
  // `<` `<=` `>` `>=` 的四分支（整数与浮点共用一套）
  template <class T>
  static bool cmpOf(TokenType op, T a, T b);

  // ==================== 一元 ====================
  AST::Expr* optimizeUnaryOpExpr(AST::UnaryOpExpr* e);

  // ==================== 二元 ====================
  // 【结构】还是一个函数，判断顺序自上而下（层号对应 expr_optim.md §4.2 / §4.7）：
  //   L0 两侧必须都是字面量常量，否则不折（含 Call / Custom 的副作用保护）
  //   L1 and / or        —— 结果与左值类型无关，恒走 truthy
  //   L2 任一侧是 null   —— 一次处理完，下面的分支里都不再判 null
  //   L3 == != < <= > >= —— 只取决于两侧是否同为序列 / 同为数字
  //   L4 + - * / idiv % ^—— 只剩两类左值：数值（Bool 折算 0/1）与序列（连接、重复）
  // L1–L3 在每个左值分支里原本是逐字重复的，提出来只为去重；
  // 每一层都保持「一个格 = 一个分支」，方便对照 expr_optim.md §4 的行为矩阵。
  // 不拆成 foldNull / foldArith / foldAdd ... 等分派函数。
  AST::Expr* optimizeBinaryOpExpr(AST::BinaryOpExpr* e);
};

}  // namespace Stope
