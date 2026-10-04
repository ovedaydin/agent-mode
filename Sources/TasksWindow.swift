import AppKit
import WebKit

/// Shows Agent Mode Pro's live task view (served by the Pro bridge on this Mac) in a window.
final class TasksWindowController: NSObject, WKNavigationDelegate {
    static let url = URL(string: "http://localhost:8787/")!

    /// Whether Agent Mode Pro has been set up on this Mac.
    static var proInstalled: Bool {
        FileManager.default.fileExists(atPath: NSHomeDirectory() + "/.agentmode-pro/config.json")
    }

    private var window: NSWindow?
    private var webView: WKWebView?

    func show() {
        if window == nil {
            let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 1040, height: 700))
            webView.navigationDelegate = self
            let window = NSWindow(contentRect: webView.frame,
                                  styleMask: [.titled, .closable, .resizable, .miniaturizable],
                                  backing: .buffered, defer: false)
            window.title = "Agent Mode Tasks"
            window.contentView = webView
            window.minSize = NSSize(width: 640, height: 400)
            window.isReleasedWhenClosed = false
            window.setFrameAutosaveName("AgentModeTasks")
            if !window.setFrameUsingName("AgentModeTasks") { window.center() }
            window.backgroundColor = NSColor(srgbRed: 0x0E / 255, green: 0x12 / 255, blue: 0x20 / 255, alpha: 1)
            self.window = window
            self.webView = webView
        }
        webView?.load(URLRequest(url: Self.url))
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        webView.loadHTMLString("""
        <body style="background:#0E1220;color:#F4EEE4;font:15px -apple-system;display:flex;align-items:center;justify-content:center;height:90vh;text-align:center">
        <div><h2>The Agent Mode Pro bridge isn't running</h2>
        <p style="color:#9AA3C0">Start it, then reopen this window:<br><code style="color:#5CE1FF">cd ~/Documents/AI/agent-mode-pro/bridge && npm start</code></p></div>
        </body>
        """, baseURL: nil)
    }

    // Keep links that leave the bridge (if any) out of this window.
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if let url = action.request.url, url.host == "localhost" || url.scheme == "about" {
            decisionHandler(.allow)
        } else {
            if let url = action.request.url { NSWorkspace.shared.open(url) }
            decisionHandler(.cancel)
        }
    }
}
