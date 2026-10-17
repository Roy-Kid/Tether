using System.Security.Cryptography;
using Tether;

namespace TetherApp;

/// App-local storage; parsing and face identity are shared with Apple.
internal static class TerminalFontStore
{
    private static readonly object Gate = new();
    private static bool _loaded;
    internal static string LoadProblem { get; private set; } = "";
    private static string DirectoryPath => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Tether", "Fonts");

    internal static void EnsureLoaded()
    {
        lock (Gate)
        {
            if (_loaded) return;
            if (Directory.Exists(DirectoryPath))
                foreach (var path in Directory.EnumerateFiles(DirectoryPath, "*.font"))
                    try { TerminalSurface.RegisterFont(File.ReadAllBytes(path)); }
                    catch (Exception ex)
                    {
                        try { File.Delete(path); } catch { /* The message below is the record. */ }
                        LoadProblem = "Couldn't restore an imported font: " + ex.Message;
                    }
            _loaded = true;
        }
    }

    internal static FontFace[] Faces()
    {
        EnsureLoaded();
        return TerminalSurface.FontFaces();
    }

    internal static async Task<FontFace[]> ImportAsync(string path)
    {
        EnsureLoaded();
        if (new FileInfo(path).Length > 128L * 1024 * 1024)
            throw new IOException("Font exceeds 128 MiB.");
        var data = await File.ReadAllBytesAsync(path);
        Directory.CreateDirectory(DirectoryPath);
        var digest = Convert.ToHexString(SHA256.HashData(data)).ToLowerInvariant();
        var destination = Path.Combine(DirectoryPath, digest + ".font");
        var temporary = destination + ".tmp-" + Guid.NewGuid().ToString("N");
        var created = !File.Exists(destination);
        try
        {
            if (created)
            {
                await File.WriteAllBytesAsync(temporary, data);
                File.Move(temporary, destination, overwrite: true);
            }
            return TerminalSurface.RegisterFont(data);
        }
        catch
        {
            if (created && File.Exists(destination)) File.Delete(destination);
            throw;
        }
        finally { if (File.Exists(temporary)) File.Delete(temporary); }
    }
}
