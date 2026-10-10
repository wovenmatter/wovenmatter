import Foundation
import WebKit

/// Model-authored code runs in a separate WebKit worker, never the SDK's privileged JSContext.
/// CSP blocks network access; only individually validated tool calls cross into native code.
@MainActor
final class PiCodeModeExecutor: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
  typealias Tool = @MainActor (String, String) async throws -> String
  private var browser: WKWebView?
  private var continuation: CheckedContinuation<String, any Error>?
  private var watchdog: Task<Void, Never>?
  private var pending: [String: Task<Void, Never>] = [:]
  private var tool: Tool?
  private var allowed = Set<String>()
  private var request: [String: Any] = [:]
  private var finished = false

  func run(requestJSON: String, timeout: Duration = .seconds(120), tool: @escaping Tool) async throws -> String {
    guard let request = try JSONSerialization.jsonObject(with: Data(requestJSON.utf8)) as? [String: Any],
          let source = request["source"] as? String, source.utf8.count <= 131_072,
          let tools = request["tools"] as? [[String: Any]] else {
      throw PiDurableRuntimeError.unavailable("Invalid code-mode request")
    }
    self.request = request; self.tool = tool
    allowed = Set(tools.compactMap { $0["name"] as? String })
    return try await withTaskCancellationHandler {
      try Task.checkCancellation()
      return try await withCheckedThrowingContinuation { continuation in
        self.continuation = continuation
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController.add(self, name: "wovenCodeMode")
        let view = WKWebView(frame: .zero, configuration: configuration)
        browser = view; view.navigationDelegate = self
        view.loadHTMLString(Self.html, baseURL: nil)
        watchdog = Task { [weak self] in
          do { try await Task.sleep(for: timeout) } catch { return }
          self?.finish(.failure(PiDurableRuntimeError.unavailable("Code execution exceeded its two-minute limit.")))
        }
      }
    } onCancel: {
      Task { @MainActor [weak self] in self?.finish(.failure(CancellationError())) }
    }
  }

  func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    guard !finished else { return }
    let source = request["source"] as? String ?? ""
    let tools = request["tools"] as? [[String: Any]] ?? []
    let state = request["state"] as? [String: Any] ?? [:]
    Task { [weak self] in
      do { _ = try await webView.callAsyncJavaScript("window.__wovenRun(source, tools, state)", arguments: ["source":source,"tools":tools,"state":state], in: nil, contentWorld: .page) }
      catch { self?.finish(.failure(error)) }
    }
  }
  func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) { finish(.failure(error)) }
  func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) { finish(.failure(error)) }
  func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
    finish(.failure(PiDurableRuntimeError.unavailable("The isolated code process was interrupted.")))
  }
  func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
    decisionHandler(navigationAction.request.url?.absoluteString == "about:blank" ? .allow : .cancel)
  }
  func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
    guard !finished, message.name == "wovenCodeMode", let body = message.body as? [String: Any],
          let kind = body["type"] as? String else { return }
    if kind == "done" {
      do {
        let data = try JSONSerialization.data(withJSONObject: body["result"] ?? [:])
        guard data.count <= 1_048_576 else { throw PiDurableRuntimeError.unavailable("Code output exceeds one MiB.") }
        finish(.success(String(decoding: data, as: UTF8.self)))
      } catch { finish(.failure(error)) }
    } else if kind == "failure" {
      finish(.failure(PiDurableRuntimeError.unavailable(body["message"] as? String ?? "Code execution failed.")))
    } else if kind == "tool" {
      guard pending.count < 32, let id = body["id"] as? String, pending[id] == nil,
            let name = body["name"] as? String, allowed.contains(name), let tool else {
        finish(.failure(PiDurableRuntimeError.unavailable("Code requested an unavailable tool."))); return
      }
      do {
        let data = try JSONSerialization.data(withJSONObject: body["arguments"] ?? [:])
        guard data.count <= 1_048_576 else { throw PiDurableRuntimeError.unavailable("Code tool arguments exceed one MiB.") }
        let arguments = String(decoding: data, as: UTF8.self)
        pending[id] = Task { [weak self] in
          let response: [String: Any]
          do {
            let result = try await tool(name, arguments)
            response = ["id":id,"ok":true,"value":try JSONSerialization.jsonObject(with: Data(result.utf8))]
          } catch { response = ["id":id,"ok":false,"error":error.localizedDescription] }
          guard let self, !self.finished else { return }
          self.pending.removeValue(forKey: id)
          do { _ = try await self.browser?.callAsyncJavaScript("window.__wovenReply(response)", arguments: ["response":response], in: nil, contentWorld: .page) }
          catch { self.finish(.failure(error)) }
        }
      } catch { finish(.failure(error)) }
    }
  }
  private func finish(_ result: Result<String, any Error>) {
    guard !finished else { return }
    finished = true
    watchdog?.cancel(); watchdog = nil
    for task in pending.values { task.cancel() }; pending.removeAll()
    browser?.evaluateJavaScript("window.__wovenStop()", completionHandler: nil)
    browser?.stopLoading()
    browser?.configuration.userContentController.removeScriptMessageHandler(forName: "wovenCodeMode")
    browser?.navigationDelegate = nil; browser = nil
    tool = nil; request = [:]
    let continuation = self.continuation; self.continuation = nil
    continuation?.resume(with: result)
  }

  private static let html = #"""
  <!doctype html><meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'unsafe-inline' 'unsafe-eval' blob:; worker-src blob:; connect-src 'none'; img-src 'none'; style-src 'none'; frame-src 'none'; object-src 'none'; base-uri 'none'; form-action 'none'"><script>
  (() => {
    let worker;
    window.__wovenStop = () => { worker?.terminate(); worker = null; };
    window.__wovenReply = response => worker?.postMessage({type:'reply',...response});
    window.__wovenRun = (source, definitions, initialState) => {
      const boot = async function() {
        let next = 0, started = false;
        const waiting = new Map();
        self.onmessage = async event => {
          const value = event.data;
          if (value.type === 'reply') {
            const pending = waiting.get(value.id); if (!pending) return;
            waiting.delete(value.id);
            value.ok ? pending.resolve(value.value) : pending.reject(new Error(value.error)); return;
          }
          if (started || value.type !== 'run') return;
          started = true;
          const state = Object.assign(Object.create(null),value.state), output = [];
          let outputBytes = 0;
          const text = value => {
            const text = typeof value === 'string' ? value : JSON.stringify(value);
            outputBytes += new TextEncoder().encode(text??'').length;
            if (outputBytes > 524288) throw new Error('Code text output exceeds 512 KiB.');
            output.push({type:'text',text:text??'undefined'});
          };
          const tools = Object.create(null);
          for (const definition of value.tools) {
            tools[definition.name] = args => new Promise((resolve,reject) => {
              const id = String(++next); waiting.set(id,{resolve,reject});
              self.postMessage({type:'tool',id,name:definition.name,arguments:args??{}});
            });
          }
          const store = (key, data) => { state[String(key)] = JSON.parse(JSON.stringify(data)); };
          const load = key => state[String(key)];
          try {
            const AsyncFunction = Object.getPrototypeOf(async function(){}).constructor;
            const fn = new AsyncFunction('tools','ALL_TOOLS','text','store','load',value.source);
            await fn(Object.freeze(tools),value.tools,text,store,load);
            if (waiting.size) throw new Error('Await every tool call before returning from code.');
            self.postMessage({type:'done',result:{content:output,state}});
          } catch (error) {
            self.postMessage({type:'failure',message:String(error?.message??error)});
          }
        };
      };
      const url = URL.createObjectURL(new Blob(['('+boot.toString()+')()'],{type:'text/javascript'}));
      worker = new Worker(url); URL.revokeObjectURL(url);
      worker.onmessage = event => window.webkit.messageHandlers.wovenCodeMode.postMessage(event.data);
      worker.onerror = event => window.webkit.messageHandlers.wovenCodeMode.postMessage({type:'failure',message:event.message??'Code worker failed.'});
      worker.postMessage({type:'run',source,tools:definitions,state:initialState});
    };
  })();
  </script>
  """#
}
