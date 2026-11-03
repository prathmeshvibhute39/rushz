import CryptoKit
import SwiftUI
import WebKit
import YouTubeKit

/// Google sign-in through Google's own web page, so the app never sees the password. The session cookies
/// stay in WebKit's sandboxed store; requests to youtube.com carry them plus the SAPISIDHASH signature
/// the web client uses. Nothing is ever sent to any other host.
@MainActor
final class Account: ObservableObject {
    static let shared = Account()
    @Published private(set) var isSignedIn = false
    /// Set when playback hit the sign-in gate: the app opens Settings so you can (re)sign in.
    @Published var needsAttention = false
    private var cookies: [HTTPCookie] = []
    private var store: WKHTTPCookieStore { WKWebsiteDataStore.default().httpCookieStore }

    /// Plug the session into the extractor.
    func install() {
        YouTubeAuth.headerProvider = { url in await MainActor.run { Account.shared.headers(for: url) } }
    }

    func refresh() async {
        cookies = await store.allCookies().filter { $0.domain.hasSuffix("youtube.com") || $0.domain.hasSuffix("google.com") }
        isSignedIn = cookies.contains { $0.name == "SAPISID" || $0.name == "__Secure-3PAPISID" }
    }

    func signOut() async {
        await WKWebsiteDataStore.default().removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
        cookies = []
        isSignedIn = false
        Feed.shared.clear()  // private data goes with the session
    }

    /// Cookie + auth headers for a youtube.com HTTPS request; empty when signed out or for any other host.
    func headers(for url: URL) -> [String: String] {
        guard isSignedIn, url.scheme == "https", let host = url.host, host == "youtube.com" || host.hasSuffix(".youtube.com"),
              let sid = (cookies.first { $0.name == "SAPISID" } ?? cookies.first { $0.name == "__Secure-3PAPISID" })?.value else { return [:] }
        let origin = host == "music.youtube.com" ? "https://music.youtube.com" : "https://www.youtube.com"
        let ts = Int(Date().timeIntervalSince1970)
        let hash = Insecure.SHA1.hash(data: Data("\(ts) \(sid) \(origin)".utf8)).map { String(format: "%02x", $0) }.joined()
        let usable = cookies.filter { host.hasSuffix($0.domain.drop { $0 == "." }) }
        var h = HTTPCookie.requestHeaderFields(with: usable)
        h["Authorization"] = "SAPISIDHASH \(ts)_\(hash)"
        h["X-Origin"] = origin
        h["X-Goog-AuthUser"] = "0"
        return h
    }
}

struct LoginView: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            GoogleWebView {
                await Account.shared.refresh()
                dismiss()
            }
            .ignoresSafeArea(edges: .bottom)
            .navigationTitle("Sign in")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
        .onDisappear { Task { await Account.shared.refresh() } }  // however it was closed, pick up the session
    }
}

private struct GoogleWebView: UIViewRepresentable {
    let onSignedIn: () async -> Void
    private static let start = URL(string: "https://accounts.google.com/ServiceLogin?service=youtube&continue=https%3A%2F%2Fwww.youtube.com%2F")!

    func makeCoordinator() -> Coordinator { Coordinator(onSignedIn) }

    func makeUIView(context: Context) -> WKWebView {
        let web = WKWebView(frame: .zero)
        // ponytail: Google refuses sign-in in web views that don't look like Safari
        web.customUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"
        web.navigationDelegate = context.coordinator
        web.load(URLRequest(url: Self.start))
        return web
    }

    func updateUIView(_ web: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate {
        let onSignedIn: () async -> Void
        init(_ f: @escaping () async -> Void) { onSignedIn = f }

        /// Keep the sign-in view on Google/YouTube pages only.
        func webView(_ w: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
            guard action.targetFrame?.isMainFrame ?? true else { return .allow }
            let host = action.request.url?.host ?? ""
            let ok = action.request.url?.scheme == "https" && (host.hasSuffix("google.com") || host.hasSuffix("youtube.com"))
            return ok ? .allow : .cancel
        }

        /// Whatever page Google lands on (some are blank), finish as soon as the session cookie exists.
        func webView(_ w: WKWebView, didFinish _: WKNavigation!) {
            Task { @MainActor in
                await Account.shared.refresh()
                if Account.shared.isSignedIn { await onSignedIn() }
            }
        }
    }
}
