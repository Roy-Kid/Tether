using TetherApp.Files;
using TetherApp.Plugins;
using Xunit;

namespace TetherApp.PluginTests;

public class RegistryTests
{
    private sealed class Stub(string id) : ITetherPlugin
    {
        public int Activated;
        public int Deactivated;
        public PluginMetadata Metadata { get; } = new(id, id, "", "");
        public void Activate() => Activated++;
        public void Deactivate() => Deactivated++;
    }

    [Fact]
    public void ADisabledPluginIsNotActivatedUntilItIsTurnedBackOn()
    {
        var saved = new List<IReadOnlyList<string>>();
        var registry = new PluginRegistry(["files"], saved.Add);
        var files = new Stub("files");
        registry.Register(files);

        Assert.Equal(0, files.Activated);
        registry.SetEnabled("files", true);
        Assert.Equal(1, files.Activated);
        Assert.Empty(saved[^1]);

        registry.SetEnabled("files", false);
        Assert.Equal(1, files.Deactivated);
        Assert.Equal(["files"], saved[^1]);
    }

    [Fact]
    public void RegisteringTheSameIdTwiceIsRefused()
    {
        var registry = new PluginRegistry();
        registry.Register(new Stub("files"));
        Assert.Throws<InvalidOperationException>(() => registry.Register(new Stub("files")));
    }
}

public class FilesPathTests
{
    [Fact]
    public void ARelativePathIsTriedWhereTheProgramWasThenTheBrowserThenHome()
    {
        var candidates = FilesPaths.Candidates("src/plot.png", "/work", "/work", "/home/ada");
        Assert.Equal(["/work/src/plot.png", "/home/ada/src/plot.png"], candidates);
    }

    [Fact]
    public void AnAbsolutePathIsOnlyItself()
    {
        Assert.Equal(["/var/log"], FilesPaths.Candidates("/var/log", "/work", null, "/home"));
    }

    [Fact]
    public void ATildePathIsHome()
    {
        Assert.Equal(["/home/ada/note.txt"], FilesPaths.Candidates("~/note.txt", "/work", null, "/home/ada"));
        Assert.Empty(FilesPaths.Candidates("~/note.txt", "/work", null, null));
    }

    [Fact]
    public void AFileUriIsAPathAndAWebAddressIsNot()
    {
        Assert.Equal("/home/ada/plot.png", FilesPaths.FileUri("file:///home/ada/plot.png"));
        Assert.Null(FilesPaths.FileUri("https://example.com/plot.png"));
    }

    [Fact]
    public void QuotingKeepsAPathOneWord()
    {
        Assert.Equal("'/tmp/a b'", FilesPaths.Quote("/tmp/a b", QuoteStyle.Posix));
        Assert.Equal("'/tmp/a'\\''b'", FilesPaths.Quote("/tmp/a'b", QuoteStyle.Posix));
        Assert.Equal("'C:\\a''b'", FilesPaths.Quote(@"C:\a'b", QuoteStyle.PowerShell));
        Assert.Equal("\"C:\\a b\"", FilesPaths.Quote(@"C:\a b", QuoteStyle.Cmd));
        Assert.Equal(QuoteStyle.Cmd, FilesPaths.StyleFor(false, false, "cmd"));
        Assert.Equal(QuoteStyle.Posix, FilesPaths.StyleFor(true, false, "pwsh"));
        Assert.Equal(QuoteStyle.Posix, FilesPaths.StyleFor(false, true, "wsl"));
    }
}
