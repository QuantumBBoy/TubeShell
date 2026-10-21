import UIKit
@preconcurrency import WebKit

// YouTube videos open in their own web view (the "player") over the list, like the
// app: the list (home, search, channel) never leaves its page, so it stays exactly where
// it was. Dragging the video down shrinks the player into a floating mini player that
// keeps playing; tap it to bring it back, × or flick it right to close it.

private enum MiniPlayer {
  /// Width as a share of the screen, up to maxWidth (pt).
  static let widthFraction: CGFloat = 0.46
  static let maxWidth: CGFloat = 240
  /// Room kept above YouTube's bottom bar (Home / You), pt.
  static let bottomBarClearance: CGFloat = 76
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
    miniPlayButton.setImage(
      UIImage(systemName: paused ? "play.fill" : "pause.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: 18)),
      for: .normal)
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

  @objc func restoreMini() {
    guard playerMinimized else { return }
    tick()
    expandPlayer()
    select(.youtube)
  }

  func expandPlayer() {
    guard let player = playerTab, playerMinimized else { return }
    playerMinimized = false
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

  @objc func closeMini() {
    closePlayer()
  }

  /// Gone for good: the next tapped video opens a new player.
  func closePlayer() {
    guard let player = playerTab else { return }
    player.pauseAllMedia()
    player.webView.removeFromSuperview()
    playerTab = nil
    playerMinimized = false
    miniView.isHidden = true
    updateWebViewVisibility()
    UserDefaults.standard.removeObject(forKey: DefaultsKey.lastPlayerURL)
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
    for case let button as UIButton in miniView.subviews where button !== miniPlayButton {
      button.frame.origin = CGPoint(x: width - button.frame.width, y: 0)
    }
    miniPlayButton.center = CGPoint(x: width / 2, y: height / 2)
  }
}
