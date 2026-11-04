import Foundation
import Testing

@testable import PortsPlugin

@MainActor
@Suite("one forward per host")
struct PortTableTests {
  @Test("two tabs of one host bind a port once")
  func shared() async {
    let host = UUID()
    let lease = FakeLease()
    let first = PortTables.retain(host: host, lease: lease, polling: false)
    let second = PortTables.retain(host: host, lease: lease, polling: false)
    defer {
      PortTables.release(host: host)
      PortTables.release(host: host)
    }
    #expect(first === second)
    lease.text = "8000\tmolab"
    await first.scanOnce(defaults: defaults(automatic: true))
    #expect(lease.forwards == [8000])
    await second.scanOnce(defaults: defaults(automatic: true))
    #expect(lease.forwards == [8000])
  }

  @Test("closing the last tab closes the listener")
  func lastTab() async {
    let host = UUID()
    let lease = FakeLease()
    let table = PortTables.retain(host: host, lease: lease, polling: false)
    lease.text = "8000\tmolab"
    await table.scanOnce(defaults: defaults(automatic: true))
    PortTables.release(host: host)
    #expect(lease.stops == [8000])
  }

  @Test("a port missing twice is dropped, and a closed one stays closed")
  func missesAndDismiss() async {
    let host = UUID()
    let lease = FakeLease()
    let table = PortTables.retain(host: host, lease: lease, polling: false)
    defer { PortTables.release(host: host) }
    let store = defaults(automatic: true)
    lease.text = "8000\tmolab\n9000\tother"
    await table.scanOnce(defaults: store)
    table.close(9000)
    #expect(lease.stops == [9000])
    lease.text = "8000\tmolab"
    await table.scanOnce(defaults: store)
    await table.scanOnce(defaults: store)
    #expect(table.rows.map(\.port) == [8000])
    lease.text = ""
    await table.scanOnce(defaults: store)
    #expect(table.rows.map(\.port) == [8000])
    await table.scanOnce(defaults: store)
    #expect(table.rows.isEmpty)
    lease.text = "9000\tother"
    await table.scanOnce(defaults: store)
    #expect(table.rows.isEmpty)
  }

  @Test("a redial drops the old forwards")
  func redial() async {
    let host = UUID()
    let lease = FakeLease()
    let table = PortTables.retain(host: host, lease: lease, polling: false)
    defer { PortTables.release(host: host) }
    lease.text = "8000\tmolab"
    await table.scanOnce(defaults: defaults(automatic: true))
    let next = FakeLease()
    next.leaseID = lease.leaseID + 1
    next.text = "8000\tmolab"
    await table.adopt(next)
    #expect(lease.stops == [8000])
    #expect(next.forwards == [8000])
  }

  private func defaults(automatic: Bool) -> UserDefaults {
    let store = UserDefaults(suiteName: "ports-\(UUID().uuidString)")!
    store.set(automatic, forKey: PortsPreferences.automaticKey)
    return store
  }
}

/// Set from an observation callback, which may run on any thread.
final class Flag: @unchecked Sendable {
  private let lock = NSLock()
  private var raised = false
  var value: Bool { lock.withLock { raised } }
  func set() { lock.withLock { raised = true } }
}

@MainActor
final class FakeLease: PortLease {
  var leaseID: UInt64 = 1
  var text = ""
  var failScan = false
  var taken: Set<UInt16> = []
  private(set) var forwards: [UInt16] = []
  private(set) var stops: [UInt16] = []

  func forward(port: UInt16) async throws -> HeardForward {
    forwards.append(port)
    let local = taken.contains(port) ? port + 1 : port
    return HeardForward(localPort: local, alreadyLocal: false)
  }

  func stop(port: UInt16) { stops.append(port) }

  func scan() async throws -> String {
    if failScan { throw PortScanFailure() }
    return text
  }
}
