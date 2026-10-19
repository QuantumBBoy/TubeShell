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
    do {
      try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [])
    } catch {
      NSLog("TubeShell: could not set audio session category: %@", "\(error)")
    }
    return true
  }
}
