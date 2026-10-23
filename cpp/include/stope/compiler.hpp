#pragma once
// 编译器：把 AST 编译成 Program（指令流 + 常量池 + 变量表）。
//
// 【指令流的形状】program->opcodes 是 short 数组，指令与操作数混在同一个序列里
// （与参考实现的 code:Array[int] 一致）。带操作数的指令：
//   PushInt / PushFloat / PushString / PushBinArr / PushId ——
//   常量池或变量表的索引 Call / At —— 参数个数 If / GoTo —— 跳转目标（code
//   索引） Return                                                —— 返回值个数
//   custom                                                ——
//   变长参数时多一个参数个数
// 其余指令无操作数。
//
#include <algorithm>
#include <cstdint>
#include <functional>
#include <map>
#include <memory>
#include <string>
#include <vector>

#include <stope/ast.hpp>
#include <stope/ast_visitor.hpp>
#include <stope/custom_opcode.hpp>
#include <stope/opcode.hpp>
#include <stope/program.hpp>
#include <stope/scope_context.hpp>

namespace Stope {

// 错误信息里要带上标识符，这里做一次窄化。非 ASCII 码元打成 '?' ——
// 错误信息只在开发期看，不做完整 UTF-8 转码（避免给 stope/ 引入编码依赖）。
inline std::string narrowAscii(const std::u16string& s) {
  std::string out;
  for (char16_t c : s)
    out += (c < 128) ? static_cast<char>(c) : '?';
  return out;
}

// ==================== 变量分配器 ====================
// 所有变量统一编号；块结束时索引进入回收堆复用。
// newUniqueVar 不参与回收：它给 export 与「未声明就使用的标识符」用 ——
// 变量名非空正是 Program.exports 的判据（对照参考实现 stope_asm.gd 的收尾）。
struct VariableAllocator {
  std::vector<std::u16string> vars;  // 变量总表，元素为空串表示局部变量
  std::vector<int> recycled;         // 最小堆：可复用的索引

  int num() const { return static_cast<int>(vars.size()); }
  int newVar(const std::u16string& name = std::u16string());
  int newUniqueVar(const std::u16string& name);
  void freeVar(int idx);
};

// ==================== 栈容量统计 ====================
// 只记「相对变化」，最大值最后落到 Program.requiredStackSize。
// 记账是**线性**的（按 emit 顺序走一遍），遇到分支就得手动「掰回去」——见
// converge()。
struct StackSizeManager {
  int size = 0;
  int maxSize = 0;
  void inc(int n = 1) {
    size += n;
    maxSize = std::max(maxSize, size);
  }
  void dec(int n = 1) { size -= n; }
  // 分支汇合。线性记账只能沿一条路径走，所以某条路径被 GoTo 送走以后，
  // 要把 size 扳回到「从别处跳到这里」时应有的深度，否则
  // if / 短路运算符会把容量算成各分支深度之和（实测 `a or b;` 会算成 3）。
  void converge(int depth) { size = depth; }
};

// ==================== 编译器 ====================
// 从 ASTVisitor 继承遍历骨架（visit(Node*) → visitMap → 静态分发函数 →
// onVisitXxx）， 这里只放编译语义。
//
// 两条命名红线，改代码前先看：
//   1. 语义动作写在 **onVisitXxx** 里（那是基类的钩子）。`visitXxx`
//   这个名字现在属于
//      基类的静态分发函数，本类不再有同名成员 ——
//      照抄旧代码会写出新函数而非覆盖。
//   2. 遍历的入口统一是 `Visit(Node*)`，包括 Prog：`visit(&someProg)`。
//      `visitProg(Prog&)` 这个便利重载已经没有了。
struct Compiler : public ASTVisitor {
 public:
  Program* prog = nullptr;  // 正在写入的 Program，不拥有
  const CustomOpcodeConfig* customOpcodeConfig = nullptr;
  std::vector<std::string> errors;

  Compiler(const CustomOpcodeConfig* custom = nullptr)
      : customOpcodeConfig(custom) {}
  void Reset(const CustomOpcodeConfig* custom = nullptr) {
    errors.clear();
    customOpcodeConfig = custom;
  }

  // 编译 ast，结果直接写进 out。
  // 有错误时返回 Result::Error，并把 out 复原为空 —— 等价于参考实现出错时返回
  // null：半成品 Program 跑不了，留着反而误导。
  // 参数一律传引用：两者都不允许为空，和 ParseProgram(AST::Prog&) 保持一种写法。
  Result Compile(AST::Prog& ast, Program& out);

 private:
  VariableAllocator varAlloc;
  StackSizeManager stackSize;

  std::vector<std::unique_ptr<Scope>> ownedScopes;  // 持有作用域对象
  std::vector<Scope*> scopeStack;                   // 从外到内
  // 注：curLine 在基类 ASTVisitor 里，由 visit()
  // 更新。这里不能再声明一个同名字段 —— 名字隐藏会让 emitIndex() 读到
  // Compiler::curLine（永远停在 -1），
  //    而实际被更新的是 ASTVisitor::curLine（曾差点踩进去）。

  void reset(Program& out);
  void clearOutput();

  // ---------------- 指令输出：直接写进 prog->opcodes ----------------
  int codeSize() const;
  void emitOp(Opcode op);
  // 写一个操作数（索引 / 跳转目标）。opcodes 是 short，超出范围要报错，
  // 否则回绕出来的跳转目标会把 VM 带飞。
  void emitIndex(int idx);
  // 占位：先写 -1，回填时才知道目标
  int emitPlaceholder();
  void patchIndex(int pos, int target);

  // 常量入池：相同的值只存一份，返回索引。直接写 Program 里那个池子，
  // 不给编译器再留一份副本。常量个数通常很小，线性查找足够，
  // 不必为它再维护一个 map（那又是另一份重复状态）。
  template <class T>
  int constIndex(std::vector<T>& pool, const T& v);

  void error(int line, const std::string& msg);

  // ---------------- 作用域 ----------------
  template <class T>
  T* pushScope();
  void popScope();
  // 从内向外找最近的块作用域
  BlockScope* topBlockScope();
  WhileScope* topWhileScope();
  BlockScope* findIdentHost(const std::u16string& name);
  FileScope* fileScope();

  // ---------------- 分发 ----------------
  void onVisitExprStmt(AST::ExprStmt* s) override;
  void onVisitLetStmt(AST::LetStmt* s) override;
  void onVisitReturnStmt(AST::ReturnStmt* s) override;
  void onVisitExportStmt(AST::ExportStmt* s) override;
  void onVisitBlockStmt(AST::BlockStmt* s) override;
  void onVisitIfStmt(AST::IfStmt* s) override;
  void onVisitWhileStmt(AST::WhileStmt* s) override;
  void onVisitAssignStmt(AST::AssignStmt* s) override;
  void onVisitBreakStmt(AST::BreakStmt* s) override;
  void onVisitContinueStmt(AST::ContinueStmt* s) override;

  // ---------------- 表达式 ----------------
  void onVisitNullExpr() override;
  void onVisitBoolExpr(AST::BoolExpr* e) override;
  void onVisitIntExpr(AST::IntExpr* e) override;
  void onVisitFloatExpr(AST::FloatExpr* e) override;
  void onVisitStringExpr(AST::StringExpr* e) override;
  void onVisitBinArrExpr(AST::BinArrExpr* e) override;
  void onVisitIdentExpr(AST::IdentExpr* e) override;
  void onVisitArgcExpr() override;
  void onVisitArgsExpr(AST::ArgsExpr* e) override;
  void onVisitUnaryOpExpr(AST::UnaryOpExpr* e) override;
  void onVisitBinaryOpExpr(AST::BinaryOpExpr* e) override;
  // 短路或：任一侧为真就 PushTrue，两条路径都在栈上留下恰好 1 个结果。
  // [偏离参考实现 2] 这里对 PushTrue / PushFalse 记账，且末尾不 dec，
  //                  否则 requiredStackSize 会比实际需要的小。
  void onVisitOrExpr(AST::BinaryOpExpr* e) override;
  void onVisitAndExpr(AST::BinaryOpExpr* e) override;
  void onVisitCallExpr(AST::CallExpr* e) override;
  void onVisitAtExpr(AST::AtExpr* e) override;
  void onVisitCustomOpcodeExpr(AST::CustomOpcodeExpr* e) override;

  // ---------------- 小工具 ----------------
  // 登记一个会进 Program.exports 的变量。索引来自 newUniqueVar（不回收）。
  void declareExported(const std::u16string& name, int idx);
  // 块 / if 分支 / 循环体在 AST 里都是裸 Prog（没有 BlockStmt 包着），
  // 这里补一层 BlockScope，让内部 let 的变量在离开时被回收。
  void visitBodyAsBlock(AST::Prog& prog);
  // 二元运算符 → 指令。注意二元 `-` 是 Sub 而不是 Minus
  // （[偏离参考实现 1]：参考实现的 binop_inst_map 把 `-` 映成 Minus）。
  static Opcode binaryOpcode(TokenType op);
};

}  // namespace Stope
