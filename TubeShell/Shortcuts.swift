import AppIntents

/// What a Siri / Shortcuts action asks the app to do once it is open.
enum ShortcutAction {
  case open(AppTab)
  case play
  case sleep(minutes: Int)
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
