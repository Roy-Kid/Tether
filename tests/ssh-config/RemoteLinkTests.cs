using Xunit;

namespace TetherApp;

public class RemoteLinkTests
{
    [Fact]
    public void ConnectTimeoutIsReadAndOverriddenByTheFirstStanza()
    {
        var entries = SshConfig.LoadText("""
            Host lab
              HostName 10.0.0.4
              ConnectTimeout 15

            Host *
              ConnectTimeout 60
              User ada
            """);
        Assert.Equal(15, entries[0].ConnectTimeoutSeconds);

        var inherited = SshConfig.LoadText("""
            Host *
              ConnectTimeout 12

            Host lab
              HostName 10.0.0.4
            """);
        Assert.Equal(12, inherited[0].ConnectTimeoutSeconds);
    }

    [Fact]
    public void AZeroConnectTimeoutIsNotADeadline()
    {
        var entries = SshConfig.LoadText("Host lab\n  HostName 10.0.0.4\n  ConnectTimeout 0\n");
        Assert.Null(entries[0].ConnectTimeoutSeconds);
        Assert.Equal(RemoteLink.DefaultTimeoutSeconds, RemoteLink.TimeoutSeconds(entries[0].ConnectTimeoutSeconds));
    }

    [Fact]
    public void ReconnectKeepsTheHostThatWasChosen()
    {
        var host = new HostEntry(
            "lab",
            "10.0.0.4",
            "ada",
            2222,
            "~/.ssh/id_lab",
            [new Jump("bastion.example", 22, "jump", "~/.ssh/id_bastion")],
            null,
            15);
        var again = host;
        var plan = RemoteLink.Plan(again, "fallback");
        Assert.True(RemoteLink.SamePlan(plan, RemoteLink.Plan(host, "someone-else")));
        Assert.Equal("10.0.0.4", plan.Host);
        Assert.Equal((ushort)2222, plan.Port);
        Assert.Equal("ada", plan.User);
        Assert.Equal("~/.ssh/id_lab", plan.IdentityFile);
        Assert.Equal("bastion.example", plan.Hops[0].HostName);
        Assert.Equal("~/.ssh/id_bastion", plan.Hops[0].IdentityFile);
        Assert.Equal(15, plan.TimeoutSeconds);
    }

}
