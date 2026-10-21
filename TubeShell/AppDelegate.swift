import AVFoundation
import UIKit

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {

  func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    // Declare the app as a media player so iOS keeps the audio running
    // with the screen locked (paired with UIBackgroundModes = audio in Info.plist).
    AudioSession.configure(.playback)
    return true
  }
}

enum AudioSession {
  /// Sets the shared audio session's category (and activates it on request). A failure is
  /// logged, not fatal.
  static func configure(
    _ category: AVAudioSession.Category,
    mode: AVAudioSession.Mode = .default,
    options: AVAudioSession.CategoryOptions = [],
    activate: Bool = false
  ) {
    let session = AVAudioSession.sharedInstance()
    do {
      try session.setCategory(category, mode: mode, options: options)
    } catch {
      NSLog("TubeShell: could not set audio session category %@: %@", category.rawValue, "\(error)")
    }
    guard activate else { return }
    do {
      try session.setActive(true)
    } catch {
      NSLog("TubeShell: could not activate the audio session: %@", "\(error)")
    }
  }
}
