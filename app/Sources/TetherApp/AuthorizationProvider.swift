import CryptoKit
import Foundation
import Tether

struct RemoteAuthorization: Codable, Identifiable, Sendable {
  enum State: String, Codable { case awaitingAdministrator, installed, verified, revocationPending, revoked, failed }
  var id = UUID()
  var hostID: UUID
  var publicKey: String
  var deviceLabel: String
  var provider: String
  var state: State
  var detail: String?
}

protocol AuthorizationProvider: Sendable {
  func enroll(_ authorization: RemoteAuthorization, on connection: RemoteConnection) async throws
  func revoke(_ authorization: RemoteAuthorization, on connection: RemoteConnection) async throws
}

struct AuthorizedKeysProvider: AuthorizationProvider {
  static func keyMaterial(_ text: String) throws -> String {
    let parts = text.split(whereSeparator: \.isWhitespace)
    guard parts.count >= 2, ["ssh-ed25519", "ecdsa-sha2-nistp256", "ssh-rsa"].contains(String(parts[0])),
      !text.contains(where: \.isNewline), let data = Data(base64Encoded: String(parts[1])),
      data.count > 4, data.count < 16_384 else { throw IdentityError.invalidConfiguration }
    let length = data.prefix(4).reduce(0) { ($0 << 8) | Int($1) }
    guard length > 0, length <= data.count - 4,
      String(data: data[4..<(4 + length)], encoding: .utf8) == String(parts[0]) else { throw IdentityError.invalidConfiguration }
    return "\(parts[0]) \(parts[1])"
  }
  func enroll(_ authorization: RemoteAuthorization, on connection: RemoteConnection) async throws {
    try await apply(authorization, remove: false, on: connection)
  }
  func revoke(_ authorization: RemoteAuthorization, on connection: RemoteConnection) async throws {
    try await apply(authorization, remove: true, on: connection)
  }
  static func script(_ authorization: RemoteAuthorization, remove: Bool) throws -> String {
    let key = try keyMaterial(authorization.publicKey)
    let line = key + " tether:" + authorization.id.uuidString
    // mkdir is the cooperative lock. A same-directory temporary + rename prevents
    // partial files; comparison catches non-cooperating writers before replacement.
    // No shell text supplied by the user is evaluated as code.
    return """
    set -eu
    umask 077
    d="$HOME/.ssh"
    test ! -L "$d" || exit 70
    mkdir -p "$d"
    test -d "$d" || exit 70
    mkdir "$d/.tether-authorized-keys-lock" || exit 71
    tmp=''
    original=''
    trap 'test -z "$tmp" || rm -f "$tmp"; test -z "$original" || rm -f "$original"; rmdir "$d/.tether-authorized-keys-lock"' EXIT HUP INT TERM
    f="$d/authorized_keys"
    test ! -L "$f" || exit 70
    test ! -e "$f" || test -f "$f" || exit 70
    tmp=$(mktemp "$d/.tether-keys.XXXXXXXX")
    original=$(mktemp "$d/.tether-original.XXXXXXXX")
    existed=0
    if test -f "$f"; then cat "$f" > "$original"; existed=1; fi
    line=\(shellQuoted(line))
    awk -v wanted="$line" '$0 != wanted { print }' "$original" > "$tmp"
    \(remove ? ":" : "printf '%s\\n' \"$line\" >> \"$tmp\"")
    if test "$existed" = 1; then cmp -s "$f" "$original" || exit 72; else test ! -e "$f" || exit 72; fi
    chmod 700 "$d"
    chmod 600 "$tmp"
    mv "$tmp" "$f"
    tmp=''
    """
  }
  private func apply(_ authorization: RemoteAuthorization, remove: Bool, on connection: RemoteConnection) async throws {
    let result = try await connection.execute(Self.script(authorization, remove: remove))
    guard result.status == 0 else {
      throw IdentityError.storage("Remote authorization failed (status \(result.status.map(String.init) ?? "unknown")). Check account permissions or ask its administrator.")
    }
  }
}
