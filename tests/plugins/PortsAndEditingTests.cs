using System.Text;
using TetherApp.Files;
using TetherApp.Plugins;
using Xunit;

namespace TetherApp.PluginTests;

public sealed class PortsAndEditingTests
{
    [Fact]
    public void PortListingRejectsInvalidPortsAndSanitizesProcessNames()
    {
        var ports = PortScan.Parse("80\tnginx\n3000\tnode\n3000\tduplicate\n65536\tno\n8080\t\u202eevil\u2069\r\n22;rm\tno\n");
        Assert.Equal(new ushort[] { 3000, 8080 }, ports.Select(p => p.Port));
        Assert.Equal("evil", ports[1].Name);
        Assert.Throws<IOException>(() => PortScan.Parse(new string('x', PortScan.ByteLimit + 1)));
        Assert.Equal(PortScan.Limit, PortScan.Parse(string.Join("\n", Enumerable.Range(1024, 100).Select(p => $"{p}\tapp"))).Count);
        Assert.Equal(new ushort[] { 3000, 8080 }, PortScan.Ignored("80, 3000 8080, invalid 65536").Order());
    }

    [Theory]
    [InlineData("a\nb\n", "c\rd\r", "c\nd\n")]
    [InlineData("a\r\nb\r\n", "c\rd\r", "c\r\nd\r\n")]
    [InlineData("a\rb\r", "c\nd\n", "c\rd\r")]
    public void EditingRetainsTheOriginalLineEndings(string original, string edited, string expected)
    {
        var document = new TextEditDocument(Encoding.UTF8.GetBytes(original));
        Assert.Equal(expected, Encoding.UTF8.GetString(document.Encode(edited)));
    }

    [Fact]
    public void EditingKeepsBomAndRejectsBinaryOrInvalidUtf8()
    {
        var document = new TextEditDocument([0xef, 0xbb, 0xbf, 65]);
        Assert.Equal("A", document.Text);
        Assert.Equal(new byte[] { 0xef, 0xbb, 0xbf, 66 }, document.Encode("B"));
        Assert.Throws<IOException>(() => new TextEditDocument([65, 0, 66]));
        Assert.Throws<IOException>(() => new TextEditDocument([0xff, 0xfe]));
        Assert.Throws<IOException>(() => new TextEditDocument(new byte[TextEditDocument.ByteLimit + 1]));
    }

    [Fact]
    public void SavingUnchangedMixedLineEndingsPreservesEveryByte()
    {
        var bytes = Encoding.UTF8.GetBytes("one\r\ntwo\nthree\r");
        var document = new TextEditDocument(bytes);
        Assert.Equal(bytes, document.Encode("one\rtwo\rthree\r"));
        Assert.DoesNotContain('\r', PortScan.Command);
    }
}
