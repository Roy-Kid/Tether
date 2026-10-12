import SwiftUI
import TetherPluginKit

/// Ports, as a tab plugin: every terminal tab carries the loopback listeners
/// of the machine its shell is running on, kept in the inspector beside Files.
@MainActor
public final class PortsPlugin: TabPlugin {
  public static let id = "dev.tether.ports"
  public let metadata = PluginMetadata(
    id: PortsPlugin.id, name: "Ports", symbol: "network",
    summary:
      "Forwards this machine's own loopback ports to this device. On a phone, forwarding stops when Tether leaves the foreground."
  )
  public let accessory = TabAccessory(symbol: "network", name: "Ports", placement: .inspector)

  public init() {}

  public func attach(to tab: TabContext) -> any TabAttachment {
    let lease: any PortLease
    if let connection = tab.plugin.connection {
      lease = LiveLease(connection)
    } else {
      lease = IdleLease()
    }
    return PortsTab(hostID: tab.plugin.hostID, lease: lease)
  }

  public func settings() -> AnyView { AnyView(PortsSettings()) }
}

/// A tab that has no lease yet. The scan fails quietly and the list stays empty.
@MainActor
private final class IdleLease: PortLease {
  /// Not a session. A real lease id is never this, including a local shell's 0.
  let leaseID: UInt64 = .max
  func forward(port: UInt16) async throws -> HeardForward { throw PortScanFailure() }
  func stop(port: UInt16) {}
  func scan() async throws -> String { throw PortScanFailure() }
}
