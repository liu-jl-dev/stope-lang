#pragma once
#include <map>
#include <string>
#include <vector>

namespace Stope {

namespace AST {
struct Stmt;  // defers 只存指针，不需要完整定义
}

enum class ScopeType {
  File,   // 文件作用域（顶层）
  Block,  // 块作用域：承载变量名
  While,  // 循环作用域：只为 break / continue 服务
};

struct Scope {
  ScopeType type;
  explicit Scope(ScopeType t) : type(t) {}
  virtual ~Scope() = default;
  Scope(const Scope&) = delete;
  Scope& operator=(const Scope&) = delete;
};

// 变量名作用域：标识符 → 变量总表中的索引。
// 对照参考实现 gdscript/stope/stope_compiler.gd 的 BlockScope。
struct BlockScope : Scope {
  std::map<std::u16string, int> idMap;
  // 名字 → 声明序号（Compiler::declCounter 的全局值，跨 scope 可比）。
  // defer 的「冻结名字绑定」靠它判定：载荷解析到的本地名字若序号晚于
  // defer 语句处的基线，报 "declared after the defer statement."。
  // 隐式导出（从未声明的宿主变量）记 -1，豁免检查。
  std::map<std::u16string, int> idOrder;
  // defer 语句在本 scope 的登记：载荷指针（所有权留在 AST）、defer 行号、
  // 登记时的声明序号基线。退出点（块尾 / break / continue / return）由
  // Compiler 逆序拼接 —— 运行时没有 defer 栈，顺序在编译期物化。
  struct Deferred {
    AST::Stmt* stmt;
    int line;
    int orderBaseline;
  };
  std::vector<Deferred> defers;
  // 该 scope 是否为 defer 载荷的隐式作用域：break / continue / return
  // 不得跨越它（break/continue 的目标循环在载荷外 → 报错；return 在
  // 载荷内一律报错）。
  bool isDeferPayload = false;

  BlockScope() : Scope(ScopeType::Block) {}
};

// 文件作用域：参考实现里 file_scope 就是一个 BlockScope，
// export 与「未声明就使用的标识符」都落到这里。
struct FileScope : BlockScope {
  FileScope() { type = ScopeType::File; }
};

// 循环作用域：不参与变量名查找（findIdentHost 只认 BlockScope）。
struct WhileScope : Scope {
  int startIndex = 0;             // continue 跳回这里（循环开头）
  std::vector<int> breakIndices;  // 待回填的 break 跳转目标（code 中的操作数位置）
  WhileScope() : Scope(ScopeType::While) {}
};

}  // namespace Stope
