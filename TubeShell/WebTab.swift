import UIKit
@preconcurrency import WebKit

/// One WKWebView configured like a Brave tab with Shields on:
/// network rules + scriptlets injected at document start in the page world.
@MainActor
final class WebTab: NSObject {

  let tab: AppTab
  let webView: WKWebView
  weak var owner: MainViewController?
  private var urlObservation: NSKeyValueObservation?
  private var pendingCommands: [String] = []
  private var colorObservation: NSKeyValueObservation?
  private var crashDates: [Date] = []

  /// Same user agent ending as Safari, so Google allows signing in.
  private static let userAgentSuffix = "Version/26.0 Mobile/15E148 Safari/604.1"

  private static let shieldsSource: String? = {
    guard let url = Bundle.main.url(forResource: "Shields", withExtension: "js") else {
      NSLog("TubeShell: Shields.js not found in the app bundle")
      return nil
    }
    return try? String(contentsOf: url, encoding: .utf8)
  }()

  /// Pages get the whole screen and Shields.js moves their bars clear of the island and
  /// home indicator, so content runs under both (iOS 26+ on Dynamic Island iPhones, see
  /// MainViewController). Otherwise the web view sits below the capsule with WebKit's insets.
  let edgeToEdge: Bool

  /// YouTube videos open in a second web view over the list (the "player"), so the list
  /// stays where it was; see MainViewController.
  let isPlayer: Bool
  private let startURL: URL

  init(
    tab: AppTab, ruleList: WKContentRuleList?, edgeToEdge: Bool, startURL: URL,
    isPlayer: Bool = false, autoplay: Bool = false
  ) {
    self.tab = tab
    self.edgeToEdge = edgeToEdge
    self.startURL = startURL
    self.isPlayer = isPlayer

    let configuration = WKWebViewConfiguration()
    // Default data store: both tabs share the same Google session and cookies.
    configuration.websiteDataStore = .default()
    configuration.allowsInlineMediaPlayback = true
    configuration.allowsPictureInPictureMediaPlayback = true
    configuration.mediaTypesRequiringUserActionForPlayback = []
    configuration.applicationNameForUserAgent = Self.userAgentSuffix
    // YouTube's own fullscreen button: the player (with its controls, captions and
    // SponsorBlock notices) fills the screen and rotates, instead of the bare iOS player.
    configuration.preferences.isElementFullscreenEnabled = true

    let controller = configuration.userContentController
    if let ruleList {
      controller.add(ruleList)
    }
    if edgeToEdge {
      // Read by Shields.js (the user agent still says iOS 18, so it cannot tell).
      controller.addUserScript(
        WKUserScript(
          source: "window.__tubeShellEdgeToEdge = true;",
          injectionTime: .atDocumentStart,
          forMainFrameOnly: true,
          in: .page
        )
      )
    }
    // Reopen the song or video at the second it was left; Shields.js seeks once it loads.
    if let saved = UserDefaults.standard.dictionary(forKey: tab.lastPositionKey),
      let id = saved["v"] as? String, let seconds = saved["t"] as? Int,
      id.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }),
      URLComponents(url: startURL, resolvingAgainstBaseURL: false)?
        .queryItems?.first(where: { $0.name == "v" })?.value == id
    {
      controller.addUserScript(
        WKUserScript(
          source: "window.__tubeShellResumeAt = { v: '\(id)', t: \(seconds) };",
          injectionTime: .atDocumentStart,
          forMainFrameOnly: true,
          in: .page
        )
      )
    }
    // Read by Shields.js: the player page, and whether its first video may start at once
    // (a tapped video) or waits paused (reopened at launch).
    if isPlayer || autoplay {
      controller.addUserScript(
        WKUserScript(
          source: "window.__tubeShellPlayerPage = \(isPlayer); window.__tubeShellAutoplay = \(autoplay);",
          injectionTime: .atDocumentStart,
          forMainFrameOnly: true,
          in: .page
        )
      )
    }
    if let source = Self.shieldsSource {
      // Page world + document start, exactly like Brave injects its scriptlets:
      // the script must patch JSON.parse/fetch before YouTube's own code runs.
      controller.addUserScript(
        WKUserScript(
          source: source,
          injectionTime: .atDocumentStart,
          forMainFrameOnly: false,
          in: .page
        )
      )
    }
    let messageProxy = ScriptMessageProxy()
    controller.add(messageProxy, contentWorld: .page, name: "tubeshell")

    webView = WKWebView(frame: .zero, configuration: configuration)
    super.init()

    messageProxy.target = self
    webView.navigationDelegate = self
    webView.uiDelegate = self
    webView.allowsBackForwardNavigationGestures = true
    refreshControl.tintColor = .white
    refreshControl.addTarget(self, action: #selector(pulledToRefresh), for: .valueChanged)
    // Not on YouTube's player: dragging the video down is the mini player gesture.
    if !isPlayer { webView.scrollView.refreshControl = refreshControl }
    // The system back swipe needs a page behind; when there is none (the app reopened
    // straight on a video), the same swipe runs Shields.js's back() fallback instead.
    let edgeSwipe = UIScreenEdgePanGestureRecognizer(target: self, action: #selector(edgeSwiped(_:)))
    edgeSwipe.edges = .left
    edgeSwipe.delegate = self
    webView.addGestureRecognizer(edgeSwipe)
    webView.isOpaque = false
    webView.backgroundColor = .black
    // Lets you debug from Safari on the Mac (Develop menu > your iPhone).
    webView.isInspectable = true
    if #available(iOS 26.0, *), edgeToEdge {
      // The page owns the whole screen, with no blur bands at the edges.
      webView.scrollView.contentInsetAdjustmentBehavior = .never
      webView.scrollView.topEdgeEffect.isHidden = true
      webView.scrollView.bottomEdgeEffect.isHidden = true
    }

    // Remember the page (YouTube changes it without a full load, hence KVO).
    // Sign-in pages and the other site are skipped, so the tab reopens on its own site.
    urlObservation = webView.observe(\.url) { [weak self] webView, _ in
      MainActor.assumeIsolated {
        guard let self, let url = webView.url, AppTab.preferred(for: url) == self.tab else { return }
        if self.isPlayer {
          UserDefaults.standard.set(url.absoluteString, forKey: AppTab.lastPlayerURLKey)
        } else if self.tab == .youtube, url.path == "/watch" {
          // The list reached a video without a tapped link: play it in the player.
          self.owner?.listOpenedVideo(self, url: url)
        } else {
          UserDefaults.standard.set(url.absoluteString, forKey: self.tab.lastURLKey)
        }
      }
    }
    // The strip behind the clock takes the page's background colour.
    colorObservation = webView.observe(\.underPageBackgroundColor) { [weak self] _, _ in
      MainActor.assumeIsolated {
        guard let self else { return }
        self.owner?.pageColorDidChange(in: self.tab)
      }
    }
  }

  /// Music's full player open: its own gestures (drag down to fold, sideways to change
  /// song) must not start pull to refresh or WebKit's back swipe, which take the touch
  /// away from the page and leave the player where it was.
  private var musicPlayerOpen = false

  private func setMusicPlayerOpen(_ open: Bool) {
    musicPlayerOpen = open
    webView.allowsBackForwardNavigationGestures = !open
    webView.scrollView.refreshControl = open ? nil : refreshControl
  }

  @objc private func edgeSwiped(_ gesture: UIScreenEdgePanGestureRecognizer) {
    guard gesture.state == .ended, gesture.translation(in: webView).x > 80 else { return }
    // Music's full player is not a page of its own: the edge swipe folds it.
    if musicPlayerOpen { return run("back()") }
    guard !webView.canGoBack else { return }
    // Back from the player's first video: fold it into the mini player, like the app.
    if isPlayer { owner?.minimize(self) } else { run("back()") }
  }

  func load(_ url: URL) {
    webView.load(URLRequest(url: url))
  }

  /// Runs a Shields.js command once the page now loading has finished.
  func runAfterLoad(_ command: String) {
    pendingCommands.append(command)
  }

  func pauseAllMedia() {
    let script = """
      document.querySelectorAll('video, audio').forEach(function (m) {
        if (!m.paused) { m.pause(); }
      });
      void 0;
      """
    webView.evaluateJavaScript(script, completionHandler: nil)
  }

  /// Runs one of the page commands Shields.js defines on window.__tubeShell
  /// (search, account, go(n), history), standing in for the hidden page headers.
  func run(_ command: String) {
    // Right after launch the page is still loading: run it once it has.
    if webView.isLoading || webView.url == nil {
      pendingCommands.append(command)
      return
    }
    webView.evaluateJavaScript("window.__tubeShell && window.__tubeShell.\(command); void 0;", completionHandler: nil)
  }

  /// Sleep timer "at the end of the song": Shields.js pauses when the track ends.
  func setSleepAtEndOfTrack(_ enabled: Bool) {
    webView.evaluateJavaScript("window.__tubeShellSleepAtEnd = \(enabled); void 0;", completionHandler: nil)
  }

  // MARK: - Offline screen and pull to refresh

  private lazy var offlineView: UIView = {
    let icon = UIImageView(
      image: UIImage(systemName: "wifi.slash", withConfiguration: UIImage.SymbolConfiguration(pointSize: 44, weight: .medium)))
    icon.tintColor = .secondaryLabel
    let title = UILabel()
    title.text = "Sin conexión"
    title.font = .preferredFont(forTextStyle: .title2).withSize(22)
    title.textColor = .label
    let detail = UILabel()
    detail.text = "Comprueba tu conexión a internet. La página se cargará sola al volver."
    detail.font = .preferredFont(forTextStyle: .subheadline)
    detail.textColor = .secondaryLabel
    detail.numberOfLines = 0
    detail.textAlignment = .center
    var config = UIButton.Configuration.filled()
    config.title = "Reintentar"
    config.cornerStyle = .capsule
    config.baseBackgroundColor = .white
    config.baseForegroundColor = .black
    let retry = UIButton(configuration: config, primaryAction: UIAction { [weak self] _ in self?.retryAfterOffline() })
    let stack = UIStackView(arrangedSubviews: [icon, title, detail, retry])
    stack.axis = .vertical
    stack.alignment = .center
    stack.spacing = 14
    stack.setCustomSpacing(24, after: detail)
    stack.translatesAutoresizingMaskIntoConstraints = false
    let container = UIView()
    container.backgroundColor = .black
    container.addSubview(stack)
    NSLayoutConstraint.activate([
      stack.centerXAnchor.constraint(equalTo: container.centerXAnchor),
      stack.centerYAnchor.constraint(equalTo: container.centerYAnchor),
      stack.widthAnchor.constraint(lessThanOrEqualTo: container.widthAnchor, constant: -64),
    ])
    return container
  }()
  private var failedURL: URL?

  private func showOffline(for url: URL?) {
    failedURL = url ?? failedURL
    offlineView.frame = webView.bounds
    offlineView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    webView.addSubview(offlineView)
  }

  private func retryAfterOffline() {
    offlineView.removeFromSuperview()
    if let failedURL { load(failedURL) } else { webView.reload() }
  }

  /// The connection is back: reload a page that failed for lack of it.
  func connectionRestored() {
    if offlineView.superview != nil { retryAfterOffline() }
  }

  private static let offlineErrors: Set<Int> = [
    NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost, NSURLErrorTimedOut,
    NSURLErrorCannotFindHost, NSURLErrorCannotConnectToHost, NSURLErrorDataNotAllowed,
    NSURLErrorInternationalRoamingOff,
  ]

  fileprivate func navigationFailed(_ error: Error) {
    let error = error as NSError
    guard error.domain == NSURLErrorDomain, Self.offlineErrors.contains(error.code) else { return }
    showOffline(for: error.userInfo[NSURLErrorFailingURLErrorKey] as? URL)
  }

  /// Pull down at the top of a page to reload it, unless something is playing there
  /// (a reload would stop it).
  private let refreshControl = UIRefreshControl()
  /// Keeps the spinner clear of the island when the page runs under it.
  var refreshTopOffset: CGFloat = 0 {
    didSet {
      refreshControl.bounds.origin.y = -refreshTopOffset
    }
  }

  @objc private func pulledToRefresh() {
    webView.evaluateJavaScript("[...document.querySelectorAll('video, audio')].some(m => !m.paused)") {
      [weak self] result, _ in
      guard let self else { return }
      if (result as? Bool) == true {
        self.refreshControl.endRefreshing()
      } else {
        self.webView.reload()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { self.refreshControl.endRefreshing() }
      }
    }
  }

  fileprivate func handle(_ message: WKScriptMessage) {
    guard
      let body = message.body as? [String: Any],
      let type = body["type"] as? String
    else { return }

    if type == "haptic" {
      owner?.tick()
    } else if type == "play" {
      owner?.mediaDidStartPlaying(in: tab, from: self)
    } else if type == "openVideo", let link = body["url"] as? String, let url = URL(string: link) {
      owner?.openVideo(url)
    } else if type == "musicPlayer", let open = body["open"] as? Bool {
      setMusicPlayerOpen(open)
    } else if type == "minimize" {
      owner?.minimize(self)
    } else if type == "slept" {
      owner?.sleepDidPauseAtEndOfTrack()
    } else if type == "position", let id = body["v"] as? String, let seconds = body["t"] as? Int {
      UserDefaults.standard.set(["v": id, "t": seconds], forKey: tab.lastPositionKey)
    }
  }

  // MARK: - Link handling

  /// Hosts that stay inside the app. Everything else opens in the default browser.
  static func isInternal(_ url: URL) -> Bool {
    guard let host = url.host?.lowercased() else { return false }
    let domains = [
      "youtube.com", "youtu.be", "youtube-nocookie.com",
      "google.com", "gstatic.com", "googleusercontent.com",
      "googlevideo.com", "ytimg.com", "ggpht.com",
    ]
    if domains.contains(where: { host == $0 || host.hasSuffix("." + $0) }) {
      return true
    }
    // Regional Google sign-in domains (accounts.google.es, ...).
    return host.hasPrefix("accounts.google.") || host.hasPrefix("www.google.")
  }

  private func policy(for action: WKNavigationAction) -> WKNavigationActionPolicy {
    guard let url = action.request.url else { return .allow }
    let scheme = url.scheme?.lowercased() ?? ""

    if ["about", "blob", "data"].contains(scheme) {
      return .allow
    }
    guard scheme == "http" || scheme == "https" else {
      if ["mailto", "tel", "sms"].contains(scheme) {
        UIApplication.shared.open(url)
      }
      // Blocks youtube://, vnd.youtube://, itms-apps:// ("open in the app" redirects).
      return .cancel
    }

    // Sub-frames (embedded players, sign-in iframes) are always allowed.
    if let targetFrame = action.targetFrame, !targetFrame.isMainFrame {
      return .allow
    }

    // A tapped YouTube Music link inside YouTube (or the reverse) goes to the other tab.
    if action.navigationType == .linkActivated,
      let preferred = AppTab.preferred(for: url),
      preferred != tab
    {
      owner?.open(url, in: preferred)
      return .cancel
    }

    if Self.isInternal(url) {
      return Self.allowWithoutOpeningApps
    }
    UIApplication.shared.open(url)
    return .cancel
  }

  /// "Allow, but don't hand the link to another app": stops iOS from jumping to the
  /// official YouTube / YouTube Music app when it is installed. Same value Brave and
  /// Firefox for iOS use (an undocumented WebKit policy); falls back to a plain allow.
  private static let allowWithoutOpeningApps =
    WKNavigationActionPolicy(rawValue: WKNavigationActionPolicy.allow.rawValue + 2) ?? .allow
}

// MARK: - WebKit delegates

extension WebTab: WKNavigationDelegate, WKUIDelegate {

  func webView(
    _ webView: WKWebView,
    decidePolicyFor navigationAction: WKNavigationAction,
    decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
  ) {
    decisionHandler(policy(for: navigationAction))
  }

  /// target="_blank" links and window.open().
  func webView(
    _ webView: WKWebView,
    createWebViewWith configuration: WKWebViewConfiguration,
    for navigationAction: WKNavigationAction,
    windowFeatures: WKWindowFeatures
  ) -> WKWebView? {
    if let url = navigationAction.request.url {
      if Self.isInternal(url) {
        webView.load(navigationAction.request)
      } else {
        UIApplication.shared.open(url)
      }
    }
    return nil
  }

  /// Transparent only until the first page paints (no white flash); opaque afterwards
  /// so the strips behind the status bar and home indicator take the page's colour.
  func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
    navigationFailed(error)
  }

  func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
    navigationFailed(error)
  }

  func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    webView.isOpaque = true
    offlineView.removeFromSuperview()
    let commands = pendingCommands
    pendingCommands = []
    commands.forEach(run)
  }

  /// iOS can kill the web content process during long background sessions.
  /// Reload, but give up after 3 crashes in a minute so a page that kills the process
  /// on load cannot spin forever (the tab stays blank until the next app launch).
  func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
    let now = Date()
    crashDates = crashDates.filter { now.timeIntervalSince($0) < 60 } + [now]
    guard crashDates.count <= 3 else {
      NSLog("TubeShell: web process keeps crashing in %@, not reloading", tab.title)
      return
    }
    // After a crash during the first load there is no page to reload yet.
    if webView.url == nil {
      load(startURL)
    } else {
      webView.reload()
    }
  }
}

extension WebTab: UIGestureRecognizerDelegate {
  func gestureRecognizer(
    _ gestureRecognizer: UIGestureRecognizer,
    shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
  ) -> Bool { true }
}

/// Avoids a retain cycle: WKUserContentController keeps its handlers strongly.
@MainActor
private final class ScriptMessageProxy: NSObject, WKScriptMessageHandler {
  weak var target: WebTab?

  func userContentController(
    _ userContentController: WKUserContentController,
    didReceive message: WKScriptMessage
  ) {
    target?.handle(message)
  }
}
