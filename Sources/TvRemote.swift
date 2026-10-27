import UIKit
import WebKit

// Tv-afstandsbediening for iPhone: the same remote page as the Android app (app/remote.html, bundled), talking
// to Shelf's remote service on the TV. Finds the TV by itself: the last known address, the TV's usual address,
// then a scan of the phone's own /24 and of the TV's last /24. (Broadcast discovery and Wake-on-LAN need an
// Apple entitlement that free signing can't get, so this version has neither.)

let defaultTV = "172.22.86.210"
let port = 8760

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.overrideUserInterfaceStyle = .dark
        window.rootViewController = RemoteViewController()
        window.makeKeyAndVisible()
        self.window = window
        return true
    }
}

final class RemoteViewController: UIViewController, WKScriptMessageHandler, WKNavigationDelegate {
    private var web: WKWebView!
    private var html = ""
    private var searching = false
    private let light = UIImpactFeedbackGenerator(style: .light)
    private let firm = UIImpactFeedbackGenerator(style: .medium)

    private var ip: String {
        get { UserDefaults.standard.string(forKey: "ip") ?? defaultTV }
        set { UserDefaults.standard.set(newValue, forKey: "ip") }
    }

    override var preferredStatusBarStyle: UIStatusBarStyle { .lightContent }

    override func loadView() {
        let config = WKWebViewConfiguration()
        let content = WKUserContentController()
        // What the page can ask the app (window.ShelfApp); no Wake-on-LAN on iOS, so canWake() is false.
        let bridge = """
        window.ShelfApp = {
          remember: function (mac) { window.webkit.messageHandlers.shelf.postMessage({ call: 'remember', value: String(mac) }); },
          canWake: function () { return false; },
          wake: function () {},
          rescan: function () { window.webkit.messageHandlers.shelf.postMessage({ call: 'rescan' }); },
          buzz: function (ms) { window.webkit.messageHandlers.shelf.postMessage({ call: 'buzz', value: ms || 10 }); }
        };
        """
        content.addUserScript(WKUserScript(source: bridge, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        content.add(self, name: "shelf")
        config.userContentController = content
        config.allowsInlineMediaPlayback = true

        web = WKWebView(frame: .zero, configuration: config)
        web.isOpaque = false
        web.backgroundColor = .black
        web.scrollView.backgroundColor = .black
        web.scrollView.isScrollEnabled = false        // the page scrolls its own sheets
        web.scrollView.bounces = false
        web.scrollView.contentInsetAdjustmentBehavior = .never
        web.scrollView.pinchGestureRecognizer?.isEnabled = false
        web.allowsLinkPreview = false
        web.navigationDelegate = self
        view = web
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        if let url = Bundle.main.url(forResource: "remote", withExtension: "html"), let text = try? String(contentsOf: url, encoding: .utf8) {
            html = text
        } else {
            html = "<p style='color:#fff'>remote.html ontbreekt</p>"
        }
        // Show the remote at once on the last known address; check (and if needed find) the TV meanwhile.
        show(ip)
        search(reloadAlways: false)
        NotificationCenter.default.addObserver(self, selector: #selector(foreground), name: UIApplication.willEnterForegroundNotification, object: nil)
    }

    @objc private func foreground() { search(reloadAlways: false) }

    private func show(_ address: String) {
        // The page's origin is the TV itself, so its requests go straight to the TV.
        web.loadHTMLString(html, baseURL: URL(string: "http://\(address):\(port)/"))
    }

    // Links (the page has none that leave it) never open inside the remote.
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        decisionHandler(action.navigationType == .linkActivated ? .cancel : .allow)
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let call = body["call"] as? String else { return }
        switch call {
        case "buzz":
            let ms = (body["value"] as? Int) ?? 10
            (ms > 15 ? firm : light).impactOccurred()
        case "rescan":
            search(reloadAlways: true)
        case "remember":
            if let mac = body["value"] as? String { UserDefaults.standard.set(mac, forKey: "mac") }
        default:
            break
        }
    }

    // MARK: finding the TV

    private func search(reloadAlways: Bool) {
        if searching { return }
        searching = true
        let shown = ip
        Task.detached(priority: .userInitiated) {
            let found = await Finder.find(last: shown)
            await MainActor.run {
                self.searching = false
                if let found = found {
                    self.ip = found
                    if reloadAlways || found != shown { self.show(found) }
                } else if reloadAlways {
                    self.show(shown)
                }
            }
        }
    }
}

enum Finder {
    static func find(last: String) async -> String? {
        for candidate in [last, defaultTV] {
            if await ping(candidate, timeout: 1.2) { return candidate }
        }
        // Every address in the phone's /24 and in the TV's last known /24.
        var prefixes = [String]()
        if let own = wifiAddress() { prefixes.append(prefix(own)) }
        for known in [last, defaultTV] where !prefixes.contains(prefix(known)) { prefixes.append(prefix(known)) }
        let hosts = prefixes.flatMap { p in (1...254).map { "\(p).\($0)" } }
        return await withTaskGroup(of: String?.self) { group in
            var next = 0
            // at most 48 at a time
            for _ in 0..<min(48, hosts.count) { let h = hosts[next]; next += 1; group.addTask { await ping(h, timeout: 0.6) ? h : nil } }
            while let result = await group.next() {
                if let hit = result { group.cancelAll(); return hit }
                if next < hosts.count { let h = hosts[next]; next += 1; group.addTask { await ping(h, timeout: 0.6) ? h : nil } }
            }
            return nil
        }
    }

    static func ping(_ host: String, timeout: TimeInterval) async -> Bool {
        guard let url = URL(string: "http://\(host):\(port)/ping") else { return false }
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        request.cachePolicy = .reloadIgnoringLocalCacheData
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode == 200 && String(decoding: data, as: UTF8.self).contains("shelf-remote")
        } catch {
            return false
        }
    }

    private static func prefix(_ ip: String) -> String { ip.split(separator: ".").prefix(3).joined(separator: ".") }

    /// The phone's IPv4 address on Wi-Fi (en0).
    private static func wifiAddress() -> String? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return nil }
        defer { freeifaddrs(list) }
        for p in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = p.pointee
            guard let addr = ifa.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET), String(cString: ifa.ifa_name) == "en0" else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                return String(cString: host)
            }
        }
        return nil
    }
}
