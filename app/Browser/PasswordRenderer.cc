#include "PasswordRenderer.h"
#include "PasswordForms.h"
#include "include/cef_parser.h"
#include "include/wrapper/cef_message_router.h"
#include <map>

namespace {
CefMessageRouterConfig RouterConfig() {
  CefMessageRouterConfig config;
  config.js_query_function = "wovenPasswordsQuery";
  config.js_cancel_function = "wovenPasswordsCancel";
  return config;
}
class PasswordRenderer final : public CefApp, public CefRenderProcessHandler {
 public:
  CefRefPtr<CefRenderProcessHandler> GetRenderProcessHandler() override { return this; }
  void OnWebKitInitialized() override { router_ = CefMessageRouterRendererSide::Create(RouterConfig()); }
  void OnContextCreated(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame,
                        CefRefPtr<CefV8Context> context) override {
    if (!frame->IsMain()) return;
    router_->OnContextCreated(browser, frame, context);
    CefRefPtr<CefV8Value> installer;
    CefRefPtr<CefV8Exception> exception;
    if (context->Eval(kWovenPasswordForms, "woven-passwords", 1, installer, exception) && installer->IsFunction()) {
      auto query = context->GetGlobal()->GetValue("wovenPasswordsQuery");
      auto fill = installer->ExecuteFunctionWithContext(context, nullptr, {query});
      if (fill && fill->IsFunction()) contexts_[frame->GetIdentifier()] = {context, fill};
    }
  }
  void OnContextReleased(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame,
                         CefRefPtr<CefV8Context> context) override {
    if (!frame->IsMain()) return;
    contexts_.erase(frame->GetIdentifier());
    router_->OnContextReleased(browser, frame, context);
  }
  bool OnProcessMessageReceived(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame,
                                CefProcessId source, CefRefPtr<CefProcessMessage> message) override {
    if (source != PID_BROWSER || !frame->IsMain()) return false;
    if (message->GetName() == "WovenPasswordFill") {
      auto found = contexts_.find(frame->GetIdentifier());
      if (found == contexts_.end()) return true;
      auto context = found->second.context;
      if (!context->IsValid()) return true;
      CefURLParts url;
      CefParseURL(frame->GetURL(), url);
      auto arguments = message->GetArgumentList();
      auto origin = CefString(&url.origin).ToString();
      if (!origin.empty() && origin.back() == '/') origin.pop_back();
      if (arguments->GetString(0) != origin) return true;
      context->Enter();
      auto credential = CefV8Value::CreateObject(nullptr, nullptr);
      credential->SetValue("manual", CefV8Value::CreateBool(true), V8_PROPERTY_ATTRIBUTE_NONE);
      credential->SetValue("origin", CefV8Value::CreateString(arguments->GetString(0)), V8_PROPERTY_ATTRIBUTE_NONE);
      credential->SetValue("username", CefV8Value::CreateString(arguments->GetString(1)), V8_PROPERTY_ATTRIBUTE_NONE);
      credential->SetValue("password", CefV8Value::CreateString(arguments->GetString(2)), V8_PROPERTY_ATTRIBUTE_NONE);
      found->second.fill->ExecuteFunctionWithContext(context, nullptr, {credential});
      context->Exit();
      return true;
    }
    return router_ && router_->OnProcessMessageReceived(browser, frame, source, message);
  }
 private:
  struct Context { CefRefPtr<CefV8Context> context; CefRefPtr<CefV8Value> fill; };
  std::map<CefString, Context> contexts_;
  CefRefPtr<CefMessageRouterRendererSide> router_;
  IMPLEMENT_REFCOUNTING(PasswordRenderer);
};
}
CefRefPtr<CefApp> WovenPasswordRendererApp() { return new PasswordRenderer; }
