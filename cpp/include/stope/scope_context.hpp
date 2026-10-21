#pragma once
#include <map>
#include <string>
#include <vector>

namespace Stope {

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
