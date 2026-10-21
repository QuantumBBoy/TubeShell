import AVKit
import UIKit

// Menus behind the capsule buttons: sleep timer, more (⋯), speed and quality, share, AirPlay.

extension MainViewController {

  func sleepMenu() -> UIMenu {
    var items: [UIMenuElement] = []
    if let deadline = sleepDeadline {
      let minutes = max(1, Int(deadline.timeIntervalSinceNow / 60.0 + 0.5))
      items.append(UIAction(title: L("Quedan \(minutes) min", "\(minutes) min left"), attributes: .disabled) { _ in })
    } else if sleepAtEndOfTrack {
      items.append(UIAction(title: L("Se parará al acabar la canción", "Stops at the end of the song"), attributes: .disabled) { _ in })
    }
    if sleepDeadline != nil || sleepAtEndOfTrack {
      items.append(
        UIAction(title: L("Cancelar temporizador", "Cancel timer"), image: UIImage(systemName: "xmark"), attributes: .destructive) {
          [weak self] _ in self?.cancelSleep()
        })
    }
    let choices = [15, 30, 45, 60].map { minutes in
      UIAction(title: L("\(minutes) minutos", "\(minutes) minutes")) { [weak self] _ in self?.startSleep(minutes: minutes) }
    }
    let endOfTrack = UIAction(title: L("Al acabar la canción", "At the end of the song")) { [weak self] _ in
      self?.startSleepAtEndOfTrack()
    }
    items.append(UIMenu(title: "", options: .displayInline, children: choices + [endOfTrack]))
    return UIMenu(title: L("Parar la música", "Stop the music"), children: items)
  }

  // MARK: - Page commands (the pages' own headers are hidden, see Shields.js)

  private func runInSelectedTab(_ command: String) {
    guard let tab = selectedTab else { return }
    visibleWebTab(tab)?.run(command)
  }

  /// Speed, quality, data saver and subtitles act on the video: on YouTube that is the
  /// player, also while it is the mini player over the list.
  private func runOnPlayback(_ command: String) {
    if selectedTab == .youtube, let player = playerTab {
      player.run(command)
    } else {
      runInSelectedTab(command)
    }
  }

  func moreMenu() -> UIMenu {
    func item(_ title: String, _ symbol: String, _ command: String) -> UIAction {
      UIAction(title: title, image: UIImage(systemName: symbol)) { [weak self] _ in
        self?.runInSelectedTab(command)
      }
    }
    var sections: [UIMenuElement] = []
    if let url = shareURL() {
      var shareItems: [UIMenuElement] = [
        UIAction(title: L("Compartir", "Share"), image: UIImage(systemName: "square.and.arrow.up")) { [weak self] _ in
          self?.share(url)
        }
      ]
      if url.host == "youtu.be" {
        shareItems.append(
          UIAction(title: L("Compartir en este minuto", "Share at this moment"), image: UIImage(systemName: "clock")) { [weak self] _ in
            self?.shareAtCurrentTime(url)
          })
      }
      sections.append(UIMenu(options: .displayInline, children: shareItems))
    }
    if selectedTab == .youtube, playerTab != nil || shareURL()?.host == "youtu.be" {
      sections.append(
        UIAction(title: L("Subtítulos", "Subtitles"), image: UIImage(systemName: "captions.bubble")) { [weak self] _ in
          self?.runOnPlayback("subtitles()")
        })
    }
    if let tab = selectedTab {
      sections.append(playbackMenu(for: tab))
    }
    if selectedTab == .music, let music = webTabs[.music] {
      sections.append(
        UIAction(title: L("Letra", "Lyrics"), image: UIImage(systemName: "quote.bubble")) { [weak self] _ in
          self?.presentLyrics(from: music)
        })
    }
    if selectedTab == .music {
      sections.append(
        UIMenu(options: .displayInline, children: [
          item(L("Inicio", "Home"), "house", "go(0)"),
          item(L("Explorar", "Explore"), "safari", "go(1)"),
          item(L("Biblioteca", "Library"), "books.vertical", "go(2)"),
          item(L("Historial", "History"), "clock.arrow.circlepath", "history()"),
        ]))
    }
    sections.append(
      UIMenu(options: .displayInline, children: [
        UIAction(title: L("Cuenta y ajustes", "Account and settings"), image: UIImage(systemName: "person.crop.circle")) {
          [weak self] _ in
          guard let self else { return }
          // From a video: it shrinks into the mini player and the account opens in the list.
          if self.selectedTab == .youtube, let player = self.playerTab, !self.playerMinimized { self.minimize(player) }
          self.runInSelectedTab("account()")
        }
      ]))
    sections.append(
      UIAction(title: "AirPlay", image: UIImage(systemName: "airplayvideo")) { [weak self] _ in
        self?.showAirPlayPicker()
      })
    sections.append(
      UIAction(title: L("Recargar", "Reload"), image: UIImage(systemName: "arrow.clockwise")) { [weak self] _ in
        guard let self, let tab = self.selectedTab else { return }
        self.visibleWebTab(tab)?.reloadOrRetry()
      })
    return UIMenu(children: sections)
  }

  private func presentLyrics(from music: WebTab) {
    guard presentedViewController == nil else { return }
    let lyrics = LyricsViewController(page: music.webView)
    if let sheet = lyrics.sheetPresentationController {
      // Half height shows the sheet's glass with the player behind; drag up for more.
      sheet.detents = [.medium(), .large()]
      sheet.prefersGrabberVisible = true
    }
    present(lyrics, animated: true)
  }

  /// Speed (both sites) and video quality (YouTube). The choice is stored here for the
  /// checkmarks and in the page's localStorage by Shields.js, which applies it.
  private func playbackMenu(for tab: AppTab) -> UIMenu {
    let defaults = UserDefaults.standard
    let speedKey = DefaultsKey.speed(tab)
    let currentSpeed = defaults.object(forKey: speedKey) as? Double ?? 1
    let speeds = [0.75, 1, 1.25, 1.5, 2].map { rate in
      UIAction(
        title: rate == 1 ? L("Normal", "Normal") : "\(rate.formatted())×",
        state: rate == currentSpeed ? .on : .off
      ) { [weak self] _ in
        defaults.set(rate, forKey: speedKey)
        self?.runOnPlayback("speed(\(rate))")
      }
    }
    var children: [UIMenuElement] = [
      UIMenu(title: L("Velocidad", "Speed"), image: UIImage(systemName: "gauge.with.dots.needle.67percent"), children: speeds),
    ]
    if tab == .youtube {
      let currentQuality = defaults.string(forKey: DefaultsKey.quality) ?? "hd720"
      // Without Premium YouTube still serves up to 4K (VP9/AV1, decoded in hardware);
      // the video falls back to its best if it has less.
      let qualities = [
        ("auto", L("Automática", "Auto")), ("hd720", "720p"), ("hd1080", "1080p"),
        ("hd1440", "1440p (2K)"), ("hd2160", "2160p (4K)"), ("max", L("Máxima", "Maximum")),
      ].map { value, title in
        UIAction(title: title, state: value == currentQuality ? .on : .off) { [weak self] _ in
          defaults.set(value, forKey: DefaultsKey.quality)
          self?.runOnPlayback("quality('\(value)')")
        }
      }
      let saverOn = defaults.object(forKey: DefaultsKey.dataSaver) as? Bool ?? true
      let saver = UIAction(
        title: L("Ahorro de datos", "Data saver"),
        subtitle: onCellular ? L("480p con datos móviles · ahora activo", "480p on mobile data · on now") : L("480p con datos móviles", "480p on mobile data"),
        image: UIImage(systemName: "antenna.radiowaves.left.and.right"),
        state: saverOn ? .on : .off
      ) { [weak self] _ in
        defaults.set(!saverOn, forKey: DefaultsKey.dataSaver)
        self?.runOnPlayback("saver(\(!saverOn))")
      }
      children.append(
        UIMenu(
          title: L("Calidad", "Quality"), image: UIImage(systemName: "sparkles.tv"),
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

  private func showAirPlayPicker() {
    routePicker.subviews.compactMap { $0 as? UIButton }.first?.sendActions(for: .touchUpInside)
  }

  private func share(_ url: URL) {
    let sheet = UIActivityViewController(activityItems: [url], applicationActivities: nil)
    sheet.popoverPresentationController?.sourceView = moreButton
    present(sheet, animated: true)
  }
}
