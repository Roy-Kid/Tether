import Foundation

extension HostStore {
  /// When keeping a one-time-code seed stopped also setting the host to ask
  /// for approval before every login (3f00388). Before then, a host with a
  /// seed asked because the seed was kept, not because anyone chose it.
  static let seedStoppedForcingConfirmation = Date(timeIntervalSince1970: 1_791_914_677)

  /// Undoes, once, what keeping a seed set behind someone's back: a host
  /// with a seed, asking before authentication, last changed before the fix.
  /// The host is changed now, so it is never a candidate again and the
  /// change wins on every other device; one chosen since then stays.
  func undoConfirmationForcedBySeed() {
    let forced = snapshot.records.filter { _, record in Self.confirmationForcedBySeed(record) }.map(\.key)
    guard !forced.isEmpty else { return }
    do {
      try update { state in
        for id in forced {
          guard var record = state.records[id] else { continue }
          record.profile.authentication.confirmation = .automatic
          record.profile.modified = Date()
          record.dirty = true
          state.records[id] = record
          state.approvals[id] = record.profile.securityDigest
        }
      }
    } catch { recordProblem(error) }
  }

  private static func confirmationForcedBySeed(_ record: SharedHostRecord) -> Bool {
    let authentication = record.profile.authentication
    return !record.deleted && record.conflicts.isEmpty && authentication.otp != nil
      && authentication.confirmation == .confirmAuthentication
      && (record.profile.modified ?? .distantPast) < seedStoppedForcingConfirmation
  }
}
