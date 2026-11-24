import SwiftUI
import WebKit
import AVFoundation
import UserNotifications

// MARK: - Models

enum SiteKind: String {
    case instagram, tiktok, youtube, reddit, x, facebook

    var displayName: String {
        switch self {
        case .instagram: return "Instagram"
        case .tiktok: return "TikTok"
        case .youtube: return "YouTube"
        case .reddit: return "Reddit"
        case .x: return "X"
        case .facebook: return "Facebook"
        }
    }

    var desktop: Bool { self == .tiktok || self == .facebook }
}

struct Pane: Identifiable, Hashable {
    let id: String
    let title: String
    let group: String
    let site: SiteKind
    let url: String
    let isFeed: Bool   // counts toward the daily limit and gets locked
    let eager: Bool    // created at launch (needed for notifications)
}

let allPanes: [Pane] = [
    Pane(id: "ig-dm", title: "Messages", group: "instagram", site: .instagram,
         url: "https://www.instagram.com/direct/inbox/", isFeed: false, eager: true),
    Pane(id: "ig-stories", title: "Stories", group: "instagram", site: .instagram,
         url: "https://www.instagram.com/", isFeed: true, eager: true),
    Pane(id: "tt-dm", title: "Messages", group: "tiktok", site: .tiktok,
         url: "https://www.tiktok.com/messages", isFeed: false, eager: true),
    Pane(id: "tt-following", title: "Following", group: "tiktok", site: .tiktok,
         url: "https://www.tiktok.com/following", isFeed: true, eager: false),
    Pane(id: "yt", title: "YouTube", group: "more", site: .youtube,
         url: "https://m.youtube.com/feed/subscriptions", isFeed: true, eager: false),
    Pane(id: "reddit", title: "Reddit", group: "more", site: .reddit,
         url: "https://www.reddit.com/", isFeed: true, eager: false),
    Pane(id: "x", title: "X", group: "more", site: .x,
         url: "https://x.com/messages", isFeed: false, eager: false),
    Pane(id: "fb", title: "Facebook", group: "more", site: .facebook,
         url: "https://www.facebook.com/messages/", isFeed: false, eager: false),
]

// MARK: - Accounts (each account gets its own isolated login storage)

struct Account: Codable, Identifiable, Hashable {
    var id: UUID
    var name: String
}

final class Accounts: ObservableObject {
    static let mainID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!

    @Published var list: [Account]
    @Published var activeID: UUID {
        didSet { UserDefaults.standard.set(activeID.uuidString, forKey: "activeAccount") }
    }

    init() {
        var loaded: [Account] = []
        if let data = UserDefaults.standard.data(forKey: "accounts"),
           let dec = try? JSONDecoder().decode([Account].self, from: data) {
            loaded = dec
        }
        if loaded.isEmpty { loaded = [Account(id: Accounts.mainID, name: "Account 1")] }
        list = loaded
        var chosen = loaded[0].id
        if let s = UserDefaults.standard.string(forKey: "activeAccount"),
           let u = UUID(uuidString: s),
           loaded.contains(where: { $0.id == u }) {
            chosen = u
        }
        activeID = chosen
    }

    var active: Account { list.first(where: { $0.id == activeID }) ?? list[0] }

    private func persist() {
        if let data = try? JSONEncoder().encode(list) {
            UserDefaults.standard.set(data, forKey: "accounts")
        }
    }

    func add(_ name: String) {
        let n = name.trimmingCharacters(in: .whitespaces)
        let acc = Account(id: UUID(), name: n.isEmpty ? "Account \(list.count + 1)" : n)
        list.append(acc)
        persist()
    }

    func remove(_ id: UUID) {
        guard list.count > 1 else { return }
        if activeID == id, let other = list.first(where: { $0.id != id }) { activeID = other.id }
        list.removeAll(where: { $0.id == id })
        persist()
        Task { @MainActor in
            try? await WKWebsiteDataStore.remove(forIdentifier: id)
        }
    }
}

// MARK: - Usage, limits, sleep and focus mode

final class Usage: ObservableObject {
    @Published var secondsToday: Int
    @Published var clock = Date()
    private var lastMinute = -1

    @Published var limitMinutes: Int {
        didSet { UserDefaults.standard.set(limitMinutes, forKey: "limitMinutes") }
    }
    @Published var focusOn: Bool {
        didSet { UserDefaults.standard.set(focusOn, forKey: "focusOn") }
    }
    @Published var sleepOn: Bool {
        didSet { UserDefaults.standard.set(sleepOn, forKey: "sleepOn") }
    }
    @Published var sleepStart: Int {
        didSet { UserDefaults.standard.set(sleepStart, forKey: "sleepStart") }
    }
    @Published var sleepEnd: Int {
        didSet { UserDefaults.standard.set(sleepEnd, forKey: "sleepEnd") }
    }
    @Published var keepAlive: Bool {
        didSet {
            UserDefaults.standard.set(keepAlive, forKey: "keepAlive")
            KeepAlive.shared.set(keepAlive)
        }
    }

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
        focusOn = d.bool(forKey: "focusOn")
        sleepOn = d.object(forKey: "sleepOn") as? Bool ?? true
        sleepStart = d.object(forKey: "sleepStart") as? Int ?? 22
        sleepEnd = d.object(forKey: "sleepEnd") as? Int ?? 7
        keepAlive = d.object(forKey: "keepAlive") as? Bool ?? true
    }

    var inSleep: Bool {
        guard sleepOn else { return false }
        let h = Calendar.current.component(.hour, from: Date())
        if sleepStart > sleepEnd { return h >= sleepStart || h < sleepEnd }
        return h >= sleepStart && h < sleepEnd
    }

    var feedLocked: Bool { focusOn || inSleep || secondsToday >= limitMinutes * 60 }

    var lockReason: String {
        if focusOn { return "Focus mode is on." }
        if inSleep { return "Sleep mode until \(sleepEnd):00." }
        return "\(limitMinutes) min used today."
    }

    func tick() {
        let d = UserDefaults.standard
        let today = Usage.todayString()
        if d.string(forKey: "usageDay") != today {
            secondsToday = 0
            d.set(today, forKey: "usageDay")
        }
        secondsToday += 1
        d.set(secondsToday, forKey: "usageSeconds")
    }

    func refreshClock() {
        let m = Calendar.current.component(.minute, from: Date())
        if m != lastMinute {
            lastMinute = m
            clock = Date()
        }
    }

    static func todayString() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date())
    }
}

// MARK: - Local notifications + background keep-alive

final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()
    private var last: [String: Int] = [:]

    func setup() {
        let c = UNUserNotificationCenter.current()
        c.delegate = self
        c.requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    func handle(count: Int, key: String, title: String) {
        guard let prev = last[key] else {
            last[key] = count   // first report is the baseline, no alert
            updateBadge()
            return
        }
        last[key] = count
        if count > prev {
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = count == 1 ? "New message" : "\(count) unread messages"
            content.sound = .default
            let req = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
            UNUserNotificationCenter.current().add(req)
        }
        updateBadge()
    }

    private func updateBadge() {
        let total = last.values.reduce(0, +)
        UNUserNotificationCenter.current().setBadgeCount(total)
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}

final class KeepAlive {
    static let shared = KeepAlive()
    private var player: AVAudioPlayer?

    func set(_ on: Bool) {
        let session = AVAudioSession.sharedInstance()
        if on {
            try? session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try? session.setActive(true)
            if player == nil {
                player = try? AVAudioPlayer(data: KeepAlive.silence())
                player?.numberOfLoops = -1
                player?.prepareToPlay()
            }
            player?.play()
        } else {
            player?.stop()
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
        }
    }

    // One second of silence as a WAV file, built in memory.
    static func silence() -> Data {
        let rate: UInt32 = 8000
        let bytes = 8000 * 2
        var d = Data()
        func u32(_ v: UInt32) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 4)) }
        func u16(_ v: UInt16) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 2)) }
        d.append("RIFF".data(using: .ascii)!)
        u32(UInt32(36 + bytes))
        d.append("WAVE".data(using: .ascii)!)
        d.append("fmt ".data(using: .ascii)!)
        u32(16); u16(1); u16(1); u32(rate); u32(rate * 2); u16(2); u16(16)
        d.append("data".data(using: .ascii)!)
        u32(UInt32(bytes))
        d.append(Data(count: bytes))
        return d
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
    @StateObject private var accounts = Accounts()
    @State private var selection = "instagram"
    @State private var paneSel: [String: String] = [:]
    @Environment(\.scenePhase) private var phase
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private let items: [(id: String, title: String, icon: String)] = [
        ("instagram", "Instagram", "camera.fill"),
        ("tiktok", "TikTok", "music.note"),
        ("more", "More", "square.grid.2x2.fill"),
        ("settings", "Settings", "gearshape.fill"),
    ]

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                ForEach(["instagram", "tiktok", "more"], id: \.self) { g in
                    GroupView(group: g,
                              active: selection == g,
                              usage: usage,
                              accounts: accounts,
                              paneSel: $paneSel)
                        .opacity(selection == g ? 1 : 0)
                        .allowsHitTesting(selection == g)
                }
                SettingsView(usage: usage, accounts: accounts)
                    .opacity(selection == "settings" ? 1 : 0)
                    .allowsHitTesting(selection == "settings")
            }
            HStack {
                ForEach(items, id: \.id) { item in
                    Button {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        selection = item.id
                    } label: {
                        VStack(spacing: 2) {
                            Image(systemName: item.icon).font(.system(size: 20))
                            Text(item.title).font(.system(size: 10))
                        }
                        .frame(maxWidth: .infinity)
                        .foregroundColor(selection == item.id ? .blue : .gray)
                    }
                }
            }
            .padding(.top, 8)
            .padding(.bottom, 4)
            .background(Color(white: 0.08))
        }
        .background(Color.black.ignoresSafeArea())
        .onAppear {
            Notifier.shared.setup()
            KeepAlive.shared.set(usage.keepAlive)
        }
        .onOpenURL { url in
            if let host = url.host, ["instagram", "tiktok", "more"].contains(host) { selection = host }
        }
        .onChange(of: phase) { _ in
            if phase == .active && usage.keepAlive { KeepAlive.shared.set(true) }
        }
        .onReceive(timer) { _ in
            usage.refreshClock()
            guard phase == .active, selection != "settings" else { return }
            let panes = allPanes.filter { $0.group == selection }
            let sel = paneSel[selection] ?? panes.first?.id
            if let p = panes.first(where: { $0.id == sel }), p.isFeed, !usage.feedLocked {
                usage.tick()
            }
        }
    }
}

struct GroupView: View {
    let group: String
    let active: Bool
    @ObservedObject var usage: Usage
    @ObservedObject var accounts: Accounts
    @Binding var paneSel: [String: String]
    @State private var visited: Set<String> = []

    private var panes: [Pane] { allPanes.filter { $0.group == group } }
    private var selectedID: String { paneSel[group] ?? panes[0].id }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                if panes.count > 1 {
                    Picker("", selection: Binding(get: { selectedID },
                                                  set: { paneSel[group] = $0 })) {
                        ForEach(panes) { p in Text(p.title).tag(p.id) }
                    }
                    .pickerStyle(.segmented)
                } else {
                    Spacer()
                }
                Menu {
                    ForEach(accounts.list) { a in
                        Button(a.name) { accounts.activeID = a.id }
                    }
                } label: {
                    Label(accounts.active.name, systemImage: "person.crop.circle")
                        .font(.footnote)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)

            ZStack {
                ForEach(panes) { pane in
                    if pane.eager || visited.contains(pane.id) || (active && pane.id == selectedID) {
                        ZStack {
                            WebView(pane: pane, accountID: accounts.activeID, accountName: accounts.active.name)
                                .id("\(pane.id)-\(accounts.activeID.uuidString)")
                            if pane.isFeed && usage.feedLocked {
                                LockView(usage: usage)
                            }
                        }
                        .opacity(pane.id == selectedID ? 1 : 0)
                        .allowsHitTesting(pane.id == selectedID)
                    }
                }
            }
        }
        .onAppear { markVisited() }
        .onChange(of: active) { _ in markVisited() }
        .onChange(of: selectedID) { _ in markVisited() }
    }

    private func markVisited() {
        if active { visited.insert(selectedID) }
    }
}

struct LockView: View {
    @ObservedObject var usage: Usage
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 12) {
                Image(systemName: "hand.raised.fill").font(.system(size: 44))
                Text("Feed locked").font(.title3.bold())
                Text("\(usage.lockReason) Messages still work.")
                    .foregroundColor(.gray)
                    .multilineTextAlignment(.center)
            }
            .padding()
        }
    }
}

// MARK: - Settings

struct SettingsView: View {
    @ObservedObject var usage: Usage
    @ObservedObject var accounts: Accounts
    @State private var newName = ""
    @State private var msg = ""

    var body: some View {
        NavigationView {
            Form {
                Section("Accounts (separate logins)") {
                    ForEach(accounts.list) { a in
                        Button {
                            accounts.activeID = a.id
                        } label: {
                            HStack {
                                Text(a.name)
                                Spacer()
                                if a.id == accounts.activeID { Image(systemName: "checkmark") }
                            }
                        }
                    }
                    .onDelete { idx in
                        let ids = idx.map { accounts.list[$0].id }
                        for id in ids { accounts.remove(id) }
                    }
                    HStack {
                        TextField("New account name", text: $newName)
                        Button("Add") {
                            accounts.add(newName)
                            newName = ""
                        }
                    }
                    Text("Each account has its own Instagram, TikTok and other logins. Swipe to delete.")
                        .font(.footnote)
                }

                Section("Feed limits") {
                    Stepper("Daily feed limit: \(usage.limitMinutes) min",
                            value: $usage.limitMinutes, in: 5...120, step: 5)
                    Text("Used today: \(usage.secondsToday / 60) min")
                    Toggle("Focus mode (lock all feeds now)", isOn: $usage.focusOn)
                    Toggle("Sleep mode", isOn: $usage.sleepOn)
                    if usage.sleepOn {
                        Stepper("From \(usage.sleepStart):00", value: $usage.sleepStart, in: 0...23)
                        Stepper("Until \(usage.sleepEnd):00", value: $usage.sleepEnd, in: 0...23)
                    }
                }

                Section("Message alerts") {
                    Toggle("Background alerts", isOn: $usage.keepAlive)
                    Text("Experimental. Plays silence so iOS keeps the app alive and sends a local notification when your unread count goes up. Costs battery and iOS can still stop it. Keep the app in the app switcher, don't swipe it away.")
                        .font(.footnote)
                    Text("Most reliable option: in Safari, open instagram.com, Share, Add to Home Screen, open that icon and allow notifications. Same for tiktok.com.")
                        .font(.footnote)
                }

                Section("Redirect the real Instagram app here") {
                    Text("Shortcuts app, Automation tab, plus, App, pick Instagram, Is Opened, Run Immediately. Add action Open App and pick Unscroll. Repeat for TikTok and any other app. Optional: also set a 0 min App Limit on the real app in iOS Screen Time.")
                        .font(.footnote)
                }

                Section("Account data") {
                    Button("Sign out current account everywhere") {
                        WKWebsiteDataStore(forIdentifier: accounts.activeID)
                            .removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(),
                                        modifiedSince: .distantPast) {
                                msg = "Signed out. Restart the app."
                            }
                    }
                    .foregroundColor(.red)
                    if !msg.isEmpty { Text(msg).font(.footnote) }
                }
            }
            .navigationTitle("Settings")
        }
        .navigationViewStyle(.stack)
    }
}

// MARK: - Site rules

struct Rule {
    let hostSuffix: String
    let blockedPrefixes: [String]
    let blockedExact: [String]
    let css: String
    let homeHide: String
    let banner: String
}

enum Scripts {
    static let mobileUA = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Mobile/15E148 Safari/604.1"
    static let desktopUA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Safari/605.1.15"

    static func rule(_ site: SiteKind) -> Rule {
        switch site {
        case .instagram:
            return Rule(hostSuffix: "instagram.com",
                        blockedPrefixes: ["/reels", "/explore"],
                        blockedExact: [],
                        css: "a[href^=\"/reels\"],a[href^=\"/explore\"]{display:none!important}",
                        homeHide: "article",
                        banner: "Feed hidden. Stories only.")
        case .tiktok:
            return Rule(hostSuffix: "tiktok.com",
                        blockedPrefixes: ["/foryou", "/explore", "/live"],
                        blockedExact: ["/"],
                        css: "a[href=\"/foryou\"],a[href^=\"/explore\"],a[href^=\"/live\"]{display:none!important}",
                        homeHide: "", banner: "")
        case .youtube:
            return Rule(hostSuffix: "youtube.com",
                        blockedPrefixes: ["/shorts", "/feed/explore", "/feed/trending"],
                        blockedExact: ["/"],
                        css: "ytm-reel-shelf-renderer,ytm-shorts-lockup-view-model,ytm-shorts-lockup-view-model-v2,a[href^=\"/shorts\"]{display:none!important}",
                        homeHide: "", banner: "")
        case .reddit:
            return Rule(hostSuffix: "reddit.com",
                        blockedPrefixes: ["/r/popular", "/r/all", "/explore"],
                        blockedExact: [],
                        css: "a[href^=\"/r/popular\"],a[href^=\"/r/all\"],a[href^=\"/explore\"]{display:none!important}",
                        homeHide: "", banner: "")
        case .x:
            return Rule(hostSuffix: "x.com",
                        blockedPrefixes: ["/explore", "/home", "/i/trends"],
                        blockedExact: ["/"],
                        css: "a[href^=\"/explore\"],a[href^=\"/home\"]{display:none!important}",
                        homeHide: "", banner: "")
        case .facebook:
            return Rule(hostSuffix: "facebook.com",
                        blockedPrefixes: ["/reel", "/watch", "/marketplace", "/gaming"],
                        blockedExact: ["/"],
                        css: "a[href^=\"/reel\"],a[href^=\"/watch\"],a[href^=\"/marketplace\"]{display:none!important}",
                        homeHide: "", banner: "")
        }
    }

    static func isBlocked(_ url: URL, site: SiteKind) -> Bool {
        let r = rule(site)
        guard (url.host ?? "").hasSuffix(r.hostSuffix) else { return false }
        let p = url.path.isEmpty ? "/" : url.path
        if r.blockedExact.contains(p) { return true }
        return r.blockedPrefixes.contains(where: { p.hasPrefix($0) })
    }

    private static func json<T: Encodable>(_ v: T) -> String {
        guard let d = try? JSONEncoder().encode(v), let s = String(data: d, encoding: .utf8) else { return "\"\"" }
        return s
    }

    static func source(for pane: Pane) -> String {
        let r = rule(pane.site)
        let fb = json(URL(string: pane.url)?.path ?? "/")
        let prefixes = json(r.blockedPrefixes)
        let exact = json(r.blockedExact)
        let css = json(r.css)
        let home = json(r.homeHide)
        let banner = json(r.banner)
        return #"""
        (function () {
          var FB = \#(fb), PREFIX = \#(prefixes), EXACT = \#(exact);
          var CSS = \#(css), HOME = \#(home), BANNER = \#(banner);
          function blocked(p) {
            if (EXACT.indexOf(p) !== -1) return true;
            for (var i = 0; i < PREFIX.length; i++) { if (p.indexOf(PREFIX[i]) === 0) return true; }
            return false;
          }
          function guard() {
            if (!document.documentElement) return;
            var p = location.pathname || '/';
            if (blocked(p) && p !== FB) { location.replace(FB); return; }
            document.documentElement.setAttribute('data-un', p === '/' ? 'home' : 'other');
            if (!document.getElementById('un-style')) {
              var s = document.createElement('style'); s.id = 'un-style';
              s.textContent = CSS + (HOME ? 'html[data-un="home"] ' + HOME + '{display:none!important}' : '') +
                '#un-banner{padding:28px 16px;text-align:center;color:#8e8e8e;font:14px -apple-system,sans-serif}';
              (document.head || document.documentElement).appendChild(s);
            }
            if (BANNER && p === '/' && document.body && !document.getElementById('un-banner')) {
              var b = document.createElement('div'); b.id = 'un-banner'; b.textContent = BANNER;
              (document.querySelector('main') || document.body).appendChild(b);
            }
          }
          function unread() {
            var c = 0;
            var m = (document.title || '').match(/^\((\d+)\)/);
            if (m) c = parseInt(m[1], 10);
            var a = document.querySelector('a[href*="/direct/inbox"]');
            if (a) { var n = (a.innerText || '').match(/\d+/); if (n) c = Math.max(c, parseInt(n[0], 10)); }
            return c;
          }
          var last = -1;
          function report() {
            var c = unread();
            if (c !== last) {
              last = c;
              try { window.webkit.messageHandlers.unread.postMessage(c); } catch (e) {}
            }
          }
          guard(); report();
          setInterval(guard, 400);
          setInterval(report, 3000);
        })();
        """#
    }
}

// MARK: - Web view

final class UnreadHandler: NSObject, WKScriptMessageHandler {
    let key: String
    let title: String
    init(key: String, title: String) {
        self.key = key
        self.title = title
    }
    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        var n: Int?
        if let i = message.body as? Int { n = i }
        else if let d = message.body as? Double { n = Int(d) }
        if let n = n { Notifier.shared.handle(count: n, key: key, title: title) }
    }
}

struct WebView: UIViewRepresentable {
    let pane: Pane
    let accountID: UUID
    let accountName: String

    func makeCoordinator() -> Coordinator { Coordinator(pane) }

    func makeUIView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        cfg.allowsInlineMediaPlayback = true
        cfg.mediaTypesRequiringUserActionForPlayback = []
        cfg.websiteDataStore = WKWebsiteDataStore(forIdentifier: accountID)
        cfg.userContentController.addUserScript(
            WKUserScript(source: Scripts.source(for: pane),
                         injectionTime: .atDocumentStart,
                         forMainFrameOnly: true))
        if !pane.isFeed {
            let handler = UnreadHandler(key: "\(accountID.uuidString)-\(pane.id)",
                                        title: "\(pane.site.displayName) (\(accountName))")
            cfg.userContentController.add(handler, name: "unread")
        }
        if pane.site.desktop {
            cfg.defaultWebpagePreferences.preferredContentMode = .desktop
        }
        let wv = WKWebView(frame: .zero, configuration: cfg)
        wv.customUserAgent = pane.site.desktop ? Scripts.desktopUA : Scripts.mobileUA
        wv.navigationDelegate = context.coordinator
        wv.uiDelegate = context.coordinator
        wv.allowsBackForwardNavigationGestures = true
        wv.isOpaque = false
        wv.backgroundColor = .black
        wv.scrollView.backgroundColor = .black
        if let u = URL(string: pane.url) { wv.load(URLRequest(url: u)) }
        return wv
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        let pane: Pane
        init(_ pane: Pane) { self.pane = pane }

        func webView(_ webView: WKWebView,
                     decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if let url = navigationAction.request.url,
               navigationAction.targetFrame?.isMainFrame ?? true,
               Scripts.isBlocked(url, site: pane.site) {
                decisionHandler(.cancel)
                if let u = URL(string: pane.url) { webView.load(URLRequest(url: u)) }
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
