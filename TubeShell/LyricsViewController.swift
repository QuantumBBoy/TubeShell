import UIKit
import WebKit

/// Synced lyrics for the song playing in Music, from LRCLIB (free, no account): the line
/// being sung lights up and stays in the middle; tapping a line jumps to it.
/// Only the song title, artist and length are sent to lrclib.net.
final class LyricsViewController: UITableViewController {

  private struct Line {
    let time: Double?  // nil: plain lyrics without times
    let text: String
  }

  private let page: WKWebView
  private var lines: [Line] = []
  private var current: Int?
  private var song: String?  // "title|artist" of the lyrics shown
  private var timer: Timer?
  private var lastDrag = Date.distantPast
  private let header = UILabel()
  private let status = UILabel()

  init(page: WKWebView) {
    self.page = page
    super.init(style: .plain)
  }

  required init?(coder: NSCoder) { fatalError() }

  override func viewDidLoad() {
    super.viewDidLoad()
    overrideUserInterfaceStyle = .dark
    tableView.backgroundColor = .black
    tableView.separatorStyle = .none
    tableView.register(UITableViewCell.self, forCellReuseIdentifier: "line")
    tableView.contentInset.top = 20

    header.font = .preferredFont(forTextStyle: .headline)
    header.textColor = .secondaryLabel
    header.textAlignment = .center
    header.numberOfLines = 2
    header.frame.size.height = 56
    tableView.tableHeaderView = header

    status.font = .preferredFont(forTextStyle: .title3)
    status.textColor = .secondaryLabel
    status.textAlignment = .center
    status.numberOfLines = 0
    status.text = L("Buscando la letra…", "Finding the lyrics…")
    tableView.backgroundView = status
  }

  override func viewWillAppear(_ animated: Bool) {
    super.viewWillAppear(animated)
    tick()
    timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated { self?.tick() }
    }
  }

  override func viewWillDisappear(_ animated: Bool) {
    super.viewWillDisappear(animated)
    timer?.invalidate()
    timer = nil
  }

  // MARK: Following the song

  private static let stateScript = """
    (() => {
      const p = document.getElementById('movie_player'), d = p && p.getVideoData && p.getVideoData();
      const m = navigator.mediaSession && navigator.mediaSession.metadata;
      const title = (m && m.title) || (d && d.title), artist = (m && m.artist) || (d && d.author) || '';
      return title && p && p.getCurrentTime ? [title, artist, p.getDuration() || 0, p.getCurrentTime()] : null;
    })()
    """

  private func tick() {
    page.evaluateJavaScript(Self.stateScript) { [weak self] result, _ in
      guard let self, let state = result as? [Any], state.count == 4,
        let title = state[0] as? String, let artist = state[1] as? String,
        let duration = (state[2] as? NSNumber)?.doubleValue,
        let time = (state[3] as? NSNumber)?.doubleValue
      else { return }
      let key = title + "|" + artist
      if key != self.song {
        self.song = key
        self.header.text = artist.isEmpty ? title : "\(title)\n\(artist)"
        self.load(title: title, artist: artist, duration: duration)
      }
      self.follow(time)
    }
  }

  private func follow(_ time: Double) {
    // The line whose time has come (lyrics shown a bit early read better).
    let index = lines.lastIndex { ($0.time ?? .infinity) <= time + 0.3 }
    guard index != current else { return }
    let changed = [current, index].compactMap { $0 }.map { IndexPath(row: $0, section: 0) }
    current = index
    tableView.reloadRows(at: changed.filter { $0.row < lines.count }, with: .none)
    // Leave the list alone for a few seconds after the user scrolls it.
    if let index, Date().timeIntervalSince(lastDrag) > 4 {
      tableView.scrollToRow(at: IndexPath(row: index, section: 0), at: .middle, animated: true)
    }
  }

  override func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
    lastDrag = Date()
  }

  override func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
    lastDrag = Date()
  }

  // MARK: LRCLIB

  private func load(title: String, artist: String, duration: Double) {
    lines = []
    current = nil
    tableView.reloadData()
    status.text = L("Buscando la letra…", "Finding the lyrics…")
    tableView.backgroundView = status
    let key = song
    Task { [weak self] in
      let found = await Self.lyrics(title: title, artist: artist, duration: duration)
      guard let self, self.song == key else { return }
      self.lines = found
      self.current = nil
      self.tableView.backgroundView = found.isEmpty ? self.status : nil
      self.status.text = L("No hay letra para esta canción", "No lyrics for this song")
      self.tableView.reloadData()
    }
  }

  /// Searches by title (without "(Official Video)" and the like) and artist, and keeps the
  /// synced lyrics whose length is closest to the song's; plain lyrics if none is synced.
  /// Very short entries are skipped: the database has some junk ones.
  private static func lyrics(title: String, artist: String, duration: Double) async -> [Line] {
    let cleanTitle = title.replacingOccurrences(of: "\\s*[\\(\\[][^\\)\\]]*[\\)\\]]", with: "", options: .regularExpression)
    var search = URLComponents(string: "https://lrclib.net/api/search")!
    search.queryItems = [
      URLQueryItem(name: "track_name", value: cleanTitle),
      URLQueryItem(name: "artist_name", value: artist),
    ]
    var results = await fetch(search.url)
    if results.isEmpty {
      search.queryItems = [URLQueryItem(name: "q", value: "\(cleanTitle) \(artist)")]
      results = await fetch(search.url)
    }
    let candidates = results.compactMap { entry -> (lines: [Line], gap: Double)? in
      guard let lines = parse(entry), lines.count >= 5 else { return nil }
      let gap = abs(((entry["duration"] as? NSNumber)?.doubleValue ?? 0) - duration)
      // Synced first, then the closest length.
      return (lines, (lines[0].time == nil ? 10_000 : 0) + gap)
    }
    return candidates.min { $0.gap < $1.gap }?.lines ?? []
  }

  /// The search answers a list of entries.
  private static func fetch(_ url: URL?) async -> [[String: Any]] {
    guard let url else { return [] }
    var request = URLRequest(url: url)
    request.setValue("Tube (github.com/QuantumBBoy/TubeShell)", forHTTPHeaderField: "User-Agent")
    guard let (data, response) = try? await URLSession.shared.data(for: request),
      (response as? HTTPURLResponse)?.statusCode == 200,
      let json = try? JSONSerialization.jsonObject(with: data)
    else { return [] }
    return json as? [[String: Any]] ?? []
  }

  /// "[01:23.45] text" lines; a line can carry several times (a repeated chorus).
  private static func parse(_ entry: [String: Any]) -> [Line]? {
    if let synced = entry["syncedLyrics"] as? String, !synced.isEmpty {
      let stamp = try! NSRegularExpression(pattern: "\\[(\\d+):(\\d+(?:\\.\\d+)?)\\]")
      var lines: [Line] = []
      for raw in synced.split(separator: "\n") {
        let raw = String(raw)
        let matches = stamp.matches(in: raw, range: NSRange(raw.startIndex..., in: raw))
        guard let last = matches.last, let end = Range(last.range, in: raw) else { continue }
        let text = raw[end.upperBound...].trimmingCharacters(in: .whitespaces)
        for match in matches {
          guard let minutes = Range(match.range(at: 1), in: raw).flatMap({ Double(raw[$0]) }),
            let seconds = Range(match.range(at: 2), in: raw).flatMap({ Double(raw[$0]) })
          else { continue }
          lines.append(Line(time: minutes * 60 + seconds, text: text.isEmpty ? "♪" : text))
        }
      }
      return lines.isEmpty ? nil : lines.sorted { $0.time! < $1.time! }
    }
    if let plain = entry["plainLyrics"] as? String, !plain.isEmpty {
      return plain.components(separatedBy: "\n").map { Line(time: nil, text: $0) }
    }
    return nil
  }

  // MARK: Table

  override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
    lines.count
  }

  override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
    let cell = tableView.dequeueReusableCell(withIdentifier: "line", for: indexPath)
    let line = lines[indexPath.row]
    var content = cell.defaultContentConfiguration()
    content.text = line.text
    let synced = line.time != nil
    content.textProperties.font = .systemFont(ofSize: synced ? 26 : 20, weight: .bold)
    content.textProperties.color = !synced || indexPath.row == current ? .white : UIColor(white: 1, alpha: 0.35)
    content.directionalLayoutMargins = .init(top: 8, leading: 24, bottom: 8, trailing: 24)
    cell.contentConfiguration = content
    cell.backgroundColor = .clear
    cell.selectionStyle = .none
    return cell
  }

  /// Tapping a synced line jumps the song there.
  override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
    guard let time = lines[indexPath.row].time else { return }
    UIImpactFeedbackGenerator(style: .light).impactOccurred()
    lastDrag = .distantPast
    page.evaluateJavaScript(
      "(p => p && p.seekTo ? p.seekTo(\(time), true) : (document.querySelector('video').currentTime = \(time)))(document.getElementById('movie_player'))"
    )
  }
}
