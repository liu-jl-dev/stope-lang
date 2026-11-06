#pragma once
#include <stope/stml_parser.hpp>
#include "Runtime.hpp"

struct DocVisitor {
  void VisitDoc(Stope::STML::Element& doc, Runtime& rt);
  void VisitFunc(Stope::STML::Element& e, Runtime& rt);
  void VisitClass(Stope::STML::Element& e, Runtime& rt);
  void VisitMethod(Stope::STML::Element& e, Runtime& rt, Class& cls);
};
