#include "API.hpp"

#include "ObjectManager.hpp"

using namespace Stope;

// ==================== API：三个开口的薄转发 ====================

void API::HandleAt(BasicVM::State& s, const BasicVM::Value& handle,
                   const BasicVM::Value& key, BasicVM::Value& out) {
  objMgr->At(s, handle, key, out);
}

void API::HandleAssign(BasicVM::State& s, const BasicVM::Value& handle,
                       const BasicVM::Value& value) {
  objMgr->Assign(s, handle, value);
}

void API::HandleCall(BasicVM::State& s, const BasicVM::Value& handle,
                     std::span<BasicVM::Value> args, BasicVM::Value& out) {
  objMgr->Call(s, handle, args, out);
}
