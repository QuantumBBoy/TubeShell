import AVKit
import MediaPlayer
import Network
import Speech
import UIKit
@preconcurrency import WebKit

/// Capsule dimensions (pt).
private enum Capsule {
  /// The Dynamic Island itself.
  static let islandWidth: CGFloat = 126
  /// What the capsule adds on each side of it.
  static let lobeWidth: CGFloat = 108
  static let height: CGFloat = 37
}

/// Full-screen container with one web view per tab. The tab switcher and the sleep timer
/// live in a black capsule that extends the Dynamic Island to both sides.
/// Both web views stay alive, so switching tabs never reloads or stops the music.
final class MainViewController: UIViewController {

  /// Set by the scene delegate when the app is opened from a quick action.
  var initialTab: AppTab?

  private let contentView = UIView()
  let islandBar = UIView()
  private var islandCenterY: NSLayoutConstraint?
  /// Where the web views start: the top edge (pages run under the island), the safe area,
  /// or below the capsule when it is a bar (no Dynamic Island, or landscape).
  private var contentToTop: NSLayoutConstraint!
  private var contentToSafeArea: NSLayoutConstraint!
  private var contentToBar: NSLayoutConstraint!
  /// Decided when the first web view is made; both tabs share it.
  var pagesEdgeToEdge: Bool?
  private let tabSwitch = UISegmentedControl(
    items: AppTab.allCases.map { tab in
      let image = UIImage(systemName: tab.symbolName)!
      image.accessibilityLabel = tab.title
      return image
    }
  )
  private let sleepButton = UIButton(type: .system)
  private let searchButton = UIButton(type: .system)
  let moreButton = UIButton(type: .system)
  /// Fires once, at the deadline, and pauses everything.
  private var sleepTimer: Timer?
  /// Refreshes the countdown in the capsule; runs only while the app is active.
  private var sleepRefreshTimer: Timer?
  var sleepDeadline: Date?
  var sleepAtEndOfTrack = false
  var webTabs: [AppTab: WebTab] = [:]
  var ruleList: WKContentRuleList?
  private var isReady = false
  private var pendingTab: AppTab?
  var selectedTab: AppTab?

  // MARK: - Haptics, rotation, connection

  /// Keyboard height assumed when sizing the search sheet (pt, iPhone).
  private static let keyboardHeight: CGFloat = 330

  private let haptic = UIImpactFeedbackGenerator(style: .light)

  /// A light tap: tab changes, track changes, mini player, timer.
  func tick() {
    haptic.impactOccurred()
  }

  /// Turning the iPhone sideways on a YouTube video goes fullscreen; upright leaves it.
  override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
    super.viewWillTransition(to: size, with: coordinator)
    guard selectedTab == .youtube, let player = playerTab, !playerMinimized else { return }
    if size.width > size.height {
      player.run("fullscreen(true)")
    } else {
      // Left once the iPhone is upright: measured mid-turn, YouTube kept the landscape
      // width for its seek bar and seeks landed left of the finger.
      coordinator.animate(alongsideTransition: nil) { _ in player.run("fullscreen(false)") }
    }
  }

  /// Every web view: the tabs' and, when open, the YouTube player.
  private var allWebTabs: [WebTab] { Array(webTabs.values) + [playerTab].compactMap { $0 } }

  private let pathMonitor = NWPathMonitor()
  /// Mobile data or iOS Low Data Mode: the data saver caps YouTube at 480p (Shields.js).
  var onCellular = false

  private func watchConnection() {
    pathMonitor.pathUpdateHandler = { [weak self] path in
      let cellular = path.isExpensive || path.isConstrained
      // The monitor runs on the main queue (see start below).
      MainActor.assumeIsolated {
        guard let self else { return }
        if path.status == .satisfied {
          self.allWebTabs.forEach { $0.connectionRestored() }
        }
        guard cellular != self.onCellular else { return }
        self.onCellular = cellular
        self.allWebTabs.forEach { $0.cellular = cellular }
      }
    }
    pathMonitor.start(queue: .main)
  }

  override var preferredStatusBarStyle: UIStatusBarStyle { .lightContent }
  // The island capsule takes the clock's place.
  override var prefersStatusBarHidden: Bool { true }
  override var prefersHomeIndicatorAutoHidden: Bool { videoFullscreen }

  /// A YouTube video full size with the iPhone sideways: the page shows it fullscreen
  /// (Shields.js fullscreen()) and the capsule steps aside.
  var videoFullscreen: Bool {
    view.bounds.width > view.bounds.height && selectedTab == .youtube && playerTab != nil && !playerMinimized
  }

  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    // ponytail: a top safe area of 50+ pt means a Dynamic Island (portrait), and the capsule
    // wraps it. Notch and home-button iPhones, and landscape, get it as a bar below the
    // status area instead, with the pages below it.
    let top = view.safeAreaInsets.top
    let wrapsIsland = hasIsland
    allWebTabs.forEach { $0.refreshTopOffset = $0.edgeToEdge ? top : 0 }
    islandCenterY?.constant = wrapsIsland ? top / 2 + 1 : top + 4 + Capsule.height / 2
    if miniTab != nil, miniDragStart == nil { layoutMini() }
    let fullscreen = videoFullscreen
    if islandBar.isHidden != fullscreen {
      islandBar.isHidden = fullscreen
      setNeedsUpdateOfHomeIndicatorAutoHidden()
    }
    let wanted =
      fullscreen || (wrapsIsland && pagesEdgeToEdge == true) ? contentToTop! : wrapsIsland ? contentToSafeArea! : contentToBar!
    if !wanted.isActive {
      [contentToBar!, contentToTop!, contentToSafeArea!].forEach { $0.isActive = false }
      wanted.isActive = true
    }
  }

  // Dynamic Island iPhones have a top safe area of 59 pt or more; notch models 44–50
  // (the 12 / 13 mini reach 50).
  private var hasIsland: Bool { view.safeAreaInsets.top >= 54 }

  override func viewDidLoad() {
    super.viewDidLoad()
    overrideUserInterfaceStyle = .dark
    view.backgroundColor = .black
    layoutViews()
    watchConnection()
    let center = NotificationCenter.default
    center.addObserver(self, selector: #selector(appBecameActive), name: UIApplication.didBecomeActiveNotification, object: nil)
    for name in [UIApplication.willResignActiveNotification, UIApplication.didEnterBackgroundNotification] {
      center.addObserver(self, selector: #selector(stopSleepRefreshNotification), name: name, object: nil)
    }

    let savedTab = (UserDefaults.standard.object(forKey: DefaultsKey.lastTab) as? Int)
      .flatMap(AppTab.init(rawValue:))
    pendingTab = initialTab ?? savedTab ?? .music

    // The rule list must be in place before the first page loads (the first web view
    // itself is made meanwhile, see viewIsAppearing).
    Task { @MainActor [weak self] in
      let rules = await ContentRules.compile()
      guard let self else { return }
      self.ruleList = rules
      self.isReady = true
      for webTab in self.webTabs.values { webTab.start(ruleList: rules) }
      self.select(self.pendingTab ?? .music)
      self.pendingTab = nil
      // The video that was open in the player comes back over the list, paused, the first
      // time YouTube is shown. Made at launch while on Music, YouTube would start it in the
      // background after the hold (and that stops the music).
      if let saved = UserDefaults.standard.string(forKey: DefaultsKey.lastPlayerURL) {
        self.pendingPlayerURL = URL(string: saved)
        if self.selectedTab == .youtube { self.select(.youtube) }
      }
      ShortcutActions.handler = { [weak self] action in self?.perform(action) }
    }
  }

  /// The view has its safe area now (what decides edge to edge pages): start the first web
  /// view while the content rules are still being looked up. Creating it launches WebKit's
  /// web process, the slow part; the rules are added to it before its page loads.
  override func viewIsAppearing(_ animated: Bool) {
    super.viewIsAppearing(animated)
    guard !isReady, webTabs.isEmpty else { return }
    let tab = pendingTab ?? .music
    _ = makeWebTab(for: tab, start: false)
  }

  // MARK: - Tabs

  func select(_ tab: AppTab) {
    guard isReady else {
      pendingTab = tab
      return
    }
    let webTab = webTabs[tab] ?? makeWebTab(for: tab)
    if tab == .youtube, let url = pendingPlayerURL {
      pendingPlayerURL = nil
      openVideo(url, autoplay: false, show: false)
    }
    // Bring to front; the covered views are hidden only when nothing plays in them
    // (updateWebViewVisibility): a hidden web view counts as "not visible" for WebKit,
    // which can pause its playback.
    contentView.bringSubviewToFront(webTab.webView)
    if tab == .youtube, let player = playerTab, !playerMinimized {
      contentView.bringSubviewToFront(player.webView)
    }
    selectedTab = tab
    updateWebViewVisibility()
    visibleWebTab(tab)?.wasShown()
    updateSleepButton()
    pageColorDidChange(in: tab)
    tabSwitch.selectedSegmentIndex = tab.rawValue
    UserDefaults.standard.set(tab.rawValue, forKey: DefaultsKey.lastTab)
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
    case .openLink(let url):
      if url.host == "music.youtube.com" {
        select(.music)
        webTabs[.music]?.load(url)
      } else if url.path == "/watch" {
        openVideo(url)
      } else {
        if let player = playerTab, !playerMinimized { minimize(player) }
        select(.youtube)
        webTabs[.youtube]?.load(url)
      }
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

  // MARK: - YouTube player and mini player (state; the behaviour is in MainViewController+Player.swift)

  let miniView = UIView()
  /// Off screen: how the volume gesture sets the system volume (iOS has no other way).
  lazy var volumeView: MPVolumeView = {
    let volume = MPVolumeView(frame: CGRect(x: -200, y: -200, width: 100, height: 40))
    view.addSubview(volume)
    return volume
  }()
  let miniPlayButton = UIButton(type: .system)
  var playerTab: WebTab?
  var playerMinimized = false
  /// The YouTube player is in the mode that sends the picture over AirPlay (360p).
  var airPlayVideo = false
  /// Video to reopen in the player once YouTube is shown (see viewDidLoad).
  var pendingPlayerURL: URL?
  /// Where the mini player was left (its centre); nil = bottom right.
  var miniCenter: CGPoint?
  /// Centre when a drag began; while dragging, layout passes leave the frame alone.
  var miniDragStart: CGPoint?
  /// Thrown to the right edge: tucked away with only a tab showing, still playing.
  var miniStashed = false
  /// Brightness / volume level over the fullscreen video.
  lazy var levelIndicator = LevelIndicator()
  /// The tab of a tucked-away mini player.
  let miniStashTab = UIView()

  // MARK: - Sleep timer

  func startSleep(minutes: Int) {
    cancelSleep()
    tick()
    let deadline = Date().addingTimeInterval(TimeInterval(minutes * 60))
    sleepDeadline = deadline
    // One timer at the deadline (it fires in the background too, because the audio
    // background mode keeps the app alive); the countdown refresh only runs on screen.
    let timer = Timer(fire: deadline, interval: 0, repeats: false) { [weak self] _ in
      MainActor.assumeIsolated {
        guard let self else { return }
        self.allWebTabs.forEach { $0.pauseAllMedia() }
        self.cancelSleep()
      }
    }
    timer.tolerance = 2
    RunLoop.main.add(timer, forMode: .common)
    sleepTimer = timer
    startSleepRefresh()
    updateSleepButton()
  }

  private func startSleepRefresh() {
    sleepRefreshTimer?.invalidate()
    sleepRefreshTimer = nil
    guard sleepDeadline != nil, UIApplication.shared.applicationState == .active else { return }
    sleepRefreshTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated { self?.updateSleepButton() }
    }
  }

  private func stopSleepRefresh() {
    sleepRefreshTimer?.invalidate()
    sleepRefreshTimer = nil
  }

  @objc private func stopSleepRefreshNotification() {
    stopSleepRefresh()
  }

  @objc private func appBecameActive() {
    guard sleepDeadline != nil else { return }
    updateSleepButton()
    startSleepRefresh()
  }

  func startSleepAtEndOfTrack() {
    cancelSleep()
    tick()
    sleepAtEndOfTrack = true
    webTabs.values.forEach { $0.setSleepAtEndOfTrack(true) }
    updateSleepButton()
  }

  func cancelSleep() {
    sleepTimer?.invalidate()
    sleepTimer = nil
    stopSleepRefresh()
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

  func updateSleepButton() {
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
    perform(.play)
  }

  func presentSearch(voice: Bool) {
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
    // ponytail: keyboard height assumed (see keyboardHeight); read it if sizes look off.
    if let presentation = sheet.sheetPresentationController {
      presentation.detents = [
        .custom(identifier: .init("twoThirds")) { max(220, $0.maximumDetentValue * 0.66 - Self.keyboardHeight) }
      ]
      presentation.prefersGrabberVisible = true
      presentation.preferredCornerRadius = 22
    }
    present(sheet, animated: true)
  }

  /// The system AirPlay picker, opened from the menu: AVRoutePickerView has no public
  /// way to present itself, so its own button is triggered.
  lazy var routePicker: AVRoutePickerView = {
    let picker = AVRoutePickerView(frame: .zero)
    picker.prioritizesVideoDevices = true
    picker.isHidden = true
    view.addSubview(picker)
    return picker
  }()

  // MARK: - Layout

  private func makeWebTab(for tab: AppTab, url: URL? = nil, start: Bool = true) -> WebTab {
    if pagesEdgeToEdge == nil {
      if #available(iOS 26.0, *) { pagesEdgeToEdge = hasIsland } else { pagesEdgeToEdge = false }
      view.setNeedsLayout()
    }
    let webTab = WebTab(
      tab: tab, ruleList: ruleList, edgeToEdge: pagesEdgeToEdge ?? false, startURL: url ?? tab.startURL)
    webTab.owner = self

    attach(webTab.webView)
    webTabs[tab] = webTab
    if start { webTab.start(ruleList: nil) }  // the rules are already in its configuration
    webTab.cellular = onCellular
    return webTab
  }

  func attach(_ webView: WKWebView) {
    webView.translatesAutoresizingMaskIntoConstraints = false
    contentView.addSubview(webView)
    NSLayoutConstraint.activate([
      webView.topAnchor.constraint(equalTo: contentView.topAnchor),
      webView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
      webView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
      webView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
    ])
  }

  /// iOS 26+: a dark Liquid Glass capsule to put behind a control; nil before iOS 26,
  /// where the controls keep their plain dark background.
  static func glass() -> UIView? {
    guard #available(iOS 26.0, *) else { return nil }
    let glass = UIVisualEffectView(effect: UIGlassEffect())
    glass.cornerConfiguration = .capsule()
    glass.isUserInteractionEnabled = false
    glass.overrideUserInterfaceStyle = .dark
    return glass
  }

  private func layoutViews() {
    contentView.translatesAutoresizingMaskIntoConstraints = false
    contentView.backgroundColor = .black
    view.addSubview(contentView)

    miniView.isHidden = true
    miniView.backgroundColor = .black
    miniView.overrideUserInterfaceStyle = .dark  // dark glass buttons over the video
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
    close.accessibilityLabel = L("Cerrar", "Close")
    close.frame = CGRect(x: 0, y: 0, width: 36, height: 36)
    if #available(iOS 26.0, *) {
      // iOS 26: real Liquid Glass buttons over the video.
      var glass = UIButton.Configuration.clearGlass()  // the variant meant for over media
      glass.cornerStyle = .capsule
      glass.baseForegroundColor = .white
      glass.image = UIImage(systemName: "xmark", withConfiguration: UIImage.SymbolConfiguration(pointSize: 11, weight: .bold))
      close.setImage(nil, for: .normal)  // the plain image would win over the configuration's
      close.configuration = glass
      close.frame.size = CGSize(width: 28, height: 28)
      glass.image = nil
      miniPlayButton.configuration = glass
    } else {
      miniPlayButton.backgroundColor = UIColor(white: 0, alpha: 0.45)
      miniPlayButton.layer.cornerRadius = 20
    }
    close.autoresizingMask = [.flexibleLeftMargin, .flexibleBottomMargin]
    close.addTarget(self, action: #selector(closeMini), for: .touchUpInside)
    miniView.addSubview(close)
    miniPlayButton.tintColor = .white
    miniPlayButton.frame = CGRect(x: 0, y: 0, width: 40, height: 40)
    miniPlayButton.addTarget(self, action: #selector(toggleMiniPlayback), for: .touchUpInside)
    setMiniPlayButton(paused: false)
    miniView.addSubview(miniPlayButton)
    miniStashTab.isHidden = true
    miniStashTab.isUserInteractionEnabled = false
    if let glass = Self.glass() {
      miniStashTab.addSubview(glass)
      glass.frame = miniStashTab.bounds
      glass.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    } else {
      miniStashTab.backgroundColor = UIColor(white: 0, alpha: 0.55)
    }
    let chevron = UIImageView(
      image: UIImage(systemName: "chevron.compact.left", withConfiguration: UIImage.SymbolConfiguration(pointSize: 20, weight: .semibold)))
    chevron.tintColor = .white
    chevron.contentMode = .center
    chevron.frame = miniStashTab.bounds
    chevron.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    miniStashTab.addSubview(chevron)
    miniView.addSubview(miniStashTab)
    miniView.addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(miniPanned(_:))))
    view.addSubview(miniView)

    islandBar.translatesAutoresizingMaskIntoConstraints = false
    islandBar.overrideUserInterfaceStyle = .dark
    if let glass = Self.glass() {
      // iOS 26: Liquid Glass, with the page showing through on both sides of the island.
      glass.frame = islandBar.bounds
      glass.autoresizingMask = [.flexibleWidth, .flexibleHeight]
      islandBar.addSubview(glass)
    } else {
      islandBar.backgroundColor = .black
      islandBar.layer.cornerRadius = Capsule.height / 2
      islandBar.layer.cornerCurve = .continuous
    }
    view.addSubview(islandBar)

    tabSwitch.translatesAutoresizingMaskIntoConstraints = false
    tabSwitch.selectedSegmentTintColor = UIColor(white: 1, alpha: 0.25)
    tabSwitch.backgroundColor = islandBar.backgroundColor
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
    sleepButton.accessibilityLabel = L("Temporizador para dormir", "Sleep timer")
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
    searchButton.accessibilityLabel = L("Buscar", "Search")
    searchButton.addAction(UIAction { [weak self] _ in self?.presentSearch(voice: false) }, for: .touchUpInside)
    // Hold to search by voice.
    searchButton.addGestureRecognizer(
      UILongPressGestureRecognizer(target: self, action: #selector(searchHeld(_:))))
    islandBar.addSubview(searchButton)

    moreButton.translatesAutoresizingMaskIntoConstraints = false
    moreButton.setImage(UIImage(systemName: "ellipsis", withConfiguration: symbol), for: .normal)
    moreButton.tintColor = .white
    moreButton.accessibilityLabel = L("Más", "More")
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
    // The capsule is the island plus a lobe on each side (see Capsule): tabs and search on
    // the left, sleep timer and menu on the right.
    let centerY = islandBar.centerYAnchor.constraint(equalTo: view.topAnchor, constant: 30)
    islandCenterY = centerY
    contentToTop = contentView.topAnchor.constraint(equalTo: view.topAnchor)
    contentToSafeArea = contentView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor)
    contentToBar = contentView.topAnchor.constraint(equalTo: islandBar.bottomAnchor, constant: 4)
    NSLayoutConstraint.activate([
      centerY,
      islandBar.centerXAnchor.constraint(equalTo: view.centerXAnchor),
      islandBar.widthAnchor.constraint(equalToConstant: Capsule.islandWidth + 2 * Capsule.lobeWidth),
      islandBar.heightAnchor.constraint(equalToConstant: Capsule.height),

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
