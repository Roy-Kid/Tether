using System.Security.Cryptography;
using System.Buffers.Binary;

namespace TetherApp;

public sealed record TotpCredential(string Seed, string Algorithm = "SHA1", int Digits = 6, int Period = 30)
{
    public static TotpCredential Parse(string input)
    {
        var credential = new TotpCredential(input.Trim().Replace(" ", "").ToUpperInvariant());
        if (input.StartsWith("otpauth://", StringComparison.OrdinalIgnoreCase))
        {
            var uri = new Uri(input);
            if (uri.Host != "totp") throw new IOException("Only time-based OTP credentials are supported.");
            var query = uri.Query.TrimStart('?').Split('&').Select(p => p.Split('=', 2))
                .ToDictionary(p => Uri.UnescapeDataString(p[0]), p => p.Length > 1 ? Uri.UnescapeDataString(p[1]) : "", StringComparer.OrdinalIgnoreCase);
            credential = new(query.GetValueOrDefault("secret", "").ToUpperInvariant(), query.GetValueOrDefault("algorithm", "SHA1").ToUpperInvariant(),
                int.Parse(query.GetValueOrDefault("digits", "6")), int.Parse(query.GetValueOrDefault("period", "30")));
        }
        if (credential.Algorithm is not ("SHA1" or "SHA256" or "SHA512") || credential.Digits is not (6 or 8) || credential.Period is < 1 or > 300)
            throw new IOException("Unsupported OTP algorithm, digit count, or period.");
        var bytes = Decode(credential.Seed);
        try { if (bytes.Length < 10 || bytes.Length > 128) throw new IOException("OTP secrets must contain 10–128 bytes."); }
        finally { CryptographicOperations.ZeroMemory(bytes); }
        return credential;
    }
    public string Code(DateTimeOffset now)
    {
        var key = Decode(Seed);
        try
        {
            Span<byte> counter = stackalloc byte[8];
            BinaryPrimitives.WriteInt64BigEndian(counter, now.ToUnixTimeSeconds() / Period);
            var digest = Algorithm switch { "SHA1" => HMACSHA1.HashData(key, counter), "SHA256" => HMACSHA256.HashData(key, counter), "SHA512" => HMACSHA512.HashData(key, counter), _ => throw new IOException("Unsupported OTP algorithm.") };
            var offset = digest[^1] & 15;
            var value = BinaryPrimitives.ReadUInt32BigEndian(digest.AsSpan(offset, 4)) & 0x7fffffff;
            return (value % (Digits == 8 ? 100_000_000u : 1_000_000u)).ToString(Digits == 8 ? "D8" : "D6");
        }
        finally { CryptographicOperations.ZeroMemory(key); }
    }
    private static byte[] Decode(string seed)
    {
        var output = new List<byte>(); var bits = 0; var value = 0;
        foreach (var c in seed.TrimEnd('='))
        {
            var index = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567".IndexOf(char.ToUpperInvariant(c));
            if (index < 0) throw new IOException("Enter a Base32 OTP secret or an otpauth URI.");
            value = (value << 5) | index; bits += 5;
            if (bits >= 8) { bits -= 8; output.Add((byte)(value >> bits)); }
        }
        if (bits > 0 && (value & ((1 << bits) - 1)) != 0) throw new IOException("OTP secret has invalid trailing bits.");
        return output.ToArray();
    }
}
