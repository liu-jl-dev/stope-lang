#include "DocVisitor.hpp"

#include <stdexcept>

#include <stope/compiler.hpp>
#include <stope/lexer.hpp>
#include <stope/parser.hpp>
#include <stope/utf.hpp>

using namespace Stope;
using namespace std;

static void parseParams(std::u16string_view params, vector<u16string>& out) {
  u16string param;
  for (;;) {
    if (params.empty()) {
      break;
    }
    char16_t c = params[0];
    params.remove_prefix(1);
    if (c == u' ' || c == u'\t' || c == u'\n' || c == u'\r' || c == u'\v' ||
        c == u'\f') {
      if (!param.empty()) {
        out.emplace_back(param);
        param.clear();
      }
      continue;
    }
    param += c;
  }
  if (!param.empty()) {
    out.emplace_back(param);
  }
}

// 链接 self:<属性> 与 self:<方法名>。必须在全部类访问完之后跑：方法可以
// 引用文档里后定义的成员，VisitMethod 编译时它们还没注册。
static void linkSelfCalls(Runtime& rt) {
  for (auto& cls : rt.classes) {
    for (auto& m : cls.methods) {
      // self:<属性>：对每个属性查 exports，配对 (槽位下标, 字段下标)。
      for (size_t f = 0; f < cls.properties.size(); ++f) {
        auto it = m.program.exports.find(u"self:" + cls.properties[f]);
        if (it != m.program.exports.end()) {
          m.selfProps.emplace_back((unsigned)it->second, f);
        }
      }
      // self:<方法名>：memberNameMap 里的方法成员。
      for (auto& [name, id] : rt.memberNameMap) {
        if (name.empty()) {
          continue;  // <delete> 无名
        }
        auto ref = cls.memberById.find(id);
        if (ref == cls.memberById.end() || ref->second.kind != kMemberMethod) {
          continue;  // 不是本类的方法成员（属性/其它类私有注册一律不绑）
        }
        auto it = m.program.exports.find(u"self:" + name);
        if (it != m.program.exports.end()) {
          m.selfMethodBinds.emplace_back((unsigned)it->second, id);
        }
      }
      // 方法体里的 <类名>:<构造器名> / obj:<名>：方法有独立的 program，这些
      // 名字是它自己的隐式导出，每个 State 都要各自绑。描述符在装配期创建
      // 并 Pin 住——它们长住宿主侧（Method::exportBinds），不在任何 State
      // 里，gc 根扫描看不见，不 Pin 会被当垃圾收走。
      for (auto& [name, varIdx] : m.program.exports) {
        size_t colon = name.find(u':');
        if (colon == u16string::npos) {
          continue;
        }
        u16string head = name.substr(0, colon);
        u16string tail = name.substr(colon + 1);
        BasicVM::Value v;
        if (head == u"obj") {
          auto it = rt.memberNameMap.find(tail);
          if (it == rt.memberNameMap.end()) {
            continue;  // 不是任何已注册成员（属性/方法名拼写错误等）
          }
          v = rt.objMgr.NewMemberDesc(it->second);
        } else {
          auto cit = rt.classMap.find(head);
          if (cit == rt.classMap.end()) {
            continue;
          }
          Class& c = rt.classes[cit->second];
          auto mit = c.constructorMap.find(tail);
          if (mit == c.constructorMap.end()) {
            continue;
          }
          v = rt.objMgr.NewCtorDesc(c.id, mit->second);
        }
        rt.objMgr.alloc.Pin(HandleToObject(v));
        m.exportBinds.emplace_back((unsigned)varIdx, std::move(v));
      }
      // 校验：self: 前缀的隐式导出必须全部链接成功（属性或方法），否则运行
      // 时槽位是 Null 才炸——装配期就拦下（典型的拼写错误）。
      for (auto& [name, varIdx] : m.program.exports) {
        if (name.rfind(u"self:", 0) != 0) {
          continue;
        }
        bool linked = false;
        for (auto& [slotIdx, fieldIdx] : m.selfProps) {
          if (slotIdx == (unsigned)varIdx) {
            linked = true;
            break;
          }
        }
        if (!linked) {
          for (auto& [slotIdx, id] : m.selfMethodBinds) {
            if (slotIdx == (unsigned)varIdx) {
              linked = true;
              break;
            }
          }
        }
        if (!linked) {
          throw runtime_error("unlinked self member: " +
                              UTF::Utf16ToUtf8(name));
        }
      }
    }
  }
}

void DocVisitor::VisitDoc(STML::Element& doc, Runtime& rt) {
  for (auto& e : doc.children) {
    if (e.tagName == u"class") {
      VisitClass(e, rt);
    } else if (e.tagName == u"func") {
      VisitFunc(e, rt);
    }
  }
  linkSelfCalls(rt);
}

void DocVisitor::VisitClass(STML::Element& e, Runtime& rt) {
  Class& cls = rt.NewClass();
  cls.name = e.attrs[u"name"];
  rt.classMap[cls.name] = cls.id;  // 命名后再登记：exportBinds 按类名找构造器
  for (auto& e : e.children) {
    if (e.tagName == u"property") {
      // 成员 id -> 类内位置（MemberRef）：两层查询的第二层在装配期建好。
      cls.memberById[rt.NewMemberId(std::u16string(e.attrs[u"name"]))] =
          MemberRef{kMemberProp, (int)cls.properties.size()};
      cls.properties.emplace_back(e.attrs[u"name"]);
    } else if (e.tagName == u"method") {
      int idx = (int)cls.methods.size();
      VisitMethod(e, rt, cls);
      if (!cls.methods.back().name.empty()) {
        cls.memberById[rt.NewMemberId(cls.methods.back().name)] =
            MemberRef{kMemberMethod, idx};
      }
    } else if (e.tagName == u"new") {
      int idx = (int)cls.methods.size();
      cls.constructorIds.push_back(idx);
      cls.constructorMap[std::u16string(e.attrs.at(u"name"))] = idx;
      VisitMethod(e, rt, cls);
    } else if (e.tagName == u"delete" && cls.deconstructorId == -1) {
      int idx = (int)cls.methods.size();
      cls.deconstructorId = idx;
      VisitMethod(e, rt, cls);
      // demo 6：<delete> 是 gc 回收时自动跑的析构函数，不注册 obj:delete
      // 成员——没有手动删除入口，成员 id 也不为它分配。
    }
  }
}

void DocVisitor::VisitMethod(STML::Element& e, Runtime& rt, Class& cls) {
  cls.methods.emplace_back();
  Method& m = cls.methods.back();
  if (e.attrs.contains(u"name")) {
    m.name = e.attrs.at(u"name");  // <delete> 没有名字
  }
  if (e.attrs.contains(u"params")) {
    parseParams(e.attrs[u"params"], m.params);
  }

  // preExports = 形参。self:<属性> 不再预导出：方法体里对它们的引用靠编译
  // 器的隐式导出机制浮现（未声明标识符自动注册，赋值走 PushId 可写回），
  // 链接遍再与字段配对——未使用的属性不占槽位。
  Lexer lexer(e.text);
  lexer.line = e.textLine;
  Parser parser(lexer);
  AST::Prog prog;
  parser.ParseProgram(prog);
  if (!parser.errors.empty()) {
    throw runtime_error("Error parsing method: " + parser.errors[0]);
  }
  Compiler compiler;
  if (compiler.Compile(prog, m.program, m.params) != Result::Success) {
    throw runtime_error("Error compiling method: " + compiler.errors[0]);
  }
  m.constAlloc = std::make_unique<BasicVM::ProgramConstants>(rt.basicAlloc, m.program);

  // 装配期预计算整数索引：宿主函数 -> (槽位, 序号)。运行中不做按名查找。
  for (auto& [name, idx] : rt.hostFuncMap) {
    auto it = m.program.exports.find(name);
    if (it != m.program.exports.end()) {
      m.hostBinds.emplace_back(it->second, idx);
    }
  }
}

void DocVisitor::VisitFunc(STML::Element& e, Runtime& rt) {
  rt.functions.emplace_back();
  Function& func = rt.functions.back();
  func.id = rt.functions.size() - 1;
  rt.funcMap[std::u16string(e.attrs.at(u"name"))] = func.id;
  func.name = e.attrs[u"name"];
  if (e.attrs.contains(u"params")) {
    parseParams(e.attrs[u"params"], func.params);
  }

  Lexer lexer(e.text);
  lexer.line = e.textLine;
  Parser parser(lexer);
  AST::Prog prog;
  parser.ParseProgram(prog);
  if (!parser.errors.empty()) {
    throw runtime_error("Error parsing function: " + parser.errors[0]);
  }
  Compiler compiler;
  if (compiler.Compile(prog, func.program, func.params) != Result::Success) {
    throw runtime_error("Error compiling function: " + compiler.errors[0]);
  }
  func.constAlloc = std::make_unique<BasicVM::ProgramConstants>(rt.basicAlloc, func.program);

  func.paramVarIdx.resize(func.params.size());
  for (size_t i = 0; i < func.params.size(); ++i) {
    func.paramVarIdx[i] = func.program.exports.at(func.params[i]);
  }
  for (auto& [name, idx] : rt.hostFuncMap) {
    auto it = func.program.exports.find(name);
    if (it != func.program.exports.end()) {
      func.hostBinds.emplace_back(it->second, idx);
    }
  }
}
