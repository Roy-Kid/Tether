/// What one login has answered, so a question that comes back is read as an
/// answer refused.
///
/// keyboard-interactive has no "that was wrong": a server that refuses an
/// answer starts the exchange again, and the question it asked first is
/// asked again. Whatever was answered last before that is what it refused —
/// a saved password, or the code a person just typed — and the difference
/// decides who is asked next. A refused saved answer is never sent again;
/// sending it again, silently, until the server gave up is how a login that
/// only needed a person reached nobody.
///
/// A server can also ask for everything before saying no — a password step
/// that is *required* rather than *requisite* still asks for the code — so a
/// refusal is not always the last answer's fault. The first time, the last
/// answer is blamed; the second time, every saved answer in the exchange is
/// suspect too, and the person is asked for it.
struct ChallengeHistory {
  enum Source: Equatable {
    /// Typed by the person, just now.
    case person
    /// Filled in by this device: a password given before connecting, or a
    /// one-time code from a stored secret.
    case saved
  }

  /// Rounds answered since the server last started over, by prompt title.
  private var exchange: [[String: Source]] = []
  /// The round the server refused, until its question has been asked again.
  private var refused: [String: Source]?
  /// Titles whose saved answer was refused. Not offered again in this login.
  private var refusedSaved: Set<String> = []
  /// Saved answers demoted without being singled out, until asked again.
  private var suspect: Set<String> = []
  private var restarts = 0

  /// A new round. A title already answered in this exchange means the
  /// server started over.
  mutating func begin(_ titles: [String]) {
    guard titles.contains(where: { title in exchange.contains { $0[title] != nil } }) else { return }
    restarts += 1
    refused = exchange.last
    for (title, source) in refused ?? [:] where source == .saved {
      refusedSaved.insert(title)
    }
    if restarts > 1 {
      for round in exchange {
        for (title, source) in round where source == .saved && refused?[title] == nil {
          refusedSaved.insert(title)
          suspect.insert(title)
        }
      }
    }
    exchange = []
  }

  /// Whether this device may answer `title` for the person.
  func maySave(_ title: String) -> Bool {
    !refusedSaved.contains(title)
  }

  /// The one line a question carries when it is being asked again.
  func notice(for titles: [String]) -> String? {
    if let refused, titles.contains(where: { refused[$0] != nil }) {
      if refused.count == 1, let title = refused.keys.first { return "\(title) was not accepted." }
      return "Not accepted."
    }
    return titles.contains(where: suspect.contains) ? "Not accepted." : nil
  }

  mutating func record(_ round: [String: Source]) {
    exchange.append(round)
    // One line per refusal: whichever question carried it has said it.
    if let refused, round.keys.contains(where: { refused[$0] != nil || suspect.contains($0) }) {
      self.refused = nil
    }
    suspect.subtract(round.keys)
  }
}
