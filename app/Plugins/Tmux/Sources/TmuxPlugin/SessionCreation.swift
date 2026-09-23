import Tether

/// A successful remote creation survives an attachment failure so Retry does
/// not create a duplicate session. No transport or view state lives here.
@MainActor
final class SessionCreation {
  private var pending: (name: String, session: TmuxSessionInfo)?

  func perform(
    name: String,
    create: (String) async throws -> TmuxSessionInfo,
    attach: (TmuxSessionInfo) async throws -> Void
  ) async throws -> TmuxSessionInfo {
    let session: TmuxSessionInfo
    if let pending, pending.name == name {
      session = pending.session
    } else {
      session = try await create(name)
      pending = (name, session)
    }
    try Task.checkCancellation()
    try await attach(session)
    try Task.checkCancellation()
    pending = nil
    return session
  }
}
