import AppIntents

/// What a Siri / Shortcuts action asks the app to do once it is open.
enum ShortcutAction {
  case open(AppTab)
  case play
  case sleep(minutes: Int)
  /// A YouTube or YouTube Music link opened from outside (share sheet shortcut, tube://,
  /// the copied-link banner).
  case openLink(URL)
}

/// A YouTube / YouTube Music address in any of the forms people share, as the page to load
/// in the app (m.youtube.com or music.youtube.com), or nil when it is something else.
/// Accepts tube://<link>, tube://watch?v=ID, youtu.be/ID, youtube.com, m., www., music.
enum ExternalLink {
  static func page(for url: URL) -> URL? {
    var url = url
    if url.scheme?.lowercased() == "tube" {
      // The link after tube://, with or without its own https:// (iOS may turn it into https//).
      let rest = url.absoluteString.dropFirst("tube:".count)
        .replacingOccurrences(of: "^/*(https?:?/*)?", with: "", options: .regularExpression)
      let startsWithHost = rest.split(separator: "/").first?.contains(".") == true
      guard let inner = URL(string: (startsWithHost ? "https://" : "https://m.youtube.com/") + rest) else { return nil }
      url = inner
    }
    guard let host = url.host?.lowercased(), url.scheme?.hasPrefix("http") == true else { return nil }
    var parts = URLComponents(url: url, resolvingAgainstBaseURL: false)
    parts?.scheme = "https"
    switch host {
    case "youtu.be":
      let id = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
      guard !id.isEmpty else { return nil }
      var watch = URLComponents(string: "https://m.youtube.com/watch")!
      watch.queryItems = [URLQueryItem(name: "v", value: id)] + (parts?.queryItems ?? [])
      return watch.url
    case "music.youtube.com":
      return parts?.url
    case "youtube.com", "www.youtube.com", "m.youtube.com":
      parts?.host = "m.youtube.com"
      // Shorts and live links play as normal videos, in the player.
      let path = url.path.split(separator: "/")
      if path.count == 2, path[0] == "shorts" || path[0] == "live" {
        parts?.path = "/watch"
        let query = parts?.queryItems ?? []
        parts?.queryItems = [URLQueryItem(name: "v", value: String(path[1]))] + query
      }
      return parts?.url
    default:
      return nil
    }
  }
}

/// Actions wait here until the main screen is ready to run them (cold launch).
@MainActor
enum ShortcutActions {
  static var handler: ((ShortcutAction) -> Void)? {
    didSet { flush() }
  }
  private static var pending: [ShortcutAction] = []

  static func send(_ action: ShortcutAction) {
    pending.append(action)
    flush()
  }

  private static func flush() {
    guard let handler else { return }
    let actions = pending
    pending = []
    actions.forEach(handler)
  }
}

struct PlayMusicIntent: AppIntent {
  static let title: LocalizedStringResource = "Poner mi música"
  static let openAppWhenRun = true

  @MainActor
  func perform() async throws -> some IntentResult {
    ShortcutActions.send(.play)
    return .result()
  }
}

struct OpenTabIntent: AppIntent {
  static let title: LocalizedStringResource = "Abrir pestaña"
  static let openAppWhenRun = true

  @Parameter(title: "Pestaña")
  var tab: TabChoice

  init() {}
  init(tab: TabChoice) { self.tab = tab }

  @MainActor
  func perform() async throws -> some IntentResult {
    ShortcutActions.send(.open(tab == .music ? .music : .youtube))
    return .result()
  }
}

enum TabChoice: String, AppEnum {
  case music, youtube
  static let typeDisplayRepresentation: TypeDisplayRepresentation = "Pestaña"
  static let caseDisplayRepresentations: [TabChoice: DisplayRepresentation] = [
    .music: "Music", .youtube: "YouTube",
  ]
}

struct SleepTimerIntent: AppIntent {
  static let title: LocalizedStringResource = "Temporizador para dormir"
  static let openAppWhenRun = true

  @Parameter(title: "Minutos", default: 30, inclusiveRange: (1, 240))
  var minutes: Int

  @MainActor
  func perform() async throws -> some IntentResult {
    ShortcutActions.send(.sleep(minutes: minutes))
    return .result()
  }
}

/// Phrases Siri understands without any setup; also listed in the Shortcuts app.
/// Shortcuts action "Open in Tube": takes a link (a share-sheet shortcut can pass the
/// page being shared) and opens it in the app.
struct OpenLinkIntent: AppIntent {
  static let title: LocalizedStringResource = "Abrir en Tube"
  static let description = IntentDescription("Abre un enlace de YouTube o YouTube Music en Tube.")
  static let openAppWhenRun = true

  @Parameter(title: "Enlace")
  var link: URL

  @MainActor
  func perform() async throws -> some IntentResult {
    if let page = ExternalLink.page(for: link) {
      ShortcutActions.send(.openLink(page))
    }
    return .result()
  }
}

struct TubeShortcuts: AppShortcutsProvider {
  static var appShortcuts: [AppShortcut] {
    AppShortcut(
      intent: PlayMusicIntent(),
      phrases: ["Pon mi música en \(.applicationName)", "Reanuda \(.applicationName)"],
      shortTitle: "Poner música",
      systemImageName: "play.fill"
    )
    AppShortcut(
      intent: OpenTabIntent(tab: .music),
      phrases: ["Abre Music en \(.applicationName)"],
      shortTitle: "Abrir Music",
      systemImageName: "music.note"
    )
    AppShortcut(
      intent: OpenTabIntent(tab: .youtube),
      phrases: ["Abre YouTube en \(.applicationName)"],
      shortTitle: "Abrir YouTube",
      systemImageName: "play.rectangle.fill"
    )
    AppShortcut(
      intent: SleepTimerIntent(),
      phrases: ["Temporizador de \(.applicationName)", "Apaga \(.applicationName) en un rato"],
      shortTitle: "Temporizador",
      systemImageName: "moon.zzz"
    )
  }
}
