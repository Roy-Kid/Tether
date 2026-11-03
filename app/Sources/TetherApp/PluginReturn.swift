import Foundation

/// Where a tap on a plugin's notification, Live Activity or in-page note goes.
/// The widget builds the same address; both sides read `tether://plugin/<id>`.
enum PluginReturn {
  static let scheme = "tether"
  static let host = "plugin"

  static func url(pluginID: String) -> URL? {
    guard !pluginID.isEmpty else { return nil }
    var allowed = CharacterSet.urlPathAllowed
    allowed.remove(charactersIn: "/")
    guard let encoded = pluginID.addingPercentEncoding(withAllowedCharacters: allowed) else {
      return nil
    }
    return URL(string: "\(scheme)://\(host)/\(encoded)")
  }

  static func pluginID(from url: URL) -> String? {
    guard url.scheme == scheme, url.host == host else { return nil }
    let raw = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    guard !raw.isEmpty, let id = raw.removingPercentEncoding, !id.isEmpty else { return nil }
    return id
  }
}
