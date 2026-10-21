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
    // Music with a song in the mini player when the app was closed: reopen the song (it
    // folds itself and the page it was on comes back, see musicReturnPath).
    if self == .music, let song = lastMusicSong, Self.musicReturnPath != nil {
      return URL(string: "https://music.youtube.com/watch?v=\(song)")!
    }
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

  /// The last song heard in Music (saved with its second while it plays, also folded).
  private var lastMusicSong: String? {
    guard let saved = UserDefaults.standard.dictionary(forKey: AppTab.music.lastPositionKey),
      let id = saved["v"] as? String,
      id.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" })
    else { return nil }
    return id
  }

  /// The Music page that was showing under the folded song (path and query), or nil when
  /// it was the song itself or home.
  static var musicReturnPath: String? {
    guard let saved = UserDefaults.standard.string(forKey: AppTab.music.lastURLKey),
      let url = URLComponents(string: saved), url.host == "music.youtube.com",
      url.path != "/watch", url.path != "/", !url.path.isEmpty
    else { return nil }
    return url.path + (url.percentEncodedQuery.map { "?" + $0 } ?? "")
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

/// The app's own labels follow the device language: Spanish, else English.
let deviceIsSpanish = Locale.preferredLanguages.first?.hasPrefix("es") == true

func L(_ spanish: String, _ english: String) -> String {
  deviceIsSpanish ? spanish : english
}
