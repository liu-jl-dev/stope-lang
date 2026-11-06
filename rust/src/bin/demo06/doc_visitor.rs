//! doc_visitor.rs：STML 文档 -> 类与函数，含编译、索引预算与 self 链接
//! （对应 C++ 的 DocVisitor.*）。

use std::rc::Rc;

use stope::common::Result as StopeResult;
use stope::stml::Element;
use stope::{Compiler, Lexer, Parser, Program, Prog};

use crate::classes::{FunctionInfo, MethodInfo};
use crate::object::{MemberKind, MemberRef};
use crate::object_manager::ObjectManager;
use crate::runtime::Runtime;
use stope::Value;

// 装配期失败用 panic 上传（对齐 C++ 的 throw；main 里 catch_unwind 接住）。
pub struct DocVisitor;

impl DocVisitor {
    pub fn visit_doc(&self, root: &mut Element, rt: &mut Runtime, obj_mgr: &ObjectManager) {
        for i in 0..root.children.len() {
            let tag = root.children[i].tag.clone();
            if tag == "class" {
                self.visit_class(&mut root.children[i], rt);
            } else if tag == "func" {
                self.visit_func(&mut root.children[i], rt);
            }
        }
        self.link_self_calls(rt, obj_mgr);
    }

    fn visit_class(&self, e: &mut Element, rt: &mut Runtime) {
        let cls_id = rt.new_class();
        rt.classes[cls_id].name = e.attrs["name"].clone();
        rt.class_map
            .insert(e.attrs["name"].clone(), cls_id); // 命名后再登记：new_class 时 name 还是空
        for ci in 0..e.children.len() {
            let tag = e.children[ci].tag.clone();
            if tag == "property" {
                let name = e.children[ci].attrs["name"].clone();
                let id = rt.new_member_id(&name);
                let cls = &mut rt.classes[cls_id];
                cls.member_by_id.insert(
                    id,
                    MemberRef { kind: MemberKind::Prop, index: cls.properties.len() },
                );
                cls.properties.push(name);
            } else if tag == "method" {
                let idx = rt.classes[cls_id].methods.len();
                self.visit_method(&e.children[ci], rt);
                let name = rt.classes[cls_id].methods[idx].name.clone();
                if !name.is_empty() {
                    let id = rt.new_member_id(&name);
                    let cls = &mut rt.classes[cls_id];
                    cls.member_by_id
                        .insert(id, MemberRef { kind: MemberKind::Method, index: idx });
                }
            } else if tag == "new" {
                let idx = rt.classes[cls_id].methods.len();
                let nm = e.children[ci].attrs["name"].clone();
                self.visit_method(&e.children[ci], rt);
                rt.classes[cls_id].constructor_map.insert(nm, idx);
            } else if tag == "delete" && rt.classes[cls_id].deconstructor_id == -1 {
                let idx = rt.classes[cls_id].methods.len();
                self.visit_method(&e.children[ci], rt);
                let cls = &mut rt.classes[cls_id];
                cls.deconstructor_id = idx as i32;
                // demo 6：<delete> 是 gc 回收时自动跑的析构函数，不注册
                // obj:delete 成员——没有手动删除入口，成员 id 也不为它分配。
            }
        }
    }

    fn visit_method(&self, e: &Element, rt: &mut Runtime) {
        let mut m = MethodInfo {
            export_binds: Vec::new(),
            name: e.attrs.get("name").cloned().unwrap_or_default(),
            params: Vec::new(),
            program: Rc::new(Program::new()),
            self_props: Vec::new(),
            host_binds: Vec::new(),
            self_method_binds: Vec::new(),
            param_slots: Vec::new(),
        };
        if let Some(ps) = e.attrs.get("params") {
            m.params = ps.split_whitespace().map(|s| s.to_string()).collect();
        }
        // pre_exports = 形参（属性不进：self:<属性> 走隐式导出，链接遍配对）。
        m.program = Rc::new(self.compile(&e.text, e.text_line, &m.params));
        // 装配期预计算整数索引：宿主函数 -> (槽位, 序号)；形参 -> 槽位。
        for (nm, idx) in &rt.host_func_map {
            if let Some(slot) = m.program.exports.get(nm) {
                m.host_binds.push((*slot as usize, *idx));
            }
        }
        for p in &m.params {
            m.param_slots.push(*m.program.exports.get(p).unwrap() as usize);
        }
        rt.classes.last_mut().unwrap().methods.push(m);
    }

    fn visit_func(&self, e: &Element, rt: &mut Runtime) {
        let mut f = FunctionInfo {
            name: e.attrs["name"].clone(),
            params: Vec::new(),
            program: Rc::new(Program::new()),
            host_binds: Vec::new(),
            param_slots: Vec::new(),
        };
        if let Some(ps) = e.attrs.get("params") {
            f.params = ps.split_whitespace().map(|s| s.to_string()).collect();
        }
        f.program = Rc::new(self.compile(&e.text, e.text_line, &f.params));
        for (nm, idx) in &rt.host_func_map {
            if let Some(slot) = f.program.exports.get(nm) {
                f.host_binds.push((*slot as usize, *idx));
            }
        }
        for p in &f.params {
            f.param_slots.push(*f.program.exports.get(p).unwrap() as usize);
        }
        rt.functions.push(f);
    }

    // 链接 self:<属性> 与 self:<方法名>，并校验方法里 self: 前缀的隐式导出
    // 全部链接成功（拼写错误装配期拦下）。必须在全部类访问完之后跑：方法可以
    // 引用文档里后定义的成员。<func> 里的 self: 有意不校验（见 docs §10）。
    fn link_self_calls(&self, rt: &mut Runtime, obj_mgr: &ObjectManager) {
        for ci in 0..rt.classes.len() {
            let props = rt.classes[ci].properties.clone();
            let members: Vec<(String, i32)> = rt
                .member_name_map
                .iter()
                .map(|(k, v)| (k.clone(), *v))
                .collect();
            for mi in 0..rt.classes[ci].methods.len() {
                let exports = rt.classes[ci].methods[mi].program.exports.clone();
                let mut self_props = Vec::new();
                let mut self_method_binds = Vec::new();
                for (fi, prop) in props.iter().enumerate() {
                    if let Some(slot) = exports.get(&format!("self:{}", prop)) {
                        self_props.push((*slot as usize, fi));
                    }
                }
                for (nm, id) in &members {
                    if nm.is_empty() {
                        continue; // <delete> 无名
                    }
                    let is_method = rt.classes[ci]
                        .member_by_id
                        .get(id)
                        .map(|r| r.kind == MemberKind::Method)
                        .unwrap_or(false);
                    if !is_method {
                        continue; // 不是本类的方法成员
                    }
                    if let Some(slot) = exports.get(&format!("self:{}", nm)) {
                        self_method_binds.push((*slot as usize, *id));
                    }
                }
                // 方法体里的 <类名>:<构造名> / obj:<名>：方法有独立的
                // program，这些名字是它自己的隐式导出，每个 State 都要各自
                // 绑。描述符被 export_binds 引用着——引用计数保证存活。
                let mut export_binds: Vec<(usize, Value)> = Vec::new();
                for (enm2, slot2) in &exports {
                    let colon = enm2.find(':');
                    if colon.is_none() {
                        continue;
                    }
                    let colon = colon.unwrap();
                    let head = &enm2[..colon];
                    let tail = &enm2[colon + 1..];
                    let handle = if head == "obj" {
                        match rt.member_name_map.get(tail) {
                            Some(mid) => Some(obj_mgr.new_member_desc(*mid)),
                            None => continue, // 不是任何已注册成员
                        }
                    } else {
                        match rt.class_map.get(head) {
                            Some(cid) => match rt.classes[*cid].constructor_map.get(tail) {
                                Some(ctor_idx) => {
                                    Some(obj_mgr.new_ctor_desc(*cid, *ctor_idx))
                                }
                                None => continue,
                            },
                            None => continue,
                        }
                    };
                    export_binds.push((*slot2 as usize, handle.unwrap()));
                }
                for (enm, slot) in &exports {
                    if !enm.starts_with("self:") {
                        continue;
                    }
                    let slot = *slot as usize;
                    let linked = self_props.iter().any(|p| p.0 == slot)
                        || self_method_binds.iter().any(|b| b.0 == slot);
                    if !linked {
                        panic!("unlinked self member: {}", enm);
                    }
                }
                let m = &mut rt.classes[ci].methods[mi];
                m.self_props = self_props;
                m.self_method_binds = self_method_binds;
                m.export_binds = export_binds;
            }
        }
    }

    // 编译一份源码：pre_exports = 形参；失败即 panic（对齐 C++ 的装配期异常）。
    fn compile(&self, src: &str, start_line: i32, pre_exports: &[String]) -> Program {
        let mut lexer = Lexer::new(src);
        lexer.set_line(start_line); // 报错行号对齐原文档
        let mut parser = Parser::with_lexer(lexer, None);
        let mut tree = Prog::default();
        parser.parse_program(&mut tree);
        if !parser.lexer().errors.is_empty() || !parser.errors.is_empty() {
            for e in &parser.lexer().errors.clone() {
                println!("  lexer: {}", e);
            }
            for e in &parser.errors.clone() {
                println!("  parser: {}", e);
            }
            panic!("parse failed");
        }
        let refs: Vec<&str> = pre_exports.iter().map(|s| s.as_str()).collect();
        let mut compiler = Compiler::new(None);
        let mut out = Program::new();
        if compiler.compile(&tree, &mut out, &refs) != StopeResult::Success {
            for e in &compiler.errors.clone() {
                println!("  compiler: {}", e);
            }
            panic!("compile failed");
        }
        out
    }
}
