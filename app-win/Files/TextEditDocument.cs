using System.Text;

namespace TetherApp.Files;

internal sealed class TextEditDocument
{
    public const int ByteLimit = 2 * 1024 * 1024;
    private static readonly UTF8Encoding Utf8 = new(false, true);
    private readonly bool _bom;
    private readonly string _newline;
    private readonly byte[] _original;
    public string Text { get; }

    public TextEditDocument(byte[] bytes)
    {
        if (bytes.Length > ByteLimit) throw new IOException("Text editing is limited to 2 MiB.");
        if (bytes.Contains((byte)0)) throw new IOException("Choose a UTF-8 text file.");
        _original = bytes.ToArray();
        _bom = bytes.AsSpan().StartsWith(new byte[] { 0xEF, 0xBB, 0xBF });
        try { Text = Utf8.GetString(bytes.AsSpan(_bom ? 3 : 0)); }
        catch (DecoderFallbackException) { throw new IOException("Choose a UTF-8 text file."); }
        _newline = Text.Contains("\r\n", StringComparison.Ordinal) ? "\r\n" : Text.Contains('\r') ? "\r" : "\n";
    }

    public byte[] Encode(string text)
    {
        if (Normalize(text) == Normalize(Text)) return _original.ToArray();
        var normalized = text.Replace("\r\n", "\n", StringComparison.Ordinal).Replace('\r', '\n')
            .Replace("\n", _newline, StringComparison.Ordinal);
        var body = Utf8.GetBytes(normalized);
        if (body.Length + (_bom ? 3 : 0) > ByteLimit) throw new IOException("Text editing is limited to 2 MiB.");
        return _bom ? [0xEF, 0xBB, 0xBF, .. body] : body;
    }
    private static string Normalize(string text) => text.Replace("\r\n", "\n", StringComparison.Ordinal).Replace('\r', '\n');
}
