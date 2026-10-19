import Foundation

/// The two sites the app wraps. The raw value is also the tab bar index.
enum AppTab: Int, CaseIterable {
  case youtube = 0
  case music = 1

  var title: String {
    switch self {
    case .youtube: return "YouTube"
    case .music: return "Music"
    }
  }

  var symbolName: String {
    switch self {
    case .youtube: return "play.rectangle.fill"
    case .music: return "music.note"
    }
  }

  var homeURL: URL {
    switch self {
    case .youtube: return URL(string: "https://m.youtube.com/")!
    case .music: return URL(string: "https://music.youtube.com/")!
    }
  }

  /// Last page visited in this tab (saved by WebTab), so the app reopens where you were.
  var lastURLKey: String { "TubeShell.lastURL.\(rawValue)" }
  /// Second the last song or video was at: ["v": video id, "t": seconds].
  var lastPositionKey: String { "TubeShell.lastPosition.\(rawValue)" }

  /// The YouTube video that was open in the player (WebTab with isPlayer).
  static let lastPlayerURLKey = "TubeShell.lastPlayerURL"

  var startURL: URL {
    if let saved = UserDefaults.standard.string(forKey: lastURLKey),
      let url = URL(string: saved),
      AppTab.preferred(for: url) == self,
      // YouTube videos reopen in the player, over the list.
      !(self == .youtube && url.path == "/watch")
    {
      return url
    }
    return homeURL
  }

  /// Must match UIApplicationShortcutItemType in Info.plist.
  var shortcutType: String {
    switch self {
    case .youtube: return "tubeshell.youtube"
    case .music: return "tubeshell.music"
    }
  }

  init?(shortcutType: String) {
    guard let tab = AppTab.allCases.first(where: { $0.shortcutType == shortcutType }) else {
      return nil
    }
    self = tab
  }

  /// Which tab a link naturally belongs to, used to move links between tabs.
  static func preferred(for url: URL) -> AppTab? {
    guard let host = url.host?.lowercased() else { return nil }
    if host == "music.youtube.com" { return .music }
    if ["youtube.com", "www.youtube.com", "m.youtube.com", "youtu.be"].contains(host) {
      return .youtube
    }
    return nil
  }
}
