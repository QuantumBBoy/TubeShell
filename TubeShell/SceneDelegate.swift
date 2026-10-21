import UIKit

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {

  var window: UIWindow?
  private var mainController: MainViewController?

  func scene(
    _ scene: UIScene,
    willConnectTo session: UISceneSession,
    options connectionOptions: UIScene.ConnectionOptions
  ) {
    guard let windowScene = scene as? UIWindowScene else { return }

    let controller = MainViewController()
    // Launched from a Home Screen quick action ("Abrir YouTube" / "Abrir Music").
    if let item = connectionOptions.shortcutItem, let tab = AppTab(shortcutType: item.type) {
      controller.initialTab = tab
    }

    let window = UIWindow(windowScene: windowScene)
    window.rootViewController = controller
    window.makeKeyAndVisible()
    self.window = window
    self.mainController = controller
    // Launched by a tube:// link.
    open(connectionOptions.urlContexts)
  }

  /// tube:// links (from Shortcuts, other apps or Safari's address bar).
  func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
    open(URLContexts)
  }

  private func open(_ contexts: Set<UIOpenURLContext>) {
    for context in contexts {
      if let page = ExternalLink.page(for: context.url) {
        ShortcutActions.send(.openLink(page))
      }
    }
  }

  // Quick action used while the app was already running in the background.
  func windowScene(
    _ windowScene: UIWindowScene,
    performActionFor shortcutItem: UIApplicationShortcutItem,
    completionHandler: @escaping (Bool) -> Void
  ) {
    guard let tab = AppTab(shortcutType: shortcutItem.type) else {
      completionHandler(false)
      return
    }
    mainController?.select(tab)
    completionHandler(true)
  }
}
