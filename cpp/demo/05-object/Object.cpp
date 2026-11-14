#include "Object.hpp"
#include <algorithm>
#include <functional>
#include <iostream>
#include <string>

using namespace std;
using namespace Stope;

// Handle <-> 对象指针：Handle 的 data.data 直接存指针（uint64 位型）。
BasicVM::Value ObjectToHandle(Object* p) {
  BasicVM::Value v;
  v.type = BasicVM::Value::Type::Handle;
  v.data.data = reinterpret_cast<std::uint64_t>(p);
  return v;
}

Object* HandleToObject(const Stope::BasicVM::Value& v) {
  return reinterpret_cast<Object*>(static_cast<std::uintptr_t>(v.data.data));
}

// 描述符 Handle：data.handle 直接存 descPool 下标（vector 底、下标稳定）。
BasicVM::Value DescToHandle(unsigned index) {
  BasicVM::Value v;
  v.type = BasicVM::Value::Type::Handle;
  v.data.handle = index;
  return v;
}
