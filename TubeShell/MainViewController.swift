import AVKit
import Network
import Speech
import UIKit
@preconcurrency import WebKit

/// Full-screen container with one web view per tab. The tab switcher and the sleep timer
/// live in a black capsule that extends the Dynamic Island to both sides.
/// Both web views stay alive, so switching tabs never reloads or stops the music.
final class MainViewController: UIViewController {

  /// Set by the scene delegate when the app is opened from a quick action.
  var initialTab: AppTab?

  private let contentView = UIView()
  private let islandBar = UIView()
  private var islandCenterY: NSLayoutConstraint?
  /// Where the web views start: the top edge (pages run under the island), the safe area,
  /// or below the capsule when it is a bar (no Dynamic Island, or landscape).
  private var contentToTop: NSLayoutConstraint!
  private var contentToSafeArea: NSLayoutConstraint!
  private var contentToBar: NSLayoutConstraint!
  /// Decided when the first web view is made; both tabs share it.
  private var pagesEdgeToEdge: Bool?
  private let tabSwitch = UISegmentedControl(
    items: AppTab.allCases.map { tab in
      let image = UIImage(systemName: tab.symbolName)!
      image.accessibilityLabel = tab.title
      return image
    }
  )
  private let sleepButton = UIButton(type: .system)
  private let searchButton = UIButton(type: .system)
  private let moreButton = UIButton(type: .system)
  private var sleepTimer: Timer?
  private var sleepDeadline: Date?
  private var sleepAtEndOfTrack = false
  private var webTabs: [AppTab: WebTab] = [:]
  private var ruleList: WKContentRuleList?
  private var isReady = false
  private var pendingTab: AppTab?
  private var selectedTab: AppTab?

  private static let lastTabKey = "TubeShell.lastTab"

  // MARK: - Haptics, rotation, connection

  private let haptic = UIImpactFeedbackGenerator(style: .light)

  /// A light tap: tab changes, track changes, mini player, timer.
  func tick() {
    haptic.impactOccurred()
  }

  /// Turning the iPhone sideways on a YouTube video goes fullscreen; upright leaves it.
  override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
    super.viewWillTransition(to: size, with: coordinator)
    guard selectedTab == .youtube, let player = playerTab, !playerMinimized else { return }
    player.run("fullscreen(\(size.width > size.height))")
  }

  private let pathMonitor = NWPathMonitor()
  /// Mobile data or iOS Low Data Mode: the data saver caps YouTube at 480p (Shields.js).
  private var onCellular = false

  private func watchConnection() {
    pathMonitor.pathUpdateHandler = { [weak self] path in
      let cellular = path.isExpensive || path.isConstrained
      DispatchQueue.main.async {
        guard let self else { return }
        if path.status == .satisfied {
          self.webTabs.values.forEach { $0.connectionRestored() }
        }
        guard cellular != self.onCellular else { return }
        self.onCellular = cellular
        (Array(self.webTabs.values) + [self.playerTab].compactMap { $0 }).forEach {
          $0.run("network(\(cellular))")
        }
      }
    }
    pathMonitor.start(queue: .main)
  }

  override var preferredStatusBarStyle: UIStatusBarStyle { .lightContent }
  // The island capsule takes the clock's place.
  override var prefersStatusBarHidden: Bool { true }

  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    // ponytail: a top safe area of 50+ pt means a Dynamic Island (portrait), and the capsule
    // wraps it. Notch and home-button iPhones, and landscape, get it as a bar below the
    // status area instead, with the pages below it.
    let top = view.safeAreaInsets.top
    let wrapsIsland = hasIsland
    (Array(webTabs.values) + [playerTab].compactMap { $0 }).forEach { $0.refreshTopOffset = $0.edgeToEdge ? top : 0 }
    islandCenterY?.constant = wrapsIsland ? top / 2 + 1 : top + 4 + 18.5
    if miniTab != nil, miniDragStart == nil { layoutMini() }
    contentToBar.isActive = false
    contentToTop.isActive = false
    contentToSafeArea.isActive = false
    if !wrapsIsland {
      contentToBar.isActive = true
    } else if pagesEdgeToEdge == true {
      contentToTop.isActive = true
    } else {
      contentToSafeArea.isActive = true
    }
  }

  private var hasIsland: Bool { view.safeAreaInsets.top >= 50 }

  override func viewDidLoad() {
    super.viewDidLoad()
    overrideUserInterfaceStyle = .dark
    view.backgroundColor = .black
    layoutViews()
    watchConnection()

    let savedTab = (UserDefaults.standard.object(forKey: Self.lastTabKey) as? Int)
      .flatMap(AppTab.init(rawValue:))
    pendingTab = initialTab ?? savedTab ?? .music

    // The rule list must be ready before the first web view is created.
    Task { @MainActor [weak self] in
      let rules = await ContentRules.compile()
      guard let self else { return }
      self.ruleList = rules
      self.isReady = true
      self.select(self.pendingTab ?? .music)
      self.pendingTab = nil
      // The video that was open in the player comes back over the list, paused.
      if let saved = UserDefaults.standard.string(forKey: AppTab.lastPlayerURLKey), let url = URL(string: saved) {
        self.openVideo(url, autoplay: false, show: self.selectedTab == .youtube)
      }
      ShortcutActions.handler = { [weak self] action in self?.perform(action) }
    }
  }

  // MARK: - Tabs

  func select(_ tab: AppTab) {
    guard isReady else {
      pendingTab = tab
      return
    }
    let webTab = webTabs[tab] ?? makeWebTab(for: tab)
    // Bring to front instead of hiding the other view: a hidden web view
    // counts as "not visible" for WebKit, which can pause its playback.
    contentView.bringSubviewToFront(webTab.webView)
    if tab == .youtube, let player = playerTab, !playerMinimized {
      contentView.bringSubviewToFront(player.webView)
    }
    selectedTab = tab
    updateSleepButton()
    pageColorDidChange(in: tab)
    tabSwitch.selectedSegmentIndex = tab.rawValue
    UserDefaults.standard.set(tab.rawValue, forKey: Self.lastTabKey)
  }

  /// Siri / Shortcuts.
  private func perform(_ action: ShortcutAction) {
    switch action {
    case .open(let tab):
      select(tab)
    case .play:
      select(.music)
      webTabs[.music]?.run("play()")
    case .sleep(let minutes):
      select(.music)
      startSleep(minutes: minutes)
    }
  }

  /// Another tab: switch to it. The tab you are on: go to its home page (no reload).
  private func tabTapped(_ tab: AppTab) {
    tick()
    if tab == selectedTab {
      // YouTube with a video open: fold it into the mini player, then home.
      if tab == .youtube, let player = playerTab, !playerMinimized { minimize(player) }
      webTabs[tab]?.run("home()")
    } else {
      select(tab)
    }
  }

  /// Opens a link in the tab it belongs to (e.g. a YouTube Music link tapped in YouTube).
  func open(_ url: URL, in tab: AppTab) {
    select(tab)
    webTabs[tab]?.load(url)
  }

  /// Paints the status bar strip with the visible page's background colour.
  func pageColorDidChange(in tab: AppTab) {
    guard tab == selectedTab, let webView = visibleWebTab(tab)?.webView else { return }
    view.backgroundColor = webView.underPageBackgroundColor ?? .black
  }

  /// Called when a video or song starts in one tab: pause the other tab, and close the
  /// mini player unless it is the one playing.
  func mediaDidStartPlaying(in tab: AppTab, from sender: WebTab) {
    for (otherTab, webTab) in webTabs where otherTab != tab {
      webTab.pauseAllMedia()
    }
    // Something else started (Music): the player stops; a mini player goes away.
    if let player = playerTab, player !== sender {
      if playerMinimized { closePlayer() } else { player.pauseAllMedia() }
    }
  }

  // MARK: - YouTube player and mini player
  // YouTube videos open in their own web view (the "player") over the list, like the
  // app: the list (home, search, channel) never leaves its page, so it stays exactly where
  // it was. Dragging the video down shrinks the player into a floating mini player that
  // keeps playing; tap it to bring it back, × or flick it right to close it.

  private let miniView = UIView()
  private let miniPlayButton = UIButton(type: .system)
  private var playerTab: WebTab?
  private var playerMinimized = false
  /// Where the mini player was left (its centre); nil = bottom right.
  private var miniCenter: CGPoint?
  /// Centre when a drag began; while dragging, layout passes leave the frame alone.
  private var miniDragStart: CGPoint?
  private var miniTab: WebTab? { playerMinimized ? playerTab : nil }

  /// The web view showing in a tab: YouTube's player when it is open full size.
  private func visibleWebTab(_ tab: AppTab) -> WebTab? {
    if tab == .youtube, let player = playerTab, !playerMinimized { return player }
    return webTabs[tab]
  }

  /// A video tapped in the list (or reopened at launch) plays in the player, full size.
  func openVideo(_ url: URL, autoplay: Bool = true, show: Bool = true) {
    if let player = playerTab {
      if playerMinimized { expandPlayer() }
      player.load(url)
      if autoplay { player.runAfterLoad("startPlayback()") }
    } else {
      let player = WebTab(
        tab: .youtube, ruleList: ruleList, edgeToEdge: pagesEdgeToEdge ?? false, startURL: url,
        isPlayer: true, autoplay: autoplay)
      player.owner = self
      attach(player.webView)
      playerTab = player
      player.load(url)
      player.run("network(\(onCellular))")
      if autoplay { player.runAfterLoad("startPlayback()") }
    }
    if show { select(.youtube) }
  }

  /// The list reached a video by itself (not a tapped link): play it in the player and
  /// take the list back to where it was.
  func listOpenedVideo(_ list: WebTab, url: URL) {
    guard list === webTabs[.youtube] else { return }
    if list.webView.canGoBack { list.webView.goBack() }
    openVideo(url)
  }

  func minimize(_ webTab: WebTab) {
    guard webTab === playerTab, !playerMinimized else { return }
    tick()
    webTab.run("mini(true)")
    let webView = webTab.webView
    webView.removeFromSuperview()
    webView.translatesAutoresizingMaskIntoConstraints = true
    webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    webView.isUserInteractionEnabled = false
    playerMinimized = true
    layoutMini()
    webView.frame = miniView.bounds
    miniView.insertSubview(webView, at: 0)
    if selectedTab == .youtube { select(.youtube) }
    miniView.alpha = 0
    miniView.isHidden = false
    UIView.animate(withDuration: 0.2) { self.miniView.alpha = 1 }
    refreshMiniPlayButton()
  }

  /// Pause / resume the video in the mini player.
  @objc private func toggleMiniPlayback() {
    let js = "(() => { const v = document.querySelector('video'); if (!v) return null; if (v.paused) v.play(); else v.pause(); return v.paused; })()"
    miniTab?.webView.evaluateJavaScript(js) { [weak self] result, _ in
      self?.setMiniPlayButton(paused: (result as? Bool) ?? false)
    }
  }

  private func refreshMiniPlayButton() {
    miniTab?.webView.evaluateJavaScript("(document.querySelector('video') || {}).paused === true") { [weak self] result, _ in
      self?.setMiniPlayButton(paused: (result as? Bool) ?? false)
    }
  }

  private func setMiniPlayButton(paused: Bool) {
    miniPlayButton.setImage(
      UIImage(systemName: paused ? "play.fill" : "pause.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: 18)),
      for: .normal)
    miniPlayButton.accessibilityLabel = paused ? "Reanudar" : "Pausar"
  }

  /// Drag the mini player anywhere and it stays where it is let go (kept on screen).
  /// Pushed well past the right edge, or flicked right at the edge, it closes.
  @objc private func miniPanned(_ pan: UIPanGestureRecognizer) {
    let move = pan.translation(in: view)
    switch pan.state {
    case .began:
      miniDragStart = miniView.center
    case .changed:
      guard let start = miniDragStart else { return }
      miniView.center = CGPoint(x: start.x + move.x, y: start.y + move.y)
    case .ended, .cancelled:
      guard miniDragStart != nil else { return }
      miniDragStart = nil
      let velocity = pan.velocity(in: view)
      let frame = miniView.frame
      let pastEdge = frame.maxX - view.bounds.width
      if pastEdge > frame.width * 0.35 || (pastEdge > 0 && velocity.x > 900) {
        UIView.animate(withDuration: 0.2) {
          self.miniView.frame.origin.x = self.view.bounds.width
          self.miniView.alpha = 0
        } completion: { _ in
          self.closeMini()
          self.miniView.alpha = 1
        }
        return
      }
      miniCenter = miniView.center
      UIView.animate(withDuration: 0.25, delay: 0, usingSpringWithDamping: 0.85, initialSpringVelocity: 0.4) {
        self.layoutMini()
      }
    default:
      break
    }
  }

  @objc private func restoreMini() {
    guard playerMinimized else { return }
    tick()
    expandPlayer()
    select(.youtube)
  }

  private func expandPlayer() {
    guard let player = playerTab, playerMinimized else { return }
    playerMinimized = false
    miniView.isHidden = true
    player.webView.removeFromSuperview()
    player.webView.isUserInteractionEnabled = true
    attach(player.webView)
    player.run("mini(false)")
  }

  @objc private func closeMini() {
    closePlayer()
  }

  /// Gone for good: the next tapped video opens a new player.
  private func closePlayer() {
    guard let player = playerTab else { return }
    player.pauseAllMedia()
    player.webView.removeFromSuperview()
    playerTab = nil
    playerMinimized = false
    miniView.isHidden = true
    UserDefaults.standard.removeObject(forKey: AppTab.lastPlayerURLKey)
  }

  /// Where it was left, kept between the capsule and YouTube's bottom bar; first time,
  /// bottom right.
  private func layoutMini() {
    let width = min(view.bounds.width * 0.46, 240)
    let height = (width * 9 / 16).rounded()
    let minY = islandBar.frame.maxY + 10
    let maxY = view.bounds.height - max(view.safeAreaInsets.bottom, 12) - 64 - height
    let center = miniCenter ?? CGPoint(x: view.bounds.width - width / 2 - 12, y: maxY + height / 2)
    miniView.frame = CGRect(
      x: min(max(center.x - width / 2, 12), view.bounds.width - width - 12),
      y: min(max(center.y - height / 2, minY), maxY),
      width: width, height: height)
    for case let button as UIButton in miniView.subviews where button !== miniPlayButton {
      button.frame.origin = CGPoint(x: width - button.frame.width, y: 0)
    }
    miniPlayButton.center = CGPoint(x: width / 2, y: height / 2)
  }

  // MARK: - Sleep timer

  private func sleepMenu() -> UIMenu {
    var items: [UIMenuElement] = []
    if let deadline = sleepDeadline {
      let minutes = max(1, Int(deadline.timeIntervalSinceNow / 60.0 + 0.5))
      items.append(UIAction(title: "Quedan \(minutes) min", attributes: .disabled) { _ in })
    } else if sleepAtEndOfTrack {
      items.append(UIAction(title: "Se parará al acabar la canción", attributes: .disabled) { _ in })
    }
    if sleepDeadline != nil || sleepAtEndOfTrack {
      items.append(
        UIAction(title: "Cancelar temporizador", image: UIImage(systemName: "xmark"), attributes: .destructive) {
          [weak self] _ in self?.cancelSleep()
        })
    }
    let choices = [15, 30, 45, 60].map { minutes in
      UIAction(title: "\(minutes) minutos") { [weak self] _ in self?.startSleep(minutes: minutes) }
    }
    let endOfTrack = UIAction(title: "Al acabar la canción") { [weak self] _ in
      self?.startSleepAtEndOfTrack()
    }
    items.append(UIMenu(title: "", options: .displayInline, children: choices + [endOfTrack]))
    return UIMenu(title: "Parar la música", children: items)
  }

  private func startSleep(minutes: Int) {
    cancelSleep()
    tick()
    sleepDeadline = Date().addingTimeInterval(TimeInterval(minutes * 60))
    // Ticks every second for the countdown; runs in the background too, because the
    // audio background mode keeps the app alive.
    sleepTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated {
        guard let self, let deadline = self.sleepDeadline else { return }
        if deadline.timeIntervalSinceNow <= 0 {
          self.webTabs.values.forEach { $0.pauseAllMedia() }
          self.playerTab?.pauseAllMedia()
          self.cancelSleep()
        } else {
          self.updateSleepButton()
        }
      }
    }
    updateSleepButton()
  }

  private func startSleepAtEndOfTrack() {
    cancelSleep()
    tick()
    sleepAtEndOfTrack = true
    webTabs.values.forEach { $0.setSleepAtEndOfTrack(true) }
    updateSleepButton()
  }

  private func cancelSleep() {
    sleepTimer?.invalidate()
    sleepTimer = nil
    sleepDeadline = nil
    if sleepAtEndOfTrack {
      sleepAtEndOfTrack = false
      webTabs.values.forEach { $0.setSleepAtEndOfTrack(false) }
    }
    updateSleepButton()
  }

  /// Shields.js paused the music at the end of the song.
  func sleepDidPauseAtEndOfTrack() {
    cancelSleep()
  }

  private func updateSleepButton() {
    let active = sleepDeadline != nil || sleepAtEndOfTrack
    // The timer belongs to Music; in YouTube it shows only while running.
    sleepButton.isHidden = selectedTab != .music && !active
    var config = UIButton.Configuration.plain()
    config.image = UIImage(
      systemName: active ? "moon.zzz.fill" : "moon.zzz",
      withConfiguration: UIImage.SymbolConfiguration(pointSize: 13, weight: .semibold))
    config.imagePadding = 3
    config.contentInsets = .zero
    config.baseForegroundColor = active ? .systemYellow : .white
    if let deadline = sleepDeadline {
      let seconds = max(0, Int(deadline.timeIntervalSinceNow.rounded()))
      var title = AttributedString(String(format: "%d:%02d", seconds / 60, seconds % 60))
      title.font = .monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
      config.attributedTitle = title
    }
    sleepButton.configuration = config
    if sleepButton.menu == nil || !active {
      sleepButton.menu = sleepMenu()
    }
  }

  // MARK: - Search

  @objc private func searchHeld(_ press: UILongPressGestureRecognizer) {
    if press.state == .began { presentSearch(voice: true) }
  }

  @objc private func musicHeld(_ press: UILongPressGestureRecognizer) {
    guard press.state == .began else { return }
    tick()
    select(.music)
    webTabs[.music]?.run("play()")
  }

  private func presentSearch(voice: Bool) {
    guard let tab = selectedTab, presentedViewController == nil else { return }
    tick()
    // Searching YouTube with a video open: it keeps playing in the mini player.
    if tab == .youtube, let player = playerTab, !playerMinimized { minimize(player) }
    let search = SearchViewController(tab: tab, startListening: voice) { [weak self] query in
      guard let data = try? JSONEncoder().encode(query), let literal = String(data: data, encoding: .utf8) else { return }
      self?.webTabs[tab]?.run("searchFor(\(literal))")
    }
    let sheet = UINavigationController(rootViewController: search)
    // About two thirds of the screen with the keyboard up, the page visible above it.
    // iOS grows a sheet by the keyboard's height, so the sheet itself is that much shorter.
    // ponytail: keyboard height assumed (~330 pt on iPhone); read it if sizes look off.
    if let presentation = sheet.sheetPresentationController {
      presentation.detents = [
        .custom(identifier: .init("twoThirds")) { max(220, $0.maximumDetentValue * 0.66 - 330) }
      ]
      presentation.prefersGrabberVisible = true
      presentation.preferredCornerRadius = 22
    }
    present(sheet, animated: true)
  }

  // MARK: - Page commands (the pages' own headers are hidden, see Shields.js)

  private func runInSelectedTab(_ command: String) {
    guard let tab = selectedTab else { return }
    visibleWebTab(tab)?.run(command)
  }

  private func moreMenu() -> UIMenu {
    func item(_ title: String, _ symbol: String, _ command: String) -> UIAction {
      UIAction(title: title, image: UIImage(systemName: symbol)) { [weak self] _ in
        self?.runInSelectedTab(command)
      }
    }
    var sections: [UIMenuElement] = []
    if let url = shareURL() {
      var shareItems: [UIMenuElement] = [
        UIAction(title: "Compartir", image: UIImage(systemName: "square.and.arrow.up")) { [weak self] _ in
          self?.share(url)
        }
      ]
      if url.host == "youtu.be" {
        shareItems.append(
          UIAction(title: "Compartir en este minuto", image: UIImage(systemName: "clock")) { [weak self] _ in
            self?.shareAtCurrentTime(url)
          })
      }
      sections.append(UIMenu(options: .displayInline, children: shareItems))
    }
    if selectedTab == .youtube, shareURL()?.host == "youtu.be" {
      sections.append(item("Subtítulos", "captions.bubble", "subtitles()"))
    }
    if let tab = selectedTab {
      sections.append(playbackMenu(for: tab))
    }
    if selectedTab == .music {
      sections.append(
        UIMenu(options: .displayInline, children: [
          item("Inicio", "house", "go(0)"),
          item("Explorar", "safari", "go(1)"),
          item("Biblioteca", "books.vertical", "go(2)"),
          item("Historial", "clock.arrow.circlepath", "history()"),
        ]))
    }
    sections.append(
      UIMenu(options: .displayInline, children: [
        item("Cuenta y ajustes", "person.crop.circle", "account()")
      ]))
    sections.append(
      UIAction(title: "AirPlay", image: UIImage(systemName: "airplayvideo")) { [weak self] _ in
        self?.showAirPlayPicker()
      })
    sections.append(
      UIAction(title: "Recargar", image: UIImage(systemName: "arrow.clockwise")) { [weak self] _ in
        guard let self, let tab = self.selectedTab else { return }
        self.visibleWebTab(tab)?.webView.reload()
      })
    return UIMenu(children: sections)
  }

  /// Speed (both sites) and video quality (YouTube). The choice is stored here for the
  /// checkmarks and in the page's localStorage by Shields.js, which applies it.
  private func playbackMenu(for tab: AppTab) -> UIMenu {
    let defaults = UserDefaults.standard
    let speedKey = "TubeShell.speed.\(tab.rawValue)"
    let currentSpeed = defaults.object(forKey: speedKey) as? Double ?? 1
    let speeds = [0.75, 1, 1.25, 1.5, 2].map { rate in
      UIAction(
        title: rate == 1 ? "Normal" : "\(rate.formatted())×",
        state: rate == currentSpeed ? .on : .off
      ) { [weak self] _ in
        defaults.set(rate, forKey: speedKey)
        self?.runInSelectedTab("speed(\(rate))")
      }
    }
    var children: [UIMenuElement] = [
      UIMenu(title: "Velocidad", image: UIImage(systemName: "gauge.with.dots.needle.67percent"), children: speeds),
    ]
    if tab == .youtube {
      let currentQuality = defaults.string(forKey: "TubeShell.quality") ?? "hd720"
      // Without Premium YouTube still serves up to 4K (VP9/AV1, decoded in hardware);
      // the video falls back to its best if it has less.
      let qualities = [
        ("auto", "Automática"), ("hd720", "720p"), ("hd1080", "1080p"),
        ("hd1440", "1440p (2K)"), ("hd2160", "2160p (4K)"), ("max", "Máxima"),
      ].map { value, title in
        UIAction(title: title, state: value == currentQuality ? .on : .off) { [weak self] _ in
          defaults.set(value, forKey: "TubeShell.quality")
          self?.runInSelectedTab("quality('\(value)')")
        }
      }
      let saverOn = defaults.object(forKey: "TubeShell.dataSaver") as? Bool ?? true
      let saver = UIAction(
        title: "Ahorro de datos",
        subtitle: onCellular ? "480p con datos móviles · ahora activo" : "480p con datos móviles",
        image: UIImage(systemName: "antenna.radiowaves.left.and.right"),
        state: saverOn ? .on : .off
      ) { [weak self] _ in
        defaults.set(!saverOn, forKey: "TubeShell.dataSaver")
        self?.runInSelectedTab("saver(\(!saverOn))")
      }
      children.append(
        UIMenu(
          title: "Calidad", image: UIImage(systemName: "sparkles.tv"),
          children: qualities + [UIMenu(options: .displayInline, children: [saver])]))
    }
    return UIMenu(options: .displayInline, children: children)
  }

  /// The visible page as a clean link: youtu.be/ID for a YouTube video, the plain watch
  /// link for a song, otherwise the page itself.
  private func shareURL() -> URL? {
    guard let tab = selectedTab, let url = visibleWebTab(tab)?.webView.url else { return nil }
    let id = URLComponents(url: url, resolvingAgainstBaseURL: false)?
      .queryItems?.first(where: { $0.name == "v" })?.value
    guard let id else { return url }
    return URL(string: tab == .music ? "https://music.youtube.com/watch?v=\(id)" : "https://youtu.be/\(id)")
  }

  /// youtu.be/ID?t=SECONDS, read from the video on screen.
  private func shareAtCurrentTime(_ url: URL) {
    guard let webView = visibleWebTab(.youtube)?.webView else { return }
    webView.evaluateJavaScript("Math.floor((document.querySelector('video') || {}).currentTime || 0)") {
      [weak self] result, _ in
      let seconds = (result as? NSNumber)?.intValue ?? 0
      var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
      if seconds > 0 { components?.queryItems = [URLQueryItem(name: "t", value: String(seconds))] }
      self?.share(components?.url ?? url)
    }
  }

  /// The system AirPlay picker, opened from the menu: AVRoutePickerView has no public
  /// way to present itself, so its own button is triggered.
  private lazy var routePicker: AVRoutePickerView = {
    let picker = AVRoutePickerView(frame: .zero)
    picker.isHidden = true
    view.addSubview(picker)
    return picker
  }()

  private func showAirPlayPicker() {
    routePicker.subviews.compactMap { $0 as? UIButton }.first?.sendActions(for: .touchUpInside)
  }

  private func share(_ url: URL) {
    let sheet = UIActivityViewController(activityItems: [url], applicationActivities: nil)
    sheet.popoverPresentationController?.sourceView = moreButton
    present(sheet, animated: true)
  }

  // MARK: - Layout

  private func makeWebTab(for tab: AppTab, url: URL? = nil) -> WebTab {
    if pagesEdgeToEdge == nil {
      if #available(iOS 26.0, *) { pagesEdgeToEdge = hasIsland } else { pagesEdgeToEdge = false }
      view.setNeedsLayout()
    }
    let webTab = WebTab(
      tab: tab, ruleList: ruleList, edgeToEdge: pagesEdgeToEdge ?? false, startURL: url ?? tab.startURL)
    webTab.owner = self

    attach(webTab.webView)
    webTabs[tab] = webTab
    webTab.load(url ?? tab.startURL)
    webTab.run("network(\(onCellular))")
    return webTab
  }

  private func attach(_ webView: WKWebView) {
    webView.translatesAutoresizingMaskIntoConstraints = false
    contentView.addSubview(webView)
    NSLayoutConstraint.activate([
      webView.topAnchor.constraint(equalTo: contentView.topAnchor),
      webView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
      webView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
      webView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
    ])
  }

  private func layoutViews() {
    contentView.translatesAutoresizingMaskIntoConstraints = false
    contentView.backgroundColor = .black
    view.addSubview(contentView)

    miniView.isHidden = true
    miniView.backgroundColor = .black
    miniView.layer.cornerRadius = 10
    miniView.layer.cornerCurve = .continuous
    miniView.layer.borderWidth = 0.5
    miniView.layer.borderColor = UIColor(white: 1, alpha: 0.25).cgColor
    miniView.clipsToBounds = true
    miniView.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(restoreMini)))
    let close = UIButton(type: .system)
    close.setImage(
      UIImage(systemName: "xmark.circle.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: 20)),
      for: .normal)
    close.tintColor = UIColor(white: 1, alpha: 0.9)
    close.accessibilityLabel = "Cerrar"
    close.frame = CGRect(x: 0, y: 0, width: 36, height: 36)
    close.autoresizingMask = [.flexibleLeftMargin, .flexibleBottomMargin]
    close.addTarget(self, action: #selector(closeMini), for: .touchUpInside)
    miniView.addSubview(close)
    miniPlayButton.tintColor = .white
    miniPlayButton.backgroundColor = UIColor(white: 0, alpha: 0.45)
    miniPlayButton.layer.cornerRadius = 20
    miniPlayButton.frame = CGRect(x: 0, y: 0, width: 40, height: 40)
    miniPlayButton.addTarget(self, action: #selector(toggleMiniPlayback), for: .touchUpInside)
    setMiniPlayButton(paused: false)
    miniView.addSubview(miniPlayButton)
    miniView.addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(miniPanned(_:))))
    view.addSubview(miniView)

    islandBar.translatesAutoresizingMaskIntoConstraints = false
    islandBar.backgroundColor = .black
    islandBar.layer.cornerRadius = 18.5
    islandBar.layer.cornerCurve = .continuous
    view.addSubview(islandBar)

    tabSwitch.translatesAutoresizingMaskIntoConstraints = false
    tabSwitch.selectedSegmentTintColor = UIColor(white: 1, alpha: 0.25)
    tabSwitch.backgroundColor = .black
    // The segmented control only shows the selected tab; a transparent button over each
    // half handles taps, so tapping the tab you are on can take you to its home page
    // (the control itself reports nothing when its selected segment is tapped again).
    tabSwitch.isUserInteractionEnabled = false
    tabSwitch.accessibilityElementsHidden = true
    islandBar.addSubview(tabSwitch)
    var tabButtonConstraints: [NSLayoutConstraint] = []
    for tab in AppTab.allCases {
      let button = UIButton(type: .custom)
      button.translatesAutoresizingMaskIntoConstraints = false
      button.accessibilityLabel = tab.title
      button.addAction(UIAction { [weak self] _ in self?.tabTapped(tab) }, for: .touchUpInside)
      if tab == .music {
        // Hold ♪ to resume the last song from anywhere.
        button.addGestureRecognizer(UILongPressGestureRecognizer(target: self, action: #selector(musicHeld(_:))))
      }
      islandBar.addSubview(button)
      let half = tabSwitch.widthAnchor.constraint(equalTo: button.widthAnchor, multiplier: 2)
      let leading =
        tab.rawValue == 0
        ? button.leadingAnchor.constraint(equalTo: tabSwitch.leadingAnchor)
        : button.trailingAnchor.constraint(equalTo: tabSwitch.trailingAnchor)
      tabButtonConstraints += [
        half, leading,
        button.topAnchor.constraint(equalTo: islandBar.topAnchor),
        button.bottomAnchor.constraint(equalTo: islandBar.bottomAnchor),
      ]
    }
    NSLayoutConstraint.activate(tabButtonConstraints)

    sleepButton.translatesAutoresizingMaskIntoConstraints = false
    sleepButton.accessibilityLabel = "Temporizador para dormir"
    sleepButton.showsMenuAsPrimaryAction = true
    sleepButton.preferredMenuElementOrder = .fixed
    // Rebuilt right before it opens, so "Quedan N min" is current.
    sleepButton.addAction(
      UIAction { [weak self] _ in
        guard let self else { return }
        self.sleepButton.menu = self.sleepMenu()
      },
      for: .menuActionTriggered
    )
    updateSleepButton()
    islandBar.addSubview(sleepButton)

    let symbol = UIImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
    searchButton.translatesAutoresizingMaskIntoConstraints = false
    searchButton.setImage(UIImage(systemName: "magnifyingglass", withConfiguration: symbol), for: .normal)
    searchButton.tintColor = .white
    searchButton.accessibilityLabel = "Buscar"
    searchButton.addAction(UIAction { [weak self] _ in self?.presentSearch(voice: false) }, for: .touchUpInside)
    // Hold to search by voice.
    searchButton.addGestureRecognizer(
      UILongPressGestureRecognizer(target: self, action: #selector(searchHeld(_:))))
    islandBar.addSubview(searchButton)

    moreButton.translatesAutoresizingMaskIntoConstraints = false
    moreButton.setImage(UIImage(systemName: "ellipsis", withConfiguration: symbol), for: .normal)
    moreButton.tintColor = .white
    moreButton.accessibilityLabel = "Más"
    moreButton.showsMenuAsPrimaryAction = true
    moreButton.preferredMenuElementOrder = .fixed
    moreButton.menu = moreMenu()
    // Depends on the visible tab: rebuilt right before it opens.
    moreButton.addAction(
      UIAction { [weak self] _ in
        guard let self else { return }
        self.moreButton.menu = self.moreMenu()
      },
      for: .menuActionTriggered
    )
    islandBar.addSubview(moreButton)

    // Web views run to the bottom edge; WebKit keeps the page clear of the home indicator.
    // At the top, iOS 26+ lets the page run under the island (see viewDidLayoutSubviews);
    // before that they start below it, or YouTube's fixed header slides under the island.
    // The capsule is the island (~126 pt wide) plus a 108 pt lobe on each side:
    // tabs and search on the left, sleep timer and menu on the right.
    let centerY = islandBar.centerYAnchor.constraint(equalTo: view.topAnchor, constant: 30)
    islandCenterY = centerY
    contentToTop = contentView.topAnchor.constraint(equalTo: view.topAnchor)
    contentToSafeArea = contentView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor)
    contentToBar = contentView.topAnchor.constraint(equalTo: islandBar.bottomAnchor, constant: 4)
    NSLayoutConstraint.activate([
      centerY,
      islandBar.centerXAnchor.constraint(equalTo: view.centerXAnchor),
      islandBar.widthAnchor.constraint(equalToConstant: 126 + 2 * 108),
      islandBar.heightAnchor.constraint(equalToConstant: 37),

      contentToSafeArea,
      contentView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      contentView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      contentView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

      tabSwitch.leadingAnchor.constraint(equalTo: islandBar.leadingAnchor, constant: 8),
      tabSwitch.centerYAnchor.constraint(equalTo: islandBar.centerYAnchor),
      tabSwitch.widthAnchor.constraint(equalToConstant: 64),
      tabSwitch.heightAnchor.constraint(equalToConstant: 27),

      searchButton.leadingAnchor.constraint(equalTo: tabSwitch.trailingAnchor, constant: 4),
      searchButton.centerYAnchor.constraint(equalTo: islandBar.centerYAnchor),
      searchButton.widthAnchor.constraint(equalToConstant: 30),
      searchButton.heightAnchor.constraint(equalToConstant: 30),

      moreButton.trailingAnchor.constraint(equalTo: islandBar.trailingAnchor, constant: -6),
      moreButton.centerYAnchor.constraint(equalTo: islandBar.centerYAnchor),
      moreButton.widthAnchor.constraint(equalToConstant: 30),
      moreButton.heightAnchor.constraint(equalToConstant: 30),

      sleepButton.trailingAnchor.constraint(equalTo: moreButton.leadingAnchor, constant: -2),
      sleepButton.centerYAnchor.constraint(equalTo: islandBar.centerYAnchor),
      sleepButton.widthAnchor.constraint(equalToConstant: 64),
      sleepButton.heightAnchor.constraint(equalToConstant: 27),
    ])
  }
}

// MARK: - Search screen

/// The app's own search: opens instantly with the keyboard up, lists recent searches,
/// and can listen (the mic in the search bar, or holding 🔍 in the capsule).
final class SearchViewController: UITableViewController, UISearchBarDelegate {

  private let searchTab: AppTab
  private let onSearch: (String) -> Void
  private let searchBar = UISearchBar()
  private var startListening: Bool
  private var recents: [String]
  private var recentsKey: String { "TubeShell.recentSearches.\(searchTab.rawValue)" }

  private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "es-ES"))
  private let audioEngine = AVAudioEngine()
  private var recognition: SFSpeechRecognitionTask?
  private var silenceTimer: Timer?

  init(tab: AppTab, startListening: Bool, onSearch: @escaping (String) -> Void) {
    self.searchTab = tab
    self.startListening = startListening
    self.onSearch = onSearch
    recents = UserDefaults.standard.stringArray(forKey: "TubeShell.recentSearches.\(tab.rawValue)") ?? []
    super.init(style: .plain)
  }

  required init?(coder: NSCoder) { fatalError() }

  override func viewDidLoad() {
    super.viewDidLoad()
    overrideUserInterfaceStyle = .dark
    searchBar.delegate = self
    searchBar.placeholder = searchTab == .music ? "Buscar en Music" : "Buscar en YouTube"
    searchBar.showsBookmarkButton = true
    searchBar.setImage(UIImage(systemName: "mic.fill"), for: .bookmark, state: .normal)
    searchBar.returnKeyType = .search
    navigationItem.titleView = searchBar
    navigationItem.rightBarButtonItem = UIBarButtonItem(
      systemItem: .cancel, primaryAction: UIAction { [weak self] _ in self?.close() })
    tableView.register(UITableViewCell.self, forCellReuseIdentifier: "recent")
    tableView.keyboardDismissMode = .onDrag
  }

  override func viewWillAppear(_ animated: Bool) {
    super.viewWillAppear(animated)
    if startListening {
      startListening = false
      listen()
    } else {
      searchBar.becomeFirstResponder()
    }
  }

  private func submit(_ text: String) {
    let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !query.isEmpty else { return }
    recents.removeAll { $0.caseInsensitiveCompare(query) == .orderedSame }
    recents.insert(query, at: 0)
    UserDefaults.standard.set(Array(recents.prefix(20)), forKey: recentsKey)
    stopListening()
    dismiss(animated: true)
    onSearch(query)
  }

  private func close() {
    stopListening()
    dismiss(animated: true)
  }

  func searchBarSearchButtonClicked(_ searchBar: UISearchBar) {
    submit(searchBar.text ?? "")
  }

  func searchBarBookmarkButtonClicked(_ searchBar: UISearchBar) {
    recognition == nil ? listen() : stopListening()
  }

  // MARK: Recent searches

  override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
    recents.count
  }

  override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
    recents.isEmpty ? nil : "Recientes"
  }

  override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
    let cell = tableView.dequeueReusableCell(withIdentifier: "recent", for: indexPath)
    var content = cell.defaultContentConfiguration()
    content.text = recents[indexPath.row]
    content.image = UIImage(systemName: "clock.arrow.circlepath")
    cell.contentConfiguration = content
    return cell
  }

  override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
    submit(recents[indexPath.row])
  }

  override func tableView(
    _ tableView: UITableView, commit editingStyle: UITableViewCell.EditingStyle, forRowAt indexPath: IndexPath
  ) {
    recents.remove(at: indexPath.row)
    UserDefaults.standard.set(recents, forKey: recentsKey)
    tableView.deleteRows(at: [indexPath], with: .automatic)
  }

  // MARK: Voice

  private func listen() {
    SFSpeechRecognizer.requestAuthorization { status in
      DispatchQueue.main.async {
        guard status == .authorized else { return self.voiceUnavailable() }
        AVAudioApplication.requestRecordPermission { granted in
          DispatchQueue.main.async { granted ? self.record() : self.voiceUnavailable() }
        }
      }
    }
  }

  private func voiceUnavailable() {
    searchBar.placeholder = "Permite el micrófono en Ajustes › Tube"
    searchBar.becomeFirstResponder()
  }

  private func record() {
    guard let recognizer, recognizer.isAvailable, recognition == nil else { return voiceUnavailable() }
    let session = AVAudioSession.sharedInstance()
    try? session.setCategory(.playAndRecord, mode: .measurement, options: [.duckOthers, .defaultToSpeaker])
    try? session.setActive(true)

    let request = SFSpeechAudioBufferRecognitionRequest()
    request.shouldReportPartialResults = true
    let input = audioEngine.inputNode
    input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0)) { buffer, _ in
      request.append(buffer)
    }
    audioEngine.prepare()
    do { try audioEngine.start() } catch { return stopListening() }

    searchBar.resignFirstResponder()
    searchBar.text = ""
    searchBar.placeholder = "Escuchando…"
    searchBar.setImage(UIImage(systemName: "mic.circle.fill"), for: .bookmark, state: .normal)
    recognition = recognizer.recognitionTask(with: request) { result, error in
      DispatchQueue.main.async {
        if let result {
          self.searchBar.text = result.bestTranscription.formattedString
          // Search once the voice has stopped for a moment.
          self.silenceTimer?.invalidate()
          self.silenceTimer = Timer.scheduledTimer(withTimeInterval: result.isFinal ? 0 : 1.4, repeats: false) { _ in
            MainActor.assumeIsolated { self.submit(self.searchBar.text ?? "") }
          }
        } else if error != nil {
          self.stopListening()
        }
      }
    }
  }

  private func stopListening() {
    silenceTimer?.invalidate()
    silenceTimer = nil
    guard recognition != nil else { return }
    recognition?.cancel()
    recognition = nil
    audioEngine.stop()
    audioEngine.inputNode.removeTap(onBus: 0)
    // Back to the media player session (background audio).
    try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [])
    searchBar.placeholder = searchTab == .music ? "Buscar en Music" : "Buscar en YouTube"
    searchBar.setImage(UIImage(systemName: "mic.fill"), for: .bookmark, state: .normal)
  }
}
