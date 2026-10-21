import AVFoundation
import Speech
import UIKit

/// The app's own search: opens instantly with the keyboard up, lists recent searches,
/// suggests as you type (YouTube's public suggestion endpoint), and can listen (the mic
/// in the search bar, or holding 🔍 in the capsule).
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

  /// Suggestions for the text being typed; empty text shows the recent searches instead.
  private var suggestions: [String] = []
  private var suggestionTask: URLSessionDataTask?
  private var suggestionDelay: Timer?
  private var showingSuggestions: Bool { !(searchBar.text ?? "").trimmingCharacters(in: .whitespaces).isEmpty }

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
    if #available(iOS 26.0, *) {
      // See-through, so the sheet shows iOS's own Liquid Glass with the page behind it.
      tableView.backgroundColor = .clear
    }
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

  func searchBar(_ searchBar: UISearchBar, textDidChange searchText: String) {
    suggestionDelay?.invalidate()
    suggestionTask?.cancel()
    let query = searchText.trimmingCharacters(in: .whitespaces)
    guard !query.isEmpty else {
      suggestions = []
      tableView.reloadData()
      return
    }
    // A short pause between keystrokes before asking, so typing fast sends one request.
    suggestionDelay = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: false) { [weak self] _ in
      MainActor.assumeIsolated { self?.fetchSuggestions(for: query) }
    }
  }

  private func fetchSuggestions(for query: String) {
    var url = URLComponents(string: "https://suggestqueries.google.com/complete/search")!
    url.queryItems = [
      URLQueryItem(name: "client", value: "firefox"),
      URLQueryItem(name: "ds", value: "yt"),
      URLQueryItem(name: "hl", value: deviceIsSpanish ? "es" : "en"),
      URLQueryItem(name: "q", value: query),
    ]
    guard let requestURL = url.url else { return }
    // Response: ["query", ["suggestion", ...], ...]
    suggestionTask = URLSession.shared.dataTask(with: requestURL) { [weak self] data, _, _ in
      guard let data,
        let json = try? JSONSerialization.jsonObject(with: data) as? [Any],
        json.count > 1, let list = json[1] as? [String]
      else { return }
      DispatchQueue.main.async {
        guard let self, self.searchBar.text?.trimmingCharacters(in: .whitespaces) == query else { return }
        self.suggestions = Array(list.prefix(10))
        self.tableView.reloadData()
      }
    }
    suggestionTask?.resume()
  }

  func searchBarBookmarkButtonClicked(_ searchBar: UISearchBar) {
    listening ? stopListening() : listen()
  }

  // MARK: Recent searches and suggestions

  private var rows: [String] { showingSuggestions ? suggestions : recents }

  override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
    rows.count
  }

  override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
    showingSuggestions || recents.isEmpty ? nil : L("Recientes", "Recent")
  }

  override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
    let cell = tableView.dequeueReusableCell(withIdentifier: "recent", for: indexPath)
    var content = cell.defaultContentConfiguration()
    content.text = rows[indexPath.row]
    content.image = UIImage(systemName: showingSuggestions ? "magnifyingglass" : "clock.arrow.circlepath")
    cell.contentConfiguration = content
    if #available(iOS 26.0, *) { cell.backgroundColor = .clear }
    // Suggestions: the arrow puts the text in the bar to keep typing, like YouTube.
    if showingSuggestions {
      let fill = UIButton(type: .system)
      fill.setImage(UIImage(systemName: "arrow.up.left"), for: .normal)
      fill.tintColor = .secondaryLabel
      fill.frame = CGRect(x: 0, y: 0, width: 36, height: 36)
      let text = rows[indexPath.row]
      fill.addAction(
        UIAction { [weak self] _ in
          guard let self else { return }
          self.searchBar.text = text + " "
          self.searchBar(self.searchBar, textDidChange: text)
        }, for: .touchUpInside)
      cell.accessoryView = fill
    } else {
      cell.accessoryView = nil
    }
    return cell
  }

  override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
    submit(rows[indexPath.row])
  }

  override func tableView(_ tableView: UITableView, canEditRowAt indexPath: IndexPath) -> Bool {
    !showingSuggestions
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
