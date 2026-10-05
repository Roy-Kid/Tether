using System.Buffers.Binary;
using System.Text;

namespace TetherApp;

public sealed record RemoteAuthorization(Guid Id, string HostAlias, string EndpointDigest, string PublicKey,
    string DeviceLabel, string State = "Awaiting administrator", string? Detail = null);

public static class AuthorizedKeysProvider
{
    public static string KeyMaterial(string text)
    {
        if (text.Any(c => c is '\r' or '\n')) throw new IOException("Enter a one-line SSH public key.");
        var parts = text.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries);
        if (parts.Length < 2 || parts[0] is not ("ssh-ed25519" or "ecdsa-sha2-nistp256" or "ssh-rsa")) throw new IOException("Unsupported SSH public key.");
        byte[] bytes;
        try { bytes = Convert.FromBase64String(parts[1]); } catch (FormatException) { throw new IOException("Public key encoding is invalid."); }
        if (bytes.Length is <= 4 or >= 16384) throw new IOException("Public key size is invalid.");
        var length = BinaryPrimitives.ReadUInt32BigEndian(bytes);
        if (length == 0 || length > bytes.Length - 4 || Encoding.UTF8.GetString(bytes, 4, (int)length) != parts[0]) throw new IOException("Public key type does not match its contents.");
        return parts[0] + " " + parts[1];
    }
    public static string Script(RemoteAuthorization authorization, bool remove)
    {
        var line = KeyMaterial(authorization.PublicKey) + " tether:" + authorization.Id.ToString("D");
        var change = remove ? ":" : "printf '%s\\n' \"$line\" >> \"$tmp\"";
        return $$"""
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
            line='{{line}}'
            awk -v wanted="$line" '$0 != wanted { print }' "$original" > "$tmp"
            {{change}}
            if test "$existed" = 1; then cmp -s "$f" "$original" || exit 72; else test ! -e "$f" || exit 72; fi
            chmod 700 "$d"
            chmod 600 "$tmp"
            mv "$tmp" "$f"
            tmp=''
            """.Replace("\r\n", "\n");
    }
}
