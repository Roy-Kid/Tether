import Foundation

/// One listening port the scan is willing to admit.
struct HeardPort: Equatable, Sendable {
  var port: UInt16
  var name: String
}

/// What a forward bound on this device.
struct HeardForward: Equatable, Sendable {
  var localPort: UInt16
  var alreadyLocal: Bool
}

/// The scan, and the only reading of its answer.
///
/// The command is fixed. Nothing a host sends is placed into it. A line that
/// is not `port<TAB>name` is dropped; a blob that is too large is refused,
/// and the previous list stays.
enum PortScan {
  static let limit = 64
  static let byteLimit = 8 * 1024

  /// Owns the user's own TCP listeners. `/proc` on Linux, `lsof` here.
  /// A live host is asked only for this user's processes: walking every pid
  /// on a shared machine does not finish before the command is given up.
  /// `TETHER_PROC_ROOT` is how a test points it at a fixture and nowhere else.
  static let command = """
    root=${TETHER_PROC_ROOT:-}
    # ss reads the listen table directly. Walking /proc/net/tcp on a shared
    # login node does not finish before the command is given up, and the
    # list stays empty. A fixture never takes this path.
    if [ -z "$root" ]; then
      user=${TETHER_PROC_UID:-}
      if [ -z "$user" ]; then user=$(id -u 2>/dev/null || true); fi
      ssbin=
      if [ -x /usr/sbin/ss ]; then ssbin=/usr/sbin/ss
      elif [ -x /sbin/ss ]; then ssbin=/sbin/ss
      elif [ -x /usr/bin/ss ]; then ssbin=/usr/bin/ss
      elif [ -x /bin/ss ]; then ssbin=/bin/ss
      elif command -v ss >/dev/null 2>&1; then ssbin=$(command -v ss)
      fi
      if [ -n "$ssbin" ]; then
        # -p is the process name. Bound it: on a busy login node it can
        # walk every pid, and a scan that does not finish is an empty list.
        listing=
        ok=
        if command -v timeout >/dev/null 2>&1; then
          listing=$(timeout 4 "$ssbin" -H -ltnpe 2>/dev/null) && ok=1 || true
        fi
        if [ -z "$ok" ]; then
          listing=$("$ssbin" -H -ltne 2>/dev/null || "$ssbin" -ltne 2>/dev/null) && ok=1 || true
        fi
        if [ -n "$ok" ]; then
          printf '%s\\n' "$listing" | awk -v user="$user" '
            {
              if ($1 == "State" || $1 == "Netid" || $1 == "Recv-Q") next
              port = -1
              owner = -1
              name = ""
              for (i = 1; i <= NF; i++) {
                u = index($i, "uid:")
                if (u > 0) owner = substr($i, u + 4) + 0
                if (index($i, "users:((\\"") == 1) {
                  rest = substr($i, 10)
                  q = index(rest, "\\"")
                  if (q > 1) name = substr(rest, 1, q - 1)
                }
                n = split($i, addr, ":")
                last = addr[n]
                if (last ~ /^[0-9]+$/ && (index($i, ".") || index($i, "*") || index($i, "["))) {
                  p = last + 0
                  if (p >= 1024 && p <= 65535 && port < 0) port = p
                }
              }
              if (port < 0) next
              if (name == "") {
                if (user == "" || owner != user + 0) next
                name = "?"
              } else if (user != "" && owner >= 0 && owner != user + 0) next
              if (port in seen) next
              seen[port] = name
              order[++count] = port
            }
            END {
              for (i = 1; i <= count; i++)
                for (j = i + 1; j <= count; j++)
                  if (order[i] + 0 > order[j] + 0) {
                    tmp = order[i]; order[i] = order[j]; order[j] = tmp
                  }
              shown = count
              if (shown > 64) shown = 64
              for (i = 1; i <= shown; i++)
                printf "%d\\t%s\\n", order[i], seen[order[i]]
            }
          '
          exit 0
        fi
      fi
    fi
    if [ -n "$root" ] || [ -r /proc/net/tcp ] || [ -r /proc/net/tcp6 ]; then
      if [ -z "$root" ]; then root=/proc; fi
      inodes=$(mktemp "${TMPDIR:-/tmp}/tether-ports.XXXXXX")
      trap 'rm -f "$inodes"' EXIT
      : > "$inodes"
      note_pid() {
        pid=$1
        dir="$root/$pid/fd"
        [ -d "$dir" ] && [ -r "$dir" ] || return 0
        name=?
        if [ -r "$root/$pid/comm" ]; then
          name=$(tr -cd '[:alnum:]._-' < "$root/$pid/comm" | head -c 32)
        fi
        [ -n "$name" ] || name=?
        for ent in "$dir"/*; do
          [ -L "$ent" ] || continue
          target=$(readlink "$ent" 2>/dev/null) || continue
          case $target in
            socket:\\[*\\])
              inode=${target#socket:[}
              inode=${inode%]}
              printf '%s\\t%s\\n' "$inode" "$name" >> "$inodes"
              ;;
          esac
        done
      }
      if [ -n "${TETHER_PROC_ROOT:-}" ]; then
        for dir in "$root"/[0-9]*; do
          [ -d "$dir" ] || continue
          note_pid "${dir##*/}"
        done
      else
        ps -u "$(id -u)" -o pid= 2>/dev/null | while read -r pid; do
          note_pid "$pid"
        done
      fi
      # A fixture names the uid it planted. A live host uses this user's.
      # An empty inode list must not be read as the tcp table: awk's
      # NR == FNR stays true for the next file when the first has no lines.
      user=${TETHER_PROC_UID:-}
      if [ -z "$user" ] && [ -z "${TETHER_PROC_ROOT:-}" ]; then
        user=$(id -u 2>/dev/null || true)
      fi
      set --
      [ -r "$root/net/tcp" ] && set -- "$@" "$root/net/tcp"
      [ -r "$root/net/tcp6" ] && set -- "$@" "$root/net/tcp6"
      if [ "$#" -gt 0 ]; then
        awk -v user="$user" -v inodes="$inodes" '
          function hex(s,    i, c, n, d) {
            n = 0
            for (i = 1; i <= length(s); i++) {
              c = substr(s, i, 1)
              if (c >= "0" && c <= "9") d = index("0123456789", c) - 1
              else if (c >= "a" && c <= "f") d = index("abcdef", c) + 9
              else if (c >= "A" && c <= "F") d = index("ABCDEF", c) + 9
              else return -1
              n = n * 16 + d
            }
            return n
          }
          FILENAME == inodes {
            split($0, a, "\\t")
            if (a[1] ~ /^[0-9]+$/ && !(a[1] in comm)) comm[a[1]] = a[2]
            next
          }
          FNR == 1 { next }
          {
            n = split($2, addr, ":")
            if (n < 2) next
            port = hex(addr[n])
            if (port < 1024 || port > 65535) next
            if ($4 != "0A") next
            inode = $10
            owner = $8 + 0
            if (inode in comm) name = comm[inode]
            else if (user != "" && owner == user + 0) name = "?"
            else next
            if (port in seen) next
            seen[port] = name
            order[++count] = port
          }
          END {
            for (i = 1; i <= count; i++)
              for (j = i + 1; j <= count; j++)
                if (order[i] + 0 > order[j] + 0) {
                  tmp = order[i]; order[i] = order[j]; order[j] = tmp
                }
            shown = count
            if (shown > 64) shown = 64
            for (i = 1; i <= shown; i++)
              printf "%d\\t%s\\n", order[i], seen[order[i]]
          }
        ' "$inodes" "$@"
      fi
      exit 0
    fi
    if [ -x /usr/sbin/lsof ]; then
      lsof=/usr/sbin/lsof
    elif command -v lsof >/dev/null 2>&1; then
      lsof=$(command -v lsof)
    else
      exit 0
    fi
    "$lsof" -nP -iTCP -sTCP:LISTEN -F cn 2>/dev/null | awk '
      /^c/ { cmd = substr($0, 2); gsub(/[^A-Za-z0-9._-]/, "", cmd); next }
      /^n/ {
        line = substr($0, 2)
        n = split(line, parts, ":")
        port = parts[n] + 0
        if (port < 1024 || port > 65535) next
        if (port in seen) next
        if (cmd == "") cmd = "?"
        seen[port] = cmd
        order[++count] = port
      }
      END {
        for (i = 1; i <= count; i++)
          for (j = i + 1; j <= count; j++)
            if (order[i] + 0 > order[j] + 0) {
              tmp = order[i]; order[i] = order[j]; order[j] = tmp
            }
        shown = count
        if (shown > 64) shown = 64
        for (i = 1; i <= shown; i++)
          printf "%d\\t%s\\n", order[i], seen[order[i]]
      }
    '
    """

  /// `nil` when the answer is too large to trust. Bad lines are skipped.
  static func parse(_ text: String) -> [HeardPort]? {
    guard text.utf8.count <= byteLimit else { return nil }
    var heard: [HeardPort] = []
    var seen = Set<UInt16>()
    for raw in text.split(whereSeparator: \.isNewline) {
      if raw.count > 128 { continue }
      let parts = raw.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
      guard let first = parts.first, let port = UInt16(first), port >= 1024 else { continue }
      guard seen.insert(port).inserted else { continue }
      let name = parts.count > 1 ? clean(String(parts[1])) : "?"
      heard.append(HeardPort(port: port, name: name))
      if heard.count == limit { break }
    }
    return heard
  }

  static func ignoredPorts(_ text: String) -> Set<UInt16> {
    var ports = Set<UInt16>()
    for piece in text.split(whereSeparator: { $0 == "," || $0.isWhitespace }) {
      guard let port = UInt16(piece), port >= 1024 else { continue }
      ports.insert(port)
    }
    return ports
  }

  private static func clean(_ raw: String) -> String {
    let kept = raw.unicodeScalars.filter { scalar in
      let value = scalar.value
      if value < 0x20 || value == 0x7F { return false }
      if (0x202A...0x202E).contains(value) || (0x2066...0x2069).contains(value) { return false }
      if value == 0x200E || value == 0x200F { return false }
      return true
    }
    let text = String(String.UnicodeScalarView(kept)).trimmingCharacters(in: .whitespaces)
    guard !text.isEmpty else { return "?" }
    return String(text.prefix(32))
  }
}
