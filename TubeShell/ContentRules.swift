import CryptoKit
@preconcurrency import WebKit

/// Compiles the bundled ContentRules.json into a native WebKit rule list.
/// These are the network rules (the declarative layer of Brave Shields).
enum ContentRules {

  /// The compiled list is kept on disk by WebKit under an identifier that includes a hash
  /// of the JSON: unchanged rules are looked up (fast), edited rules are compiled once.
  @MainActor
  static func compile() async -> WKContentRuleList? {
    guard
      let url = Bundle.main.url(forResource: "ContentRules", withExtension: "json"),
      let data = try? Data(contentsOf: url),
      let json = String(data: data, encoding: .utf8)
    else {
      NSLog("TubeShell: ContentRules.json not found in the app bundle")
      return nil
    }

    let start = Date()
    defer { NSLog("TubeShell: content rules ready in %.0f ms", Date().timeIntervalSince(start) * 1000) }
    let hash = SHA256.hash(data: data).prefix(8).map { String(format: "%02x", $0) }.joined()
    let identifier = "\(identifierPrefix)-\(hash)"
    let store = WKContentRuleListStore.default()!

    let cached: WKContentRuleList? = await withCheckedContinuation { continuation in
      store.lookUpContentRuleList(forIdentifier: identifier) { list, _ in
        continuation.resume(returning: list)
      }
    }
    if let cached { return cached }

    let compiled: WKContentRuleList?
    do {
      compiled = try await store.compileContentRuleList(
        forIdentifier: identifier,
        encodedContentRuleList: json
      )
    } catch {
      NSLog("TubeShell: could not compile content rules: %@", "\(error)")
      return nil
    }

    // Drop lists compiled from older versions of the JSON.
    for old in await store.availableIdentifiers() ?? [] where old.hasPrefix(identifierPrefix) && old != identifier {
      try? await store.removeContentRuleList(forIdentifier: old)
    }
    return compiled
  }

  private static let identifierPrefix = "tubeshell-rules"
}
