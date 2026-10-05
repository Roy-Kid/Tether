import Foundation
import ImageIO
import QuickLook
import QuickLookThumbnailing
import SwiftUI
import UniformTypeIdentifiers

#if os(macOS)
  import AppKit
  import Quartz
#else
  import UIKit
#endif

/// Shows files in Quick Look, from wherever the request came from.
///
/// Not a SwiftUI modifier on the browser: a path clicked in the terminal
/// has to open whether or not the browser is on screen. On a Mac this is the
/// same panel Finder's space bar opens; on a phone, the full-screen viewer.
@MainActor
enum QuickLook {
  static func show(_ urls: [URL]) {
    guard !urls.isEmpty else { return }
    #if os(macOS)
      MacPanel.shared.show(urls)
    #else
      PhoneViewer.shared.show(urls)
    #endif
  }

  /// Whether the preview is on screen now.
  static var isShowing: Bool {
    #if os(macOS)
      QLPreviewPanel.sharedPreviewPanelExists() && QLPreviewPanel.shared().isVisible
    #else
      false
    #endif
  }

  static func hide() {
    #if os(macOS)
      if QLPreviewPanel.sharedPreviewPanelExists() { QLPreviewPanel.shared().orderOut(nil) }
    #endif
  }

  /// A thumbnail of a local file, or `nil` for a type Quick Look cannot draw.
  ///
  /// `.all` rather than `.thumbnail`: PDFs, source, and the plain-text
  /// tables a lab writes have no bitmap thumbnail, but Quick Look will
  /// still draw an icon or a generated representation if asked for one.
  static func thumbnail(of url: URL, side: CGFloat) async -> CGImage? {
    // Quick Look's generator caches by path and keeps the previous bitmap
    // after the file is replaced. An image is read from the bytes instead.
    if let image = imageThumbnail(of: url, side: side) { return image }
    let request = QLThumbnailGenerator.Request(
      fileAt: url, size: CGSize(width: side, height: side), scale: 2,
      representationTypes: .all)
    return try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request).cgImage
  }

  /// A thumbnail decoded from the file now. Nil when the type is not an
  /// image, or the bytes are not one.
  private static func imageThumbnail(of url: URL, side: CGFloat) -> CGImage? {
    let ext = url.pathExtension
    guard !ext.isEmpty, let type = UTType(filenameExtension: ext), type.conforms(to: .image) else {
      return nil
    }
    let reading: [CFString: Any] = [kCGImageSourceShouldCache: false]
    guard let source = CGImageSourceCreateWithURL(url as CFURL, reading as CFDictionary) else {
      return nil
    }
    let options: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceThumbnailMaxPixelSize: side * 2,
      kCGImageSourceShouldCacheImmediately: true,
      kCGImageSourceShouldCache: false,
    ]
    return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
  }
}

#if os(macOS)
  @MainActor
  private final class MacPanel: NSObject, @preconcurrency QLPreviewPanelDataSource {
    static let shared = MacPanel()
    private var urls: [URL] = []

    func show(_ urls: [URL]) {
      self.urls = urls
      guard let panel = QLPreviewPanel.shared() else { return }
      panel.dataSource = self
      panel.reloadData()
      panel.currentPreviewItemIndex = 0
      panel.makeKeyAndOrderFront(nil)
      panel.refreshCurrentPreviewItem()
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { urls.count }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
      urls[index] as NSURL
    }
  }
#else
  @MainActor
  private final class PhoneViewer: NSObject, QLPreviewControllerDataSource {
    static let shared = PhoneViewer()
    private var urls: [URL] = []

    func show(_ urls: [URL]) {
      self.urls = urls
      guard let top = topController() else { return }
      let viewer = QLPreviewController()
      viewer.dataSource = self
      top.present(viewer, animated: true)
    }

    func numberOfPreviewItems(in controller: QLPreviewController) -> Int { urls.count }

    func previewController(_ controller: QLPreviewController, previewItemAt index: Int)
      -> any QLPreviewItem
    {
      urls[index] as NSURL
    }

    /// What is on screen now: the window's root, or whatever it presented —
    /// the files sheet, when the request came from there.
    private func topController() -> UIViewController? {
      let window = UIApplication.shared.connectedScenes
        .compactMap { $0 as? UIWindowScene }
        .flatMap(\.windows)
        .first(where: \.isKeyWindow)
      var top = window?.rootViewController
      while let presented = top?.presentedViewController { top = presented }
      return top
    }
  }
#endif
