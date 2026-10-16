using Xunit;

namespace TetherApp;

/// <summary>
/// The same answers <c>SSHConfigTests.swift</c> locks in. A wildcard this
/// side ignores is a different user than <c>ssh</c> would use.
/// </summary>
public class SshConfigTests
{
    [Fact]
    public void AWildcardSuppliesWhatAHostLeavesUnsaid()
    {
        var entries = SshConfig.LoadText("""
            Host lab
              HostName 10.0.0.4
              Port 2222
              IdentityFile ~/.ssh/id_lab
              ControlMaster auto

            Host cluster gateway
              HostName hpc.example.org
              User grace

            # Everything, everywhere
            Host *
              ForwardAgent no
              User ada
            """);
        Assert.Equal(["lab", "cluster"], entries.Select(e => e.Alias).ToArray());
        Assert.Equal("ada", entries[0].User);
        Assert.Equal("grace", entries[1].User);
        Assert.Equal("10.0.0.4", entries[0].HostName);
        Assert.Equal((ushort)2222, entries[0].Port);
    }

    [Fact]
    public void IdentityFileIsInheritedFromAMatchingWildcard()
    {
        var entries = SshConfig.LoadText("""
            Host lab
              HostName 10.0.0.4

            Host *
              IdentityFile ~/.ssh/id_ed25519
            """);
        Assert.Equal("~/.ssh/id_ed25519", entries[0].IdentityFile);
    }

    [Fact]
    public void ABlankLineDoesNotDropIdentityFile()
    {
        var entries = SshConfig.LoadText("""
            Host Arrhenius
                HostName login.example
                User ada

                IdentityFile ~/.ssh/id_arrhenius_mac
                IdentitiesOnly yes
            """);
        Assert.Equal("~/.ssh/id_arrhenius_mac", entries[0].IdentityFile);
    }

    [Fact]
    public void TheFirstStanzaToAnswerWins()
    {
        var entries = SshConfig.LoadText("""
            Host *
              User everyone

            Host lab
              HostName 10.0.0.4
            """);
        Assert.Equal("everyone", entries[0].User);
    }

    [Fact]
    public void EqualsSeparatorReadsTheSame()
    {
        var entries = SshConfig.LoadText("Host eq\n  HostName=10.1.1.1\n  Port = 2200\n");
        Assert.Equal("10.1.1.1", entries[0].HostName);
        Assert.Equal((ushort)2200, entries[0].Port);
    }

    [Fact]
    public void MatchEndsTheStanzaAboveIt()
    {
        var entries = SshConfig.LoadText("""
            Host lab
              HostName 10.0.0.4

            Match host nothing
              User nobody
            """);
        Assert.Single(entries);
        Assert.Null(entries[0].User);
    }

    [Fact]
    public void ProxyJumpExpandsNestedHopsFirst()
    {
        var entries = SshConfig.LoadText("""
            Host lab
              HostName lab.internal
              ProxyJump bastion

            Host bastion
              HostName bastion.example
              User jump
              ProxyJump edge

            Host edge
              HostName edge.example
              Port 2222
              IdentityFile ~/.ssh/id_edge
            """);
        var hops = entries[0].Route;
        Assert.Equal(["edge.example", "bastion.example"], hops.Select(h => h.HostName).ToArray());
        Assert.Equal((ushort)2222, hops[0].Port);
        Assert.Equal("~/.ssh/id_edge", hops[0].IdentityFile);
        Assert.Equal("jump", hops[1].User);
        Assert.Equal((ushort)22, hops[1].Port);
    }

    [Fact]
    public void ACommaSeparatedProxyJumpIsVisitedInOrder()
    {
        var hops = SshConfig.LoadText("""
            Host lab
              ProxyJump me@10.0.0.1:2222, edge

            Host edge
              HostName edge.example
            """).Single(e => e.Alias == "lab").Route;
        Assert.Equal("10.0.0.1", hops[0].HostName);
        Assert.Equal((ushort)2222, hops[0].Port);
        Assert.Equal("me", hops[0].User);
        Assert.Equal("edge.example", hops[1].HostName);
    }

    [Fact]
    public void ProxyJumpNoneMeansThereIsNoJump()
    {
        var entry = SshConfig.LoadText("""
            Host lab
              HostName lab.internal
              ProxyJump none

            Host *
              ProxyJump bastion
            """).Single();
        Assert.Empty(entry.Route);
        Assert.Null(entry.JumpError);
    }

    [Fact]
    public void HostStarCanSupplyTheJump()
    {
        var hops = SshConfig.LoadText("""
            Host lab
              HostName lab.internal

            Host bastion
              HostName bastion.example
              ProxyJump none

            Host *
              ProxyJump bastion
              User ada
            """).Single(e => e.Alias == "lab").Route;
        Assert.Equal("bastion.example", hops[0].HostName);
        Assert.Equal("ada", hops[0].User);
    }

    [Fact]
    public void AProxyJumpCycleIsAnError()
    {
        var entry = SshConfig.LoadText("""
            Host a
              ProxyJump b
            Host b
              ProxyJump a
            """).Single(e => e.Alias == "a");
        Assert.Empty(entry.Route);
        Assert.Equal("ProxyJump for a cycles through a.", entry.JumpError);
    }

    [Fact]
    public void AnIPv6JumpKeepsTheAddressInsideTheBrackets()
    {
        var hop = SshConfig.LoadText("""
            Host lab
              ProxyJump me@[2001:db8::1]:2222
            """).Single().Route[0];
        Assert.Equal("2001:db8::1", hop.HostName);
        Assert.Equal((ushort)2222, hop.Port);
        Assert.Equal("me", hop.User);
    }
}
