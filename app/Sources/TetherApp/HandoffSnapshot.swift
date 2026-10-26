import Foundation

/// One device's open workspace, named by host id.
///
/// The other device looks the host up in its own library and dials itself.
/// A key path, a password and a one-time-code seed never appear here.
struct HandoffSnapshot: Codable, Equatable {
  struct Terminal: Codable, Equatable {
    var id: UUID
    var name: String
    var pinnedName: String?
    var directory: String?
    var index: Int
    var attachments: [ClosedTerminal.Attachment]
  }

  struct Page: Codable, Equatable {
    var hostID: UUID
    var name: String
    var focused: UUID
    var layout: WorkspaceSplit?
    var terminals: [Terminal]

    static func captured(_ record: ClosedTerminal) -> Page {
      Page(
        hostID: record.host.id, name: record.workspaceName ?? record.name,
        focused: record.focusedTerminal ?? record.id, layout: record.layout,
        terminals: record.members.map {
          Terminal(id: $0.id, name: $0.name, pinnedName: $0.pinnedName, directory: $0.directory,
            index: $0.index, attachments: $0.attachments)
        })
    }

    /// The receiver's own host record, with the sender's terminal ids kept
    /// so the layout can be remapped onto the new sessions.
    func record(host: Host) -> ClosedTerminal? {
      guard let head = terminals.first else { return nil }
      var record = ClosedTerminal(
        id: head.id, host: host, name: head.name, pinnedName: head.pinnedName, directory: head.directory,
        index: head.index, attachments: head.attachments)
      let rest = terminals.dropFirst().map {
        ClosedTerminal(
          id: $0.id, host: host, name: $0.name, pinnedName: $0.pinnedName, directory: $0.directory,
          index: $0.index, attachments: $0.attachments)
      }
      record.companions = rest.isEmpty ? nil : rest
      record.workspaceName = name
      record.layout = layout
      record.focusedTerminal = focused
      return record
    }
  }

  var pages: [Page]
  /// Index into `pages` of the workspace that was in front.
  var selected: Int

  init(records: [ClosedTerminal], selected: Int) {
    pages = records.map(Page.captured)
    self.selected = selected
  }
}

/// A plugin restore the handoff queue applied, keyed by the new tab. Tests
/// read it; the window still restores through the existing path.
struct HandoffRestore: Equatable {
  var tab: UUID
  var pluginID: String
  var state: Data
}
