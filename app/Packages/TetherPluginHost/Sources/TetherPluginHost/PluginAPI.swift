import Foundation
import Observation
import TetherPluginKit
import UserNotifications

public struct PluginNote: Identifiable, Equatable, Sendable {
  public let id: UUID
  public var title: String
  public var body: String
}

/// One implementation of the plugin contract. A page's RPC and a native
/// ``PluginServices`` call both land here. The host draws what it asks for.
@MainActor @Observable
public final class PluginAPI: PluginServing {
  public private(set) var notes: [PluginNote] = []
  /// Set while the app is not the frontmost scene, so a note is also posted
  /// to the system as a notification from this app.
  public var deliversSystemNotes = false
  public var onStatus: ((String, PluginStatusBarItem) -> Void)?

  let consent: any ConsentAsking
  private let presenting: (any PluginPresenting)?
  private var storage: [String: [String: String]] = [:]
  private var storageAsked: [String: Bool] = [:]
  weak var gateway: CapabilityGateway?

  public init(consent: any ConsentAsking, presenting: (any PluginPresenting)? = nil) {
    self.consent = consent
    self.presenting = presenting
    PluginGateway.current = self
  }

  public func services(pluginID: String, pluginName: String) -> PluginServices {
    PluginServices(pluginID: pluginID, pluginName: pluginName)
  }

  public func dismiss(_ id: UUID) {
    notes.removeAll { $0.id == id }
  }

  public func notify(title: String, body: String) async {
    if let presenting {
      await presenting.notify(title: title, body: body)
      return
    }
    let note = PluginNote(id: UUID(), title: String(title.prefix(120)), body: String(body.prefix(240)))
    notes.insert(note, at: 0)
    if notes.count > 4 { notes.removeLast(notes.count - 4) }
    if deliversSystemNotes { await SystemNote.post(title: note.title, body: note.body) }
  }

  public func ask(_ prompt: PluginPrompt) async -> PluginAnswer {
    if let presenting { return await presenting.ask(prompt) }
    return await PluginDialogs.ask(prompt)
  }

  public func storageGet(pluginID: String, pluginName: String, key: String) async throws -> String? {
    try await allowStorage(pluginID: pluginID, pluginName: pluginName)
    guard !key.isEmpty, key.count <= 256 else { throw PluginServiceError.malformed }
    return storage[pluginID]?[key]
  }

  public func storageSet(pluginID: String, pluginName: String, key: String, value: String) async throws {
    try await allowStorage(pluginID: pluginID, pluginName: pluginName)
    guard !key.isEmpty, key.count <= 256, value.utf8.count <= 64 * 1024 else { throw PluginServiceError.malformed }
    store(pluginID: pluginID, key: key, value: value)
  }

  public func readDocument(pluginID: String, handle: UUID) async throws -> Data {
    guard let gateway else { throw PluginServiceError.unavailable }
    return try await gateway.read(pluginID: pluginID, handle: handle)
  }

  public func openStream(pluginID: String, url: URL) async throws -> UUID {
    guard let gateway else { throw PluginServiceError.unavailable }
    return try await gateway.open(pluginID: pluginID, url: url)
  }

  public func closeStream(pluginID: String, id: UUID) async {
    await gateway?.close(pluginID: pluginID, stream: id)
  }

  public func reportStatus(pluginID: String, item: PluginStatusBarItem) {
    onStatus?(pluginID, item)
  }

  func stored(pluginID: String, key: String) -> String? { storage[pluginID]?[key] }

  func store(pluginID: String, key: String, value: String) {
    var bucket = storage[pluginID] ?? [:]
    bucket[key] = value
    storage[pluginID] = bucket
  }

  func wipe(pluginID: String) {
    storage[pluginID] = nil
    storageAsked[pluginID] = nil
  }

  private func allowStorage(pluginID: String, pluginName: String) async throws {
    if let allowed = storageAsked[pluginID] {
      if !allowed { throw PluginServiceError.denied }
      return
    }
    let allowed = await consent.ask(pluginName: pluginName.isEmpty ? pluginID : pluginName, permission: .storagePlugin)
    storageAsked[pluginID] = allowed
    if !allowed { throw PluginServiceError.denied }
  }
}

/// notify and ask, when a test or a caller wants to see them without drawing.
@MainActor
public protocol PluginPresenting: AnyObject {
  func notify(title: String, body: String) async
  func ask(_ prompt: PluginPrompt) async -> PluginAnswer
}

enum SystemNote {
  static func post(title: String, body: String) async {
    let center = UNUserNotificationCenter.current()
    let settings = await center.notificationSettings()
    switch settings.authorizationStatus {
    case .notDetermined:
      guard (try? await center.requestAuthorization(options: [.alert, .sound])) == true else { return }
    case .authorized, .provisional, .ephemeral:
      break
    default:
      return
    }
    let content = UNMutableNotificationContent()
    content.title = title
    if !body.isEmpty { content.body = body }
    let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
    try? await center.add(request)
  }
}
