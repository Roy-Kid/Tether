import Foundation
import WebKit

/// Which URLs a plugin page may navigate to: its own package, and the empty document WebKit starts on.
public enum WebOrigin {
  public static func allows(_ url: URL, root: URL) -> Bool {
    if url.absoluteString == "about:blank" { return true }
    guard url.isFileURL else { return false }
    return PackageRoot.contains(url, root: root)
  }
}

/// One WebKit page per session. File access stops at the package root.
@MainActor
public final class WebKitRuntime: PluginRuntime {
  private final class Page {
    let webView: WKWebView
    let navigation: PageNavigation
    init(webView: WKWebView, navigation: PageNavigation) {
      self.webView = webView
      self.navigation = navigation
    }
  }

  private final class Bridge: NSObject, WKScriptMessageHandler {
    let session: UUID
    weak var runtime: WebKitRuntime?

    init(session: UUID, runtime: WebKitRuntime) {
      self.session = session
      self.runtime = runtime
    }

    func userContentController(
      _ controller: WKUserContentController, didReceive message: WKScriptMessage
    ) {
      guard message.name == "plugin", let body = message.body as? String else { return }
      let session = session
      Task { @MainActor [weak self] in
        await self?.runtime?.reply(body, session: session)
      }
    }
  }

  private var pages: [UUID: Page] = [:]
  private weak var bridge: (any PluginBridge)?

  public init() {}

  func webView(for session: UUID) -> WKWebView? {
    pages[session]?.webView
  }

  public func activate(session: UUID, root: URL, entrypoint: URL, bridge: any PluginBridge) async throws {
    self.bridge = bridge
    let content = WKUserContentController()
    content.add(Bridge(session: session, runtime: self), name: "plugin")
    content.addUserScript(
      WKUserScript(
        source: Self.bridgeScript(session: session), injectionTime: .atDocumentStart,
        forMainFrameOnly: true))
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = .nonPersistent()
    configuration.userContentController = content
    configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
    let navigation = PageNavigation(root: root)
    let webView = WKWebView(frame: .zero, configuration: configuration)
    webView.navigationDelegate = navigation
    webView.uiDelegate = navigation
    webView.allowsBackForwardNavigationGestures = false
    webView.isInspectable = false
    let page = Page(webView: webView, navigation: navigation)
    pages[session] = page
    do {
      try await navigation.load(webView, entrypoint: entrypoint, root: root)
    } catch {
      pages[session] = nil
      throw error
    }
  }

  public func unload(session: UUID) {
    guard let page = pages.removeValue(forKey: session) else { return }
    page.webView.stopLoading()
    page.webView.navigationDelegate = nil
    page.webView.uiDelegate = nil
  }

  fileprivate func reply(_ body: String, session: UUID) async {
    guard let bridge, let page = pages[session] else { return }
    let reply = await bridge.deliver(body, from: session)
    let encoded = Data(reply.utf8).base64EncodedString()
    _ = try? await page.webView.evaluateJavaScript(
      "window.tether && window.tether._reply(JSON.parse(atob('\(encoded)')))")
  }

  static func bridgeScript(session: UUID) -> String {
    """
    (function () {
      var session = "\(session.uuidString)";
      var api = \(PluginManifest.api);
      var pending = {};
      var seq = 0;
      window.tether = {
        _reply: function (message) {
          var item = pending[message.id];
          if (!item) return;
          delete pending[message.id];
          if (message.ok) item.resolve(message.payload);
          else item.reject(new Error(message.error || "rejected"));
        },
        call: function (method, payload) {
          var id = String(++seq);
          var body = JSON.stringify({
            api: api, session: session, id: id, method: method,
            payload: payload == null ? null : payload
          });
          return new Promise(function (resolve, reject) {
            pending[id] = { resolve: resolve, reject: reject };
            window.webkit.messageHandlers.plugin.postMessage(body);
          });
        }
      };
    })();
    """
  }
}

@MainActor
final class PageNavigation: NSObject, WKNavigationDelegate, WKUIDelegate {
  let root: URL
  private var continuation: CheckedContinuation<Void, Error>?
  private var finished = false

  init(root: URL) {
    self.root = root
  }

  func load(_ webView: WKWebView, entrypoint: URL, root: URL) async throws {
    try await withCheckedThrowingContinuation { continuation in
      self.continuation = continuation
      webView.loadFileURL(entrypoint, allowingReadAccessTo: root)
    }
  }

  private func finish(_ result: Result<Void, Error>) {
    guard !finished else { return }
    finished = true
    continuation?.resume(with: result)
    continuation = nil
  }

  func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    finish(.success(()))
  }

  func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
    finish(.failure(error))
  }

  func webView(
    _ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error
  ) {
    finish(.failure(error))
  }

  func webView(
    _ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
    decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
  ) {
    if let url = navigationAction.request.url, WebOrigin.allows(url, root: root) {
      decisionHandler(.allow)
    } else {
      decisionHandler(.cancel)
    }
  }

  func webView(
    _ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
    initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor () -> Void
  ) {
    completionHandler()
  }

  func webView(
    _ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
    initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor (Bool) -> Void
  ) {
    completionHandler(false)
  }

  func webView(
    _ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?,
    initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor (String?) -> Void
  ) {
    completionHandler(nil)
  }
}
