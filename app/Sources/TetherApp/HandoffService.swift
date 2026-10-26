import CryptoKit
import Foundation
import Network
import Observation
import Security

/// A paired device visible on the local link.
struct HandoffNeighbor: Identifiable, Equatable {
  var id: UUID
  var name: String
}

/// Finds a paired device nearby and hands it the open workspace.
///
/// TLS is attempted with a key both sides already share. A listener that
/// cannot start that way listens in the clear instead. Either way the
/// snapshot stays sealed with the handshake key: a TLS stand-in does not
/// get to read it, and nothing is sent before the peer's proof checks.
@MainActor
@Observable
final class HandoffService {
  static let serviceType = "_tether-handoff._tcp"

  private(set) var nearby: [HandoffNeighbor] = []
  /// Bumps when a snapshot arrives, so a window can restore it.
  private(set) var receivedToken = UUID()

  @ObservationIgnored private var archive: HandoffArchive
  @ObservationIgnored private weak var store: HostStore?
  @ObservationIgnored private var listener: NWListener?
  @ObservationIgnored private var browser: NWBrowser?
  @ObservationIgnored private var links: [HandoffLink] = []
  @ObservationIgnored private var endpoints: [UUID: NWEndpoint] = [:]
  @ObservationIgnored private var outbound: [UUID: HandoffSnapshot] = [:]
  @ObservationIgnored private var pending: HandoffSnapshot?
  @ObservationIgnored private var started = false
  @ObservationIgnored private var transportTLS = true

  init(archive: HandoffArchive = HandoffArchive()) {
    self.archive = archive
  }

  /// Idempotent. Does nothing until this device has an identity, and does
  /// not run from a store's initializer: tests build many stores.
  func start(_ store: HostStore) {
    self.store = store
    guard !started, store.handoffLocal() != nil else { return }
    started = true
    transportTLS = true
    listen()
    browse()
  }

  /// The account changed, so the name we advertise and the keys we accept
  /// have too. A service that was never started stays down.
  func refresh() {
    guard started, let store else { return }
    stop()
    start(store)
  }

  func takeReceived() -> HandoffSnapshot? {
    defer { pending = nil }
    return pending
  }

  func send(_ snapshot: HandoffSnapshot, to peer: UUID) {
    outbound[peer] = snapshot
    if let link = links.first(where: { $0.peerID == peer && $0.exchange.phase == .open }) {
      flush(peer, link: link)
    } else if !links.contains(where: { $0.peerID == peer }) {
      connect(to: peer, tls: transportTLS, fallback: true)
    }
  }

  private func stop() {
    started = false
    listener?.cancel()
    browser?.cancel()
    listener = nil
    browser = nil
    for link in links { link.connection.cancel() }
    links.removeAll()
    endpoints.removeAll()
    outbound.removeAll()
    nearby = []
  }

  private func listen() {
    guard let principal = store?.handoffLocal() else { return }
    let tls = transportTLS ? listenerSecurity(principal) : nil
    guard let listener = try? NWListener(using: parameters(security: tls)) else {
      fallBackToTCP()
      return
    }
    listener.service = NWListener.Service(name: principal.card.id.uuidString, type: Self.serviceType)
    listener.stateUpdateHandler = { [weak self] state in
      Task { @MainActor in self?.listenerChanged(state) }
    }
    listener.newConnectionHandler = { [weak self] connection in
      Task { @MainActor in self?.accept(connection) }
    }
    listener.start(queue: .main)
    self.listener = listener
  }

  private func listenerChanged(_ state: NWListener.State) {
    guard case .failed = state else { return }
    fallBackToTCP()
  }

  private func fallBackToTCP() {
    guard transportTLS else { return }
    transportTLS = false
    listener?.cancel()
    listener = nil
    listen()
  }

  private func browse() {
    let browser = NWBrowser(for: .bonjour(type: Self.serviceType, domain: nil), using: parameters(security: nil))
    browser.browseResultsChangedHandler = { [weak self] results, _ in
      let found = results.map(\.endpoint)
      Task { @MainActor in self?.apply(found) }
    }
    browser.start(queue: .main)
    self.browser = browser
  }

  private func apply(_ endpoints: [NWEndpoint]) {
    var neighbors: [HandoffNeighbor] = []
    var next: [UUID: NWEndpoint] = [:]
    for endpoint in endpoints {
      guard case .service(let name, _, _, _) = endpoint, let id = UUID(uuidString: name),
        let peer = store?.handoffPeer(id) else { continue }
      neighbors.append(HandoffNeighbor(id: id, name: peer.card.name))
      next[id] = endpoint
    }
    self.endpoints = next
    nearby = neighbors.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    for id in outbound.keys where !links.contains(where: { $0.peerID == id }) {
      connect(to: id, tls: transportTLS, fallback: true)
    }
  }

  private func accept(_ connection: NWConnection) {
    guard let principal = store?.handoffLocal() else {
      connection.cancel()
      return
    }
    let link = HandoffLink(connection: connection, exchange: HandoffExchange(principal: principal))
    links.append(link)
    arm(link)
    connection.start(queue: .main)
  }

  private func connect(to id: UUID, tls: Bool, fallback: Bool) {
    guard let endpoint = endpoints[id], let peer = store?.handoffPeer(id), let principal = store?.handoffLocal() else { return }
    let security = tls ? clientSecurity(principal, peer: peer.card) : nil
    let connection = NWConnection(to: endpoint, using: parameters(security: security))
    let link = HandoffLink(connection: connection, exchange: HandoffExchange(principal: principal))
    link.peerID = id
    link.fallbackToTCP = fallback && tls
    links.append(link)
    arm(link)
    connection.start(queue: .main)
  }

  private func arm(_ link: HandoffLink) {
    link.connection.stateUpdateHandler = { [weak self] state in
      Task { @MainActor in self?.link(link, changed: state) }
    }
  }

  private func link(_ link: HandoffLink, changed state: NWConnection.State) {
    switch state {
    case .ready:
      send(link.exchange.start(), on: link)
      receive(link)
    case .failed:
      let retry = link.fallbackToTCP ? link.peerID : nil
      drop(link)
      if let retry { connect(to: retry, tls: false, fallback: false) }
    case .cancelled:
      drop(link)
    default:
      break
    }
  }

  private func receive(_ link: HandoffLink) {
    link.connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, complete, error in
      Task { @MainActor in
        guard let self, self.links.contains(where: { $0 === link }) else { return }
        if let data { self.ingest(data, link: link) }
        if error != nil || complete || link.framerFailed {
          self.drop(link)
          return
        }
        self.receive(link)
      }
    }
  }

  private func ingest(_ data: Data, link: HandoffLink) {
    for wire in link.ingest(data) {
      switch link.exchange.receive(wire) {
      case .reply(let reply):
        send(reply, on: link)
        if reply.kind == "refuse" {
          link.connection.cancel()
          return
        }
      case .snapshot(let snapshot):
        deliver(snapshot)
      case .idle:
        break
      }
      if link.peerID == nil { link.peerID = link.exchange.acceptedID }
      if let id = link.peerID, link.exchange.phase == .open { flush(id, link: link) }
    }
  }

  private func deliver(_ snapshot: HandoffSnapshot) {
    archive.save(snapshot)
    pending = snapshot
    receivedToken = UUID()
  }

  private func flush(_ id: UUID, link: HandoffLink) {
    guard link.exchange.phase == .open, let snapshot = outbound.removeValue(forKey: id),
      let wire = link.exchange.seal(snapshot) else { return }
    send(wire, on: link)
  }

  private func send(_ wire: HandoffWire, on link: HandoffLink) {
    guard let framed = HandoffFramer.frame(wire) else { return }
    link.connection.send(content: framed, completion: .contentProcessed { _ in })
  }

  private func drop(_ link: HandoffLink) {
    links.removeAll { $0 === link }
  }

  private func parameters(security: NWProtocolTLS.Options?) -> NWParameters {
    let tcp = NWProtocolTCP.Options()
    tcp.noDelay = true
    let parameters = NWParameters(tls: security, tcp: tcp)
    parameters.includePeerToPeer = true
    return parameters
  }

  private func listenerSecurity(_ principal: HandoffPrincipal) -> NWProtocolTLS.Options? {
    let options = NWProtocolTLS.Options()
    var added = false
    for peer in principal.peers.values where !peer.revoked {
      guard let key = HandoffExchange.transportKey(local: principal.keys, peer: peer.card) else { continue }
      sec_protocol_options_add_pre_shared_key(
        options.securityProtocolOptions, dispatchData(key), dispatchData(Data(peer.card.id.uuidString.utf8)))
      added = true
    }
    guard added else { return nil }
    sec_protocol_options_set_peer_authentication_required(options.securityProtocolOptions, false)
    return options
  }

  private func clientSecurity(_ principal: HandoffPrincipal, peer: DeviceCard) -> NWProtocolTLS.Options? {
    guard let key = HandoffExchange.transportKey(local: principal.keys, peer: peer) else { return nil }
    let options = NWProtocolTLS.Options()
    sec_protocol_options_set_peer_authentication_required(options.securityProtocolOptions, false)
    sec_protocol_options_add_pre_shared_key(
      options.securityProtocolOptions, dispatchData(key), dispatchData(Data(principal.card.id.uuidString.utf8)))
    return options
  }

  private func dispatchData(_ key: SymmetricKey) -> dispatch_data_t {
    dispatchData(key.withUnsafeBytes { Data($0) })
  }

  /// `DispatchData` copies the bytes. Bridging yields the `dispatch_data_t`
  /// Security stores for the PSK; `dispatch_data_create` is unavailable.
  private func dispatchData(_ data: Data) -> dispatch_data_t {
    data.withUnsafeBytes { raw in
      DispatchData(bytes: raw)._bridgeToObjectiveC()
    }
  }
}

@MainActor
private final class HandoffLink {
  let connection: NWConnection
  let exchange: HandoffExchange
  var peerID: UUID?
  var fallbackToTCP = false
  private var framer = HandoffFramer()
  var framerFailed: Bool { framer.failed }

  init(connection: NWConnection, exchange: HandoffExchange) {
    self.connection = connection
    self.exchange = exchange
  }

  func ingest(_ data: Data) -> [HandoffWire] { framer.append(data) }
}
