import Foundation
import Observation

/// Brief, replaceable feedback owned by the window where an action completed.
/// Views only read and announce it; expiration belongs to this model.
@MainActor @Observable
final class WindowFeedback {
  struct Message: Equatable, Identifiable {
    let id: UUID
    let title: String
    let symbol: String
    let isStruckThrough: Bool
    let accessibilityLabel: String
  }

  private var messages: [UUID: Message] = [:]
  @ObservationIgnored private var expirations: [UUID: Task<Void, Never>] = [:]
  @ObservationIgnored private let sleep: @MainActor (Duration) async throws -> Void

  init(sleep: @escaping @MainActor (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
    self.sleep = sleep
  }

  func message(for hostID: UUID) -> Message? { messages[hostID] }

  func show(title: String, symbol: String, isStruckThrough: Bool = false,
            accessibilityLabel: String? = nil, in hostID: UUID) {
    dismiss(in: hostID)
    let message = Message(id: UUID(), title: title, symbol: symbol,
      isStruckThrough: isStruckThrough, accessibilityLabel: accessibilityLabel ?? title)
    messages[hostID] = message
    let sleep = sleep
    expirations[hostID] = Task { [weak self] in
      do { try await sleep(.seconds(2)) }
      catch { return }
      // A cancelled timer may already have resumed. It must never dismiss
      // a replacement message, even if its sleeper ignored cancellation.
      guard self?.messages[hostID]?.id == message.id else { return }
      self?.dismiss(in: hostID)
    }
  }

  func dismiss(in hostID: UUID) {
    expirations.removeValue(forKey: hostID)?.cancel()
    messages.removeValue(forKey: hostID)
  }

  func dismissAll() {
    expirations.values.forEach { $0.cancel() }
    expirations.removeAll()
    messages.removeAll()
  }
}
