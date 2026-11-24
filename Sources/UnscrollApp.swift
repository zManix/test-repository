import SwiftUI
import WebKit

// MARK: - Tabs

enum Site { case instagram, tiktok }

struct AppTab: Identifiable, Hashable {
    let id: String
    let title: String
    let icon: String
    let site: Site
    let url: String
    let isFeed: Bool   // counts against the daily limit
}

let appTabs: [AppTab] = [
    AppTab(id: "igdm", title: "Messages", icon: "paperplane.fill", site: .instagram,
           url: "https://www.instagram.com/direct/inbox/", isFeed: false),
    AppTab(id: "igstories", title: "Stories", icon: "circle.dashed", site: .instagram,
           url: "https://www.instagram.com/", isFeed: true),
    AppTab(id: "ttdm", title: "TikTok DMs", icon: "message.fill", site: .tiktok,
           url: "https://www.tiktok.com/messages", isFeed: false),
]

// MARK: - Daily usage limit (Stories tab only)

final class Usage: ObservableObject {
    @Published var secondsToday: Int
    @Published var limitMinutes: Int {
        didSet { UserDefaults.standard.set(limitMinutes, forKey: "limitMinutes") }
    }
    private let dayKey = "usageDay"
    private let secKey = "usageSeconds"

    init() {
        let d = UserDefaults.standard
        let today = Usage.todayString()
        if d.string(forKey: "usageDay") == today {
            secondsToday = d.integer(forKey: "usageSeconds")
        } else {
            secondsToday = 0
            d.set(today, forKey: "usageDay")
            d.set(0, forKey: "usageSeconds")
        }
        let saved = d.integer(forKey: "limitMinutes")
        limitMinutes = saved == 0 ? 15 : saved
    }

    var overLimit: Bool { secondsToday >= limitMinutes * 60 }

    func tick() {
        let d = UserDefaults.standard
        let today = Usage.todayString()
        if d.string(forKey: dayKey) != today {
            secondsToday = 0
            d.set(today, forKey: dayKey)
        }
        secondsToday += 1
        d.set(secondsToday, forKey: secKey)
    }

    static func todayString() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date())
    }
}

// MARK: - App

@main
struct UnscrollApp: App {
    var body: some Scene {
        WindowGroup { RootView().preferredColorScheme(.dark) }
    }
}

struct RootView: View {
    @StateObject private var usage = Usage()
    @State private var selection = "igdm"
    @Environment(\.scenePhase) private var phase
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        TabView(selection: $selection) {
            ForEach(appTabs) { tab in
                ZStack {
                    Color.black.ignoresSafeArea()
                    WebView(tab: tab)
                    if tab.isFeed && usage.overLimit {
                        LockView(usage: usage)
                    }
                }
                .tabItem { Label(tab.title, systemImage: tab.icon) }
                .tag(tab.id)
            }
            SettingsView(usage: usage)
                .tabItem { Label("Settings", systemImage: "gearshape") }
                .tag("settings")
        }
        .onReceive(timer) { _ in
            guard phase == .active,
                  let t = appTabs.first(where: { $0.id == selection }),
                  t.isFeed else { return }
            usage.tick()
        }
    }
}

struct LockView: View {
    @ObservedObject var usage: Usage
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 12) {
                Image(systemName: "hand.raised.fill").font(.system(size: 44))
                Text("Daily Stories limit reached").font(.title3.bold())
                Text("\(usage.limitMinutes) min used today. Messages still work.")
                    .foregroundColor(.gray)
                    .multilineTextAlignment(.center)
            }
            .padding()
        }
    }
}

struct SettingsView: View {
    @ObservedObject var usage: Usage
    @State private var cleared = false

    var body: some View {
        NavigationView {
            Form {
                Section("Stories time limit") {
                    Stepper("Daily limit: \(usage.limitMinutes) min",
                            value: $usage.limitMinutes, in: 5...120, step: 5)
                    Text("Used today: \(usage.secondsToday / 60) min")
                }
                Section("Notifications") {
                    Text("This app cannot receive live push notifications. For live DM alerts, add instagram.com to your Home Screen from Safari (Share, then Add to Home Screen), open it, and allow notifications. Same idea for TikTok.")
                        .font(.footnote)
                }
                Section("Account") {
                    Button("Sign out of everything") {
                        let store = WKWebsiteDataStore.default()
                        store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(),
                                         modifiedSince: .distantPast) { cleared = true }
                    }
                    .foregroundColor(.red)
                    if cleared { Text("Cleared. Restart the app.").font(.footnote) }
                }
            }
            .navigationTitle("Settings")
        }
        .navigationViewStyle(.stack)
    }
}

// MARK: - Web view

enum Scripts {
    static let mobileUA = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Mobile/15E148 Safari/604.1"
    static let desktopUA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Safari/605.1.15"

    static func fallbackPath(_ tab: AppTab) -> String {
        URL(string: tab.url)?.path ?? "/"
    }

    static func isBlocked(_ url: URL, site: Site) -> Bool {
        let host = url.host ?? ""
        let p = url.path
        switch site {
        case .instagram:
            guard host.hasSuffix("instagram.com") else { return false }
            return p.hasPrefix("/reels") || p.hasPrefix("/explore")
        case .tiktok:
            guard host.hasSuffix("tiktok.com") else { return false }
            return p == "/" || p.hasPrefix("/foryou") || p.hasPrefix("/explore") || p.hasPrefix("/live")
        }
    }

    static func source(for tab: AppTab) -> String {
        let fb = fallbackPath(tab)
        switch tab.site {
        case .instagram:
            return """
            (function () {
              var FALLBACK = "\(fb)";
              var css = 'a[href^="/reels"],a[href^="/explore"]{display:none!important}' +
                        'html[data-un="home"] article{display:none!important}' +
                        '#un-banner{padding:28px 16px;text-align:center;color:#8e8e8e;font:14px -apple-system,sans-serif}';
              function guard() {
                if (!document.documentElement) return;
                var p = location.pathname;
                if (p.indexOf('/reels') === 0 || p.indexOf('/explore') === 0) { location.replace(FALLBACK); return; }
                document.documentElement.setAttribute('data-un', p === '/' ? 'home' : 'other');
                if (!document.getElementById('un-style')) {
                  var s = document.createElement('style'); s.id = 'un-style'; s.textContent = css;
                  (document.head || document.documentElement).appendChild(s);
                }
                if (p === '/' && document.body && !document.getElementById('un-banner')) {
                  var b = document.createElement('div'); b.id = 'un-banner';
                  b.textContent = 'Feed hidden. Stories only.';
                  (document.querySelector('main') || document.body).appendChild(b);
                }
              }
              guard(); setInterval(guard, 400);
            })();
            """
        case .tiktok:
            return """
            (function () {
              var FALLBACK = "\(fb)";
              function guard() {
                var p = location.pathname;
                if (p === '/' || p.indexOf('/foryou') === 0 || p.indexOf('/explore') === 0 || p.indexOf('/live') === 0) {
                  location.replace(FALLBACK);
                }
              }
              guard(); setInterval(guard, 400);
            })();
            """
        }
    }
}

struct WebView: UIViewRepresentable {
    let tab: AppTab

    func makeCoordinator() -> Coordinator { Coordinator(tab) }

    func makeUIView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        cfg.allowsInlineMediaPlayback = true
        cfg.mediaTypesRequiringUserActionForPlayback = []
        cfg.websiteDataStore = WKWebsiteDataStore.default()
        cfg.userContentController.addUserScript(
            WKUserScript(source: Scripts.source(for: tab),
                         injectionTime: .atDocumentStart,
                         forMainFrameOnly: true))
        if tab.site == .tiktok {
            cfg.defaultWebpagePreferences.preferredContentMode = .desktop
        }
        let wv = WKWebView(frame: .zero, configuration: cfg)
        wv.customUserAgent = tab.site == .instagram ? Scripts.mobileUA : Scripts.desktopUA
        wv.navigationDelegate = context.coordinator
        wv.uiDelegate = context.coordinator
        wv.allowsBackForwardNavigationGestures = true
        wv.isOpaque = false
        wv.backgroundColor = .black
        wv.scrollView.backgroundColor = .black
        if let u = URL(string: tab.url) { wv.load(URLRequest(url: u)) }
        return wv
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        let tab: AppTab
        init(_ tab: AppTab) { self.tab = tab }

        func webView(_ webView: WKWebView,
                     decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if let url = navigationAction.request.url,
               navigationAction.targetFrame?.isMainFrame ?? true,
               Scripts.isBlocked(url, site: tab.site) {
                decisionHandler(.cancel)
                if let u = URL(string: tab.url) { webView.load(URLRequest(url: u)) }
                return
            }
            decisionHandler(.allow)
        }

        func webView(_ webView: WKWebView,
                     createWebViewWith configuration: WKWebViewConfiguration,
                     for navigationAction: WKNavigationAction,
                     windowFeatures: WKWindowFeatures) -> WKWebView? {
            if navigationAction.targetFrame == nil { webView.load(navigationAction.request) }
            return nil
        }
    }
}
