import AVFoundation
import UIKit
@preconcurrency import WebKit

// YouTube videos open in their own web view (the "player") over the list, like the
// app: the list (home, search, channel) never leaves its page, so it stays exactly where
// it was. Dragging the video down shrinks the player into a floating mini player that
// keeps playing; tap it to bring it back, × or flick it right to close it.

/// The brightness / volume level over the fullscreen video: a glass capsule (iOS 26)
/// with an icon and a bar, gone a moment after the last change.
final class LevelIndicator: UIView {
  private let icon = UIImageView()
  private let bar = UIProgressView(progressViewStyle: .bar)
  /// The time, when moving through a Short.
  private let time = UILabel()
  private var hideTimer: Timer?

  init() {
    super.init(frame: .zero)
    isUserInteractionEnabled = false
    alpha = 0
    overrideUserInterfaceStyle = .dark
    if let glass = MainViewController.glass() {
      glass.frame = bounds
      glass.autoresizingMask = [.flexibleWidth, .flexibleHeight]
      addSubview(glass)
    } else {
      backgroundColor = UIColor(white: 0.12, alpha: 0.7)
      layer.cornerRadius = 23
    }
    icon.tintColor = .white
    icon.contentMode = .center
    icon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 17, weight: .semibold)
    bar.trackTintColor = UIColor(white: 1, alpha: 0.25)
    bar.progressTintColor = .white
    bar.layer.cornerRadius = 2
    bar.clipsToBounds = true
    time.font = .monospacedDigitSystemFont(ofSize: 15, weight: .semibold)
    time.textColor = .white
    time.isHidden = true
    time.setContentHuggingPriority(.required, for: .horizontal)
    let row = UIStackView(arrangedSubviews: [icon, bar, time])
    row.spacing = 12
    row.alignment = .center
    row.translatesAutoresizingMaskIntoConstraints = false
    addSubview(row)
    NSLayoutConstraint.activate([
      icon.widthAnchor.constraint(equalToConstant: 26),
      bar.heightAnchor.constraint(equalToConstant: 4),
      row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
      row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20),
      row.centerYAnchor.constraint(equalTo: centerYAnchor),
    ])
  }

  required init?(coder: NSCoder) { fatalError() }

  func show(brightness: Bool, level: Double) {
    let symbol =
      brightness ? "sun.max.fill" : level == 0 ? "speaker.slash.fill" : level < 0.5 ? "speaker.wave.1.fill" : "speaker.wave.3.fill"
    icon.image = UIImage(systemName: symbol)
    bar.progress = Float(level)
    time.isHidden = true
    appear()
  }

  /// Moving through a Short: where it is, as a bar and as "0:12 / 0:45".
  func show(seconds: Double, of duration: Double) {
    func clock(_ value: Double) -> String {
      let total = max(0, Int(value))
      return "\(total / 60):" + String(format: "%02d", total % 60)
    }
    icon.image = UIImage(systemName: "play.fill")
    bar.progress = duration > 0 ? Float(seconds / duration) : 0
    time.text = clock(seconds) + " / " + clock(duration)
    time.isHidden = false
    appear()
  }

  private func appear() {
    if alpha < 1 {
      transform = CGAffineTransform(scaleX: 0.92, y: 0.92)
      UIView.animate(withDuration: 0.15) {
        self.alpha = 1
        self.transform = .identity
      }
    }
    hideTimer?.invalidate()
    hideTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: false) { [weak self] _ in
      MainActor.assumeIsolated {
        UIView.animate(withDuration: 0.25) { self?.alpha = 0 }
      }
    }
  }
}

private enum MiniPlayer {
  /// Width as a share of the screen, up to maxWidth (pt).
  static let widthFraction: CGFloat = 0.46
  static let maxWidth: CGFloat = 240
  /// Room kept above YouTube's bottom bar (Home / You), pt.
  static let bottomBarClearance: CGFloat = 76
  /// What shows of a tucked-away mini player, pt.
  static let stashTabWidth: CGFloat = 30
}

extension MainViewController {

  var miniTab: WebTab? { playerMinimized ? playerTab : nil }

  /// On screen now: the visible tab's page, or the player in the mini window.
  func isShowing(_ webTab: WebTab) -> Bool {
    if webTab === playerTab && playerMinimized { return true }
    guard let tab = selectedTab else { return false }
    return visibleWebTab(tab) === webTab
  }

  /// Hides the web views another page covers (the other tab, the list under the player),
  /// unless media plays in them: WebKit pauses media in a hidden web view, so a playing
  /// one stays put, just covered. Called whenever what is on top changes.
  func updateWebViewVisibility() {
    view.setNeedsLayout()  // the capsule hides for a fullscreen video (viewDidLayoutSubviews)
    let playerOnTop = playerTab != nil && !playerMinimized
    for (tab, webTab) in webTabs {
      let covered = tab != selectedTab || (tab == .youtube && playerOnTop)
      webTab.webView.isHidden = covered && !webTab.isPlayingMedia
    }
    if let player = playerTab {
      player.webView.isHidden = playerOnTop && selectedTab != .youtube && !player.isPlayingMedia
    }
  }

  /// The web view showing in a tab: YouTube's player when it is open full size.
  func visibleWebTab(_ tab: AppTab) -> WebTab? {
    if tab == .youtube, let player = playerTab, !playerMinimized { return player }
    return webTabs[tab]
  }

  /// A video tapped in the list (or reopened at launch) plays in the player, full size.
  func openVideo(_ url: URL, autoplay: Bool = true, show: Bool = true) {
    // Opened with the iPhone already sideways: straight to fullscreen.
    let landscape = view.bounds.width > view.bounds.height
    // Feed previews in the list keep playing under the player otherwise.
    webTabs[.youtube]?.pauseAllMedia()
    let player: WebTab
    if let existing = playerTab {
      if playerMinimized { expandPlayer() }
      existing.openInPage(url)
      player = existing
    } else {
      player = WebTab(
        tab: .youtube, ruleList: ruleList, edgeToEdge: pagesEdgeToEdge ?? false, startURL: url,
        isPlayer: true, autoplay: autoplay)
      player.owner = self
      attach(player.webView)
      playerTab = player
      player.load(url)
      player.cellular = onCellular
    }
    if autoplay { player.runAfterLoad("startPlayback()") }
    if landscape { player.runAfterLoad("fullscreen(true)") }
    if show { select(.youtube) }
  }

  /// The list reached a video by itself (not a tapped link): play it in the player and
  /// take the list back to where it was.
  func listOpenedVideo(_ list: WebTab, url: URL) {
    guard list === webTabs[.youtube] else { return }
    if list.webView.canGoBack { list.webView.goBack() }
    openVideo(url)
  }

  /// The player navigated away from the video (a channel, the account page): take it
  /// back to the video, shrink it, and open that page in the list.
  func playerLeftVideo(_ player: WebTab, to url: URL) {
    guard player === playerTab else { return }
    if player.webView.canGoBack { player.webView.goBack() }
    if !playerMinimized { minimize(player) }
    webTabs[.youtube]?.load(url)
  }

  func minimize(_ webTab: WebTab) {
    guard webTab === playerTab, !playerMinimized else { return }
    tick()
    webTab.setMini(true)
    let webView = webTab.webView
    let cover = relayoutCover(for: webView)
    webView.removeFromSuperview()
    webView.translatesAutoresizingMaskIntoConstraints = true
    webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    webView.isUserInteractionEnabled = false
    playerMinimized = true
    layoutMini()
    webView.frame = miniView.bounds
    miniView.insertSubview(webView, at: 0)
    if let cover { showCover(cover, in: miniView, above: webView, frame: miniView.bounds) }
    if selectedTab == .youtube { select(.youtube) }
    updateWebViewVisibility()
    miniView.alpha = 0
    miniView.isHidden = false
    UIView.animate(withDuration: 0.2) { self.miniView.alpha = 1 }
    refreshMiniPlayButton()
  }

  /// Pause / resume the video in the mini player.
  @objc func toggleMiniPlayback() {
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

  func setMiniPlayButton(paused: Bool) {
    let image = UIImage(systemName: paused ? "play.fill" : "pause.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: 18))
    if miniPlayButton.configuration != nil {
      miniPlayButton.configuration?.image = image
    } else {
      miniPlayButton.setImage(image, for: .normal)
    }
    miniPlayButton.accessibilityLabel = paused ? L("Reanudar", "Resume") : L("Pausar", "Pause")
  }

  /// Drag the mini player anywhere and it stays where it is let go (kept on screen).
  /// Pushed well past the right edge, or flicked right at the edge, it closes.
  @objc func miniPanned(_ pan: UIPanGestureRecognizer) {
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
      let pastLeft = -frame.minX
      let pastRight = frame.maxX - view.bounds.width
      miniCenter = CGPoint(x: miniStashed ? view.bounds.width : miniView.center.x, y: miniView.center.y)
      if miniStashed {
        // Pulled out to the left: back in view; otherwise it tucks away again.
        if move.x < -30 || velocity.x < -300 { setMiniStashed(false) }
      } else if pastLeft > frame.width * 0.35 || (pastLeft > 0 && velocity.x < -900) {
        // Thrown off to the left: closed.
        tick()
        UIView.animate(withDuration: 0.2) {
          self.miniView.frame.origin.x = -frame.width
          self.miniView.alpha = 0
        } completion: { _ in
          self.closeMini()
          self.miniView.alpha = 1
        }
        return
      } else if pastRight > frame.width * 0.35 || (pastRight > 0 && velocity.x > 900) {
        // Thrown to the right: tucked away at the edge, still playing.
        tick()
        setMiniStashed(true)
      } else {
        miniCenter = miniView.center
      }
      UIView.animate(withDuration: 0.25, delay: 0, usingSpringWithDamping: 0.85, initialSpringVelocity: 0.4) {
        self.layoutMini()
      }
    default:
      break
    }
  }

  @objc func restoreMini() {
    guard playerMinimized else { return }
    // Tucked away: tapping the tab brings the mini player back first.
    if miniStashed {
      tick()
      setMiniStashed(false)
      return
    }
    tick()
    expandPlayer()
    select(.youtube)
  }

  func expandPlayer() {
    guard let player = playerTab, playerMinimized else { return }
    playerMinimized = false
    setMiniStashed(false)
    miniView.isHidden = true
    let cover = relayoutCover(for: player.webView)
    player.webView.removeFromSuperview()
    player.webView.isUserInteractionEnabled = true
    attach(player.webView)
    if let cover, let host = player.webView.superview?.superview {
      showCover(cover, in: host, above: player.webView.superview!, frame: player.webView.superview!.frame)
    }
    updateWebViewVisibility()
    player.setMini(false)
    if view.bounds.width > view.bounds.height { player.run("fullscreen(true)") }
  }

  func setMiniStashed(_ stashed: Bool) {
    miniStashed = stashed
    miniStashTab.isHidden = !stashed
    miniPlayButton.isHidden = stashed
    UIView.animate(withDuration: 0.25, delay: 0, usingSpringWithDamping: 0.85, initialSpringVelocity: 0.4) {
      self.layoutMini()
    }
  }

  @objc func closeMini() {
    closePlayer()
  }

  /// Gone for good: the next tapped video opens a new player.
  func closePlayer() {
    guard let player = playerTab else { return }
    player.pauseAllMedia()
    player.webView.removeFromSuperview()
    playerTab = nil
    airPlayVideo = false  // a new player starts in normal quality
    playerMinimized = false
    setMiniStashed(false)
    miniView.isHidden = true
    updateWebViewVisibility()
    UserDefaults.standard.removeObject(forKey: DefaultsKey.lastPlayerURL)
  }

  /// Turns the screen sideways or back upright: YouTube's fullscreen button (iOS's video
  /// player is already up, see Shields.js) and leaving that player.
  func turnScreen(sideways: Bool? = nil) {
    guard let scene = view.window?.windowScene else { return }
    let isSideways = view.bounds.width > view.bounds.height
    let wanted = sideways ?? !isSideways
    guard wanted != isSideways else { return }
    if sideways == nil { tick() }
    // A moment later: iOS's video player is opening now and would ignore an earlier turn.
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
      scene.requestGeometryUpdate(.iOS(interfaceOrientations: wanted ? .landscapeRight : .portrait))
    }
  }

  // MARK: - Video gestures (Shields.js section 13)

  /// A drag on the fullscreen video: left half brightness, right half volume, with the
  /// level shown over the video.
  func adjust(_ kind: String, by delta: Double, in webTab: WebTab) {
    let level: Double
    if kind == "brightness" {
      let screen = view.window?.windowScene?.screen ?? UIScreen.main
      screen.brightness = min(1, max(0, screen.brightness + delta))
      level = screen.brightness
    } else if kind == "volume", let slider = volumeView.subviews.compactMap({ $0 as? UISlider }).first {
      // The slider can still be at 0 before it has synced: start from the real volume.
      let current = slider.value > 0 ? slider.value : AVAudioSession.sharedInstance().outputVolume
      slider.value = min(1, max(0, current + Float(delta)))
      level = Double(slider.value)
    } else {
      return
    }
    placeLevelIndicator(width: 230, y: max(view.safeAreaInsets.top, 16) + 8)
    levelIndicator.show(brightness: kind == "brightness", level: level)
  }

  /// A drag sideways on a Short (Shields.js): where it is now, low on the screen.
  func shortScrubbed(to seconds: Double, of duration: Double) {
    placeLevelIndicator(width: 300, y: view.bounds.height * 0.72)
    levelIndicator.show(seconds: seconds, of: duration)
  }

  private func placeLevelIndicator(width: CGFloat, y: CGFloat) {
    if levelIndicator.superview == nil { view.addSubview(levelIndicator) }
    view.bringSubviewToFront(levelIndicator)
    levelIndicator.frame = CGRect(x: (view.bounds.width - width) / 2, y: y, width: width, height: 46)
  }

  // MARK: - Hiding the relayout when the player changes size

  /// The player's page lays itself out again when its web view goes between full screen
  /// and the mini window. A snapshot of the old size covers that, then fades away.
  /// (Anchored top left, so the video lands on the video.)
  private func relayoutCover(for webView: WKWebView) -> UIView? {
    guard webView.bounds.width > 0, let snapshot = webView.snapshotView(afterScreenUpdates: false) else { return nil }
    let cover = UIView()
    cover.backgroundColor = .black
    cover.clipsToBounds = true
    cover.isUserInteractionEnabled = false
    snapshot.layer.anchorPoint = .zero
    snapshot.frame = CGRect(origin: .zero, size: webView.bounds.size)
    cover.addSubview(snapshot)
    return cover
  }

  private func showCover(_ cover: UIView, in host: UIView, above sibling: UIView, frame: CGRect) {
    guard let snapshot = cover.subviews.first else { return }
    let scale = frame.width / max(snapshot.bounds.width, 1)
    snapshot.transform = CGAffineTransform(scaleX: scale, y: scale)
    cover.frame = frame
    host.insertSubview(cover, aboveSubview: sibling)
    UIView.animate(withDuration: 0.15, delay: 0.25, options: .allowUserInteraction) {
      cover.alpha = 0
    } completion: { _ in
      cover.removeFromSuperview()
    }
  }

  /// Where it was left, kept between the capsule and YouTube's bottom bar; first time,
  /// bottom right.
  func layoutMini() {
    let width = min(view.bounds.width * MiniPlayer.widthFraction, MiniPlayer.maxWidth)
    let height = (width * 9 / 16).rounded()
    let minY = islandBar.frame.maxY + 10
    // Clear of YouTube's bottom bar (Home / You) with some room to spare.
    let maxY = view.bounds.height - max(view.safeAreaInsets.bottom, 12) - MiniPlayer.bottomBarClearance - height
    let center = miniCenter ?? CGPoint(x: view.bounds.width - width / 2 - 12, y: maxY + height / 2)
    miniView.frame = CGRect(
      x: min(max(center.x - width / 2, 12), view.bounds.width - width - 12),
      y: min(max(center.y - height / 2, minY), maxY),
      width: width, height: height)
    // Tucked away: only the tab at its left edge stays on screen.
    if miniStashed { miniView.frame.origin.x = view.bounds.width - MiniPlayer.stashTabWidth }
    miniStashTab.frame = CGRect(x: 0, y: 0, width: MiniPlayer.stashTabWidth, height: height)
    for case let button as UIButton in miniView.subviews where button !== miniPlayButton {
      // The glass close button sits a little in from the corner.
      let inset: CGFloat = button.configuration != nil ? 5 : 0
      button.frame.origin = CGPoint(x: width - button.frame.width - inset, y: inset)
    }
    miniPlayButton.center = CGPoint(x: width / 2, y: height / 2)
  }
}
