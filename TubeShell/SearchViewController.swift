import AVFoundation
import Speech
import UIKit

/// The app's own search: opens instantly with the keyboard up, lists recent searches,
/// and can listen (the mic in the search bar, or holding 🔍 in the capsule).
final class SearchViewController: UITableViewController, UISearchBarDelegate {

  private let searchTab: AppTab
  private let onSearch: (String) -> Void
  private let searchBar = UISearchBar()
  private var startListening: Bool
  private var recents: [String]
  private var recentsKey: String { DefaultsKey.recentSearches(searchTab) }

  // Dictation in the device language (falls back to Spanish if it has no recognizer).
  private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: Locale.preferredLanguages.first ?? "es-ES"))
    ?? SFSpeechRecognizer(locale: Locale(identifier: "es-ES"))
  private let audioEngine = AVAudioEngine()
  private var recognition: SFSpeechRecognitionTask?
  private var silenceTimer: Timer?

  init(tab: AppTab, startListening: Bool, onSearch: @escaping (String) -> Void) {
    self.searchTab = tab
    self.startListening = startListening
    self.onSearch = onSearch
    recents = UserDefaults.standard.stringArray(forKey: DefaultsKey.recentSearches(tab)) ?? []
    super.init(style: .plain)
  }

  required init?(coder: NSCoder) { fatalError() }

  override func viewDidLoad() {
    super.viewDidLoad()
    overrideUserInterfaceStyle = .dark
    searchBar.delegate = self
    searchBar.placeholder = searchTab.searchPlaceholder
    searchBar.showsBookmarkButton = true
    searchBar.setImage(UIImage(systemName: "mic.fill"), for: .bookmark, state: .normal)
    searchBar.returnKeyType = .search
    navigationItem.titleView = searchBar
    navigationItem.rightBarButtonItem = UIBarButtonItem(
      systemItem: .cancel, primaryAction: UIAction { [weak self] _ in self?.close() })
    tableView.register(UITableViewCell.self, forCellReuseIdentifier: "recent")
    tableView.keyboardDismissMode = .onDrag
  }

  /// Closed by swiping it down or tapping outside: the microphone stops, nothing is searched.
  override func viewWillDisappear(_ animated: Bool) {
    super.viewWillDisappear(animated)
    stopListening()
  }

  override func viewWillAppear(_ animated: Bool) {
    super.viewWillAppear(animated)
    if startListening {
      startListening = false
      listen()
    } else {
      searchBar.becomeFirstResponder()
    }
  }

  private func submit(_ text: String) {
    let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !query.isEmpty else { return }
    recents.removeAll { $0.caseInsensitiveCompare(query) == .orderedSame }
    recents.insert(query, at: 0)
    UserDefaults.standard.set(Array(recents.prefix(20)), forKey: recentsKey)
    stopListening()
    dismiss(animated: true)
    onSearch(query)
  }

  private func close() {
    stopListening()
    dismiss(animated: true)
  }

  func searchBarSearchButtonClicked(_ searchBar: UISearchBar) {
    submit(searchBar.text ?? "")
  }

  func searchBarBookmarkButtonClicked(_ searchBar: UISearchBar) {
    listening ? stopListening() : listen()
  }

  // MARK: Recent searches

  override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
    recents.count
  }

  override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
    recents.isEmpty ? nil : L("Recientes", "Recent")
  }

  override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
    let cell = tableView.dequeueReusableCell(withIdentifier: "recent", for: indexPath)
    var content = cell.defaultContentConfiguration()
    content.text = recents[indexPath.row]
    content.image = UIImage(systemName: "clock.arrow.circlepath")
    cell.contentConfiguration = content
    return cell
  }

  override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
    submit(recents[indexPath.row])
  }

  override func tableView(
    _ tableView: UITableView, commit editingStyle: UITableViewCell.EditingStyle, forRowAt indexPath: IndexPath
  ) {
    recents.remove(at: indexPath.row)
    UserDefaults.standard.set(recents, forKey: recentsKey)
    tableView.deleteRows(at: [indexPath], with: .automatic)
  }

  // MARK: Voice

  private func listen() {
    SFSpeechRecognizer.requestAuthorization { status in
      DispatchQueue.main.async {
        guard status == .authorized else { return self.voiceUnavailable() }
        AVAudioApplication.requestRecordPermission { granted in
          DispatchQueue.main.async { granted ? self.record() : self.voiceUnavailable() }
        }
      }
    }
  }

  private func voiceUnavailable() {
    searchBar.placeholder = L("Permite el micrófono en Ajustes › Tube", "Allow the microphone in Settings › Tube")
    searchBar.becomeFirstResponder()
  }

  private func record() {
    guard let recognizer, recognizer.isAvailable, !listening else { return voiceUnavailable() }
    AudioSession.configure(.playAndRecord, mode: .measurement, options: [.duckOthers, .defaultToSpeaker], activate: true)

    let request = SFSpeechAudioBufferRecognitionRequest()
    request.shouldReportPartialResults = true
    let input = audioEngine.inputNode
    input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0)) { buffer, _ in
      request.append(buffer)
    }
    audioEngine.prepare()
    listening = true  // the tap is installed: stopListening must remove it whatever happens
    do { try audioEngine.start() } catch { return stopListening() }

    searchBar.resignFirstResponder()
    searchBar.text = ""
    searchBar.placeholder = L("Escuchando…", "Listening…")
    searchBar.setImage(UIImage(systemName: "mic.circle.fill"), for: .bookmark, state: .normal)
    recognition = recognizer.recognitionTask(with: request) { result, error in
      DispatchQueue.main.async {
        guard self.listening else { return }  // closed meanwhile: no search
        if let result {
          self.searchBar.text = result.bestTranscription.formattedString
          // Search once the voice has stopped for a moment.
          self.silenceTimer?.invalidate()
          self.silenceTimer = Timer.scheduledTimer(withTimeInterval: result.isFinal ? 0 : 1.4, repeats: false) { _ in
            MainActor.assumeIsolated { self.submit(self.searchBar.text ?? "") }
          }
        } else if error != nil {
          self.stopListening()
        }
      }
    }
  }

  private var listening = false

  private func stopListening() {
    silenceTimer?.invalidate()
    silenceTimer = nil
    guard listening else { return }
    listening = false
    recognition?.cancel()
    recognition = nil
    audioEngine.stop()
    audioEngine.inputNode.removeTap(onBus: 0)
    // Back to the media player session (background audio).
    AudioSession.configure(.playback)
    searchBar.placeholder = searchTab.searchPlaceholder
    searchBar.setImage(UIImage(systemName: "mic.fill"), for: .bookmark, state: .normal)
  }
}
