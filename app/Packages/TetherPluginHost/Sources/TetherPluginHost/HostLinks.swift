import Foundation
#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

/// Opens a URL the manifest already named. The page never supplies the address.
@MainActor
enum HostLinks {
  static func open(_ url: URL) {
    #if canImport(AppKit)
    NSWorkspace.shared.open(url)
    #elseif canImport(UIKit)
    UIApplication.shared.open(url)
    #endif
  }
}
