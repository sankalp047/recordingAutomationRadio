import Foundation
import SwiftUI
import WebKit
import Observation

/// Sign-in through Cloudflare Access.
///
/// Access sits in front of the Worker and decides who may reach it, so the
/// rule "only @funasia.net" lives in a Cloudflare policy rather than in this
/// app or in the API. Signing in happens in a real web view because that is
/// where the identity provider's own login runs; on success Access sets a
/// `CF_Authorization` cookie, which is copied into the shared cookie store so
/// ordinary URLSession calls carry it.
///
/// The app also works before Access is switched on: requests still send the
/// bearer token, and the login sheet only appears if a response comes back as
/// an Access challenge.
@MainActor
@Observable
final class Auth {
    var identity: Identity?
    var signedIn = false
    var checking = false

    struct Identity: Codable, Equatable {
        let email: String?
        let name: String?
        var display: String { email ?? name ?? "signed in" }
    }

    private var baseURL: String

    init(baseURL: String) { self.baseURL = baseURL }

    func update(baseURL: String) { self.baseURL = baseURL }

    /// Cloudflare exposes the signed-in user here once a session exists.
    func refreshIdentity() async {
        guard let url = URL(string: baseURL + "/cdn-cgi/access/get-identity") else { return }
        checking = true
        defer { checking = false }
        var req = URLRequest(url: url)
        req.httpShouldHandleCookies = true
        req.cachePolicy = .reloadIgnoringLocalCacheData
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let id = try? JSONDecoder().decode(Identity.self, from: data)
        else {
            identity = nil
            signedIn = false
            return
        }
        identity = id
        signedIn = true
    }

    /// Move cookies the login web view obtained into URLSession's store.
    func adoptCookies(from store: WKHTTPCookieStore) async {
        let cookies = await store.allCookies()
        for c in cookies where c.name.hasPrefix("CF_") {
            HTTPCookieStorage.shared.setCookie(c)
        }
        await refreshIdentity()
    }

    func signOut() async {
        if let host = URL(string: baseURL)?.host {
            for c in HTTPCookieStorage.shared.cookies ?? [] where c.domain.contains(host) {
                HTTPCookieStorage.shared.deleteCookie(c)
            }
        }
        let store = WKWebsiteDataStore.default()
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        let records = await store.dataRecords(ofTypes: types)
        await store.removeData(ofTypes: types, for: records)
        identity = nil
        signedIn = false
    }
}

/// A web view that runs the Cloudflare Access login and reports when the
/// protected origin finally answers normally.
struct AccessLoginWebView: NSViewRepresentable {
    let url: URL
    var onFinished: (WKHTTPCookieStore) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onFinished: onFinished) }

    func makeNSView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = .default()
        let v = WKWebView(frame: .zero, configuration: cfg)
        v.navigationDelegate = context.coordinator
        v.load(URLRequest(url: url))
        return v
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate {
        let onFinished: (WKHTTPCookieStore) -> Void
        private var done = false
        init(onFinished: @escaping (WKHTTPCookieStore) -> Void) { self.onFinished = onFinished }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            // Access redirects through its own domains during login; the flow is
            // complete once the app's own origin loads without being bounced.
            guard !done, let host = webView.url?.host,
                  !host.contains("cloudflareaccess.com"),
                  !host.contains("accounts.google.com"),
                  !host.contains("login.microsoftonline.com")
            else { return }
            done = true
            onFinished(webView.configuration.websiteDataStore.httpCookieStore)
        }
    }
}
