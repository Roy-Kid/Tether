import Foundation
import Tether

/// One row. The port is the one on the far side; `localPort` is where this
/// device is listening, when a forward exists.
struct PortRow: Identifiable, Equatable {
  var port: UInt16
  var name: String
  var localPort: UInt16?
  var alreadyLocal = false
  var forwarded = false
  var error: String?
  var misses = 0

  var id: UInt16 { port }

  var label: String {
    guard let localPort, localPort != port else { return String(port) }
    return "\(port) → \(localPort)"
  }
}

/// What the table asks of a lease. Tests hand it a fake; the tab hands it
/// the session's connection.
@MainActor
protocol PortLease: AnyObject {
  var leaseID: UInt64 { get }
  func forward(port: UInt16) async throws -> HeardForward
  func stop(port: UInt16)
  func scan() async throws -> String
}

/// The session's own connection. The first wrapper is kept: it is the one
/// whose listeners are alive. A later wrapper of the same lease is not.
@MainActor
final class LiveLease: PortLease {
  let connection: RemoteConnection
  var leaseID: UInt64 { connection.leaseID() }

  init(_ connection: RemoteConnection) { self.connection = connection }

  func forward(port: UInt16) async throws -> HeardForward {
    let forwarded = try await connection.forwardPort(port)
    return HeardForward(localPort: forwarded.localPort, alreadyLocal: forwarded.alreadyLocal)
  }

  func stop(port: UInt16) { connection.stopForward(port) }

  func scan() async throws -> String {
    let output = try await connection.execute(PortScan.command)
    guard output.status == 0 else {
      let err = String(data: output.stderr, encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      throw PortScanFailure(message: err.isEmpty ? "the scan failed" : String(err.prefix(180)))
    }
    guard let text = String(data: output.stdout, encoding: .utf8) else { throw PortScanFailure() }
    return text
  }
}

struct PortScanFailure: Error, LocalizedError {
  var message = "the scan failed"
  var errorDescription: String? { message }
}

/// One host's ports, shared by every tab on that host.
@MainActor
@Observable
final class PortTable {
  private(set) var rows: [PortRow] = []
  private(set) var scanning = false
  private(set) var scanFailed = false
  private(set) var problem: String?
  private var lease: any PortLease
  private var dismissed: Set<UInt16> = []
  private var poll: Task<Void, Never>?
  /// The wait between two scans, cut short when the list comes on screen.
  private var nap: Task<Void, Never>?
  private var closed = false
  private var polls = false
  /// How many lists of this table are on screen.
  private var viewers = 0
  private(set) var interval = Cadence.quickest

  /// A scan is a command run on the far side, so it is not run more often
  /// than what it finds changes: soon after a change, then less and less
  /// often while the ports stay as they were.
  enum Cadence {
    static let quickest: Duration = .seconds(3)
    static let slowest: Duration = .seconds(30)
  }

  init(lease: any PortLease) { self.lease = lease }

  func startPolling() {
    polls = true
    guard poll == nil, !closed else { return }
    poll = Task { [weak self] in
      while !Task.isCancelled {
        guard let pause = await self?.pollOnce() else { return }
        let nap = Task { _ = try? await Task.sleep(for: pause) }
        self?.nap = nap
        await nap.value
      }
    }
  }

  /// One turn of the poll: the wait before the next, or `nil` to stop.
  ///
  /// With nobody looking and nothing to forward on its own, a scan would
  /// only refresh a list no one sees, so polling stops until it is shown.
  /// Forwarding automatically keeps it going: a server started with the
  /// panel closed is still forwarded.
  func pollOnce(defaults: UserDefaults = .standard) async -> Duration? {
    guard !closed, viewers > 0 || PortsPreferences.automatic(defaults) else {
      poll = nil
      return nil
    }
    let changed = await scanOnce(defaults: defaults)
    interval = changed ? Cadence.quickest : min(interval * 2, Cadence.slowest)
    return interval
  }

  /// A list came on screen: scan now, and quickly again after.
  func shown() {
    viewers += 1
    interval = Cadence.quickest
    if poll == nil {
      if polls { startPolling() }
    } else {
      nap?.cancel()
    }
  }

  func hidden() {
    viewers = max(0, viewers - 1)
  }

  /// A redial is a new lease. The same id keeps the wrapper that owns the
  /// listeners; replacing it would drop them.
  func adopt(_ next: any PortLease) async {
    guard next.leaseID != lease.leaseID else { return }
    await stopForwarded()
    rows = []
    dismissed = []
    lease = next
    await scanOnce()
  }

  func refresh() async { await scanOnce() }

  /// Whether the list changed. A failed scan changes nothing.
  @discardableResult
  func scanOnce(defaults: UserDefaults = .standard) async -> Bool {
    guard !closed, !scanning else { return false }
    scanning = true
    defer { scanning = false }
    let text: String
    do { text = try await lease.scan() } catch {
      scanFailed = true
      problem = (error as? LocalizedError)?.errorDescription ?? "the scan failed"
      return false
    }
    guard let heard = PortScan.parse(text) else {
      scanFailed = true
      problem = "the scan failed"
      return false
    }
    if scanFailed { scanFailed = false }
    if problem != nil { problem = nil }
    guard !closed else { return false }

    let ignore = PortsPreferences.ignored(defaults)
    let automatic = PortsPreferences.automatic(defaults)
    var next: [PortRow] = []
    var seen = Set<UInt16>()

    for item in heard where !ignore.contains(item.port) && !dismissed.contains(item.port) {
      seen.insert(item.port)
      var row = rows.first { $0.port == item.port } ?? PortRow(port: item.port, name: item.name)
      row.name = item.name
      row.misses = 0
      next.append(row)
    }

    for var row in rows where !seen.contains(row.port) {
      row.misses += 1
      if row.misses >= 2 {
        if row.forwarded { lease.stop(port: row.port) }
      } else {
        next.append(row)
      }
    }

    next.sort { $0.port < $1.port }
    // Show the ports before asking for forwards. A forward that waits would
    // otherwise leave the column empty for the whole scan. Assigned only
    // when different: every assignment redraws every list watching it.
    let changed = next != rows
    if changed { rows = next }
    guard automatic, !closed else { return changed }
    for port in next.map(\.port) {
      guard !closed else { return changed }
      guard let row = rows.first(where: { $0.port == port }), !row.forwarded else { continue }
      await forward(port)
    }
    return changed
  }

  func forward(_ port: UInt16) async {
    guard let index = rows.firstIndex(where: { $0.port == port }) else { return }
    rows[index] = await applyForward(rows[index])
  }

  func close(_ port: UInt16) {
    dismissed.insert(port)
    if let row = rows.first(where: { $0.port == port }), row.forwarded {
      lease.stop(port: port)
    }
    rows.removeAll { $0.port == port }
  }

  func shutdown() {
    closed = true
    poll?.cancel()
    poll = nil
    nap?.cancel()
    for row in rows where row.forwarded {
      lease.stop(port: row.port)
    }
    rows = []
  }

  private func applyForward(_ row: PortRow) async -> PortRow {
    var row = row
    do {
      let forwarded = try await lease.forward(port: row.port)
      if closed {
        lease.stop(port: row.port)
        return row
      }
      row.localPort = forwarded.localPort
      row.alreadyLocal = forwarded.alreadyLocal
      row.forwarded = true
      row.error = nil
    } catch {
      let text = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
      row.error = text.isEmpty ? "the port was not forwarded" : text
    }
    return row
  }

  private func stopForwarded() async {
    for row in rows where row.forwarded {
      lease.stop(port: row.port)
    }
  }
}

/// Tabs on one host share a table, so two of them do not bind the same port.
@MainActor
enum PortTables {
  private static var tables: [UUID: PortTable] = [:]
  private static var counts: [UUID: Int] = [:]

  static func retain(host: UUID, lease: any PortLease, polling: Bool = true) -> PortTable {
    if let table = tables[host] {
      counts[host, default: 1] += 1
      return table
    }
    let table = PortTable(lease: lease)
    tables[host] = table
    counts[host] = 1
    if polling { table.startPolling() }
    return table
  }

  static func release(host: UUID) {
    guard let count = counts[host] else { return }
    if count > 1 {
      counts[host] = count - 1
      return
    }
    tables[host]?.shutdown()
    tables[host] = nil
    counts[host] = nil
  }
}
