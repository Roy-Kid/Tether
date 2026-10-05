import SwiftUI
import WebKit

#if os(macOS)
  struct HostedWebView: NSViewRepresentable {
    let webView: WKWebView
    func makeNSView(context: Context) -> WKWebView { webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
  }
#else
  struct HostedWebView: UIViewRepresentable {
    let webView: WKWebView
    func makeUIView(context: Context) -> WKWebView { webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
  }
#endif

/// The view a later tab embeds. The page draws inside it. The host keeps the chrome.
public struct PluginSurface: View {
  let runtime: WebKitRuntime
  let session: UUID

  public init(runtime: WebKitRuntime, session: UUID) {
    self.runtime = runtime
    self.session = session
  }

  public var body: some View {
    if let webView = runtime.webView(for: session) {
      HostedWebView(webView: webView)
    } else {
      Color.clear
    }
  }
}
