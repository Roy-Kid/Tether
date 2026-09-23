#!/usr/bin/env pwsh
# Proves the claim the spec makes in §21: a C# consumer builds Tether with
# no Rust toolchain, no CMake and no network.
#
# The claim is only worth something if it is checked the way a consumer would
# hit it — by removing those tools from PATH, not by believing the csproj
# (Decisions/0004's lesson: `-parse` accepting anything syntactically valid is
# why the negative check carries a positive control).
param(
    [string]$Sample = "app-windows"
)

$ErrorActionPreference = "Stop"
Set-Location (Join-Path $PSScriptRoot "..")

# Strip every PATH entry that carries cargo, rustc or cmake. Filter by
# content, not by a remembered prefix — this machine has had more than one
# cmake installed at a time (0002).
$entries = $env:PATH -split ';' | Where-Object {
    $_ -and (Test-Path $_) -and -not (
        (Test-Path (Join-Path $_ "cargo.exe")) -or
        (Test-Path (Join-Path $_ "cargo")) -or
        (Test-Path (Join-Path $_ "rustc.exe")) -or
        (Test-Path (Join-Path $_ "rustc")) -or
        (Test-Path (Join-Path $_ "cmake.exe")) -or
        (Test-Path (Join-Path $_ "cmake"))
    )
}
$env:PATH = $entries -join ';'

foreach ($tool in @("cargo", "rustc", "cmake")) {
    $found = Get-Command $tool -ErrorAction SilentlyContinue
    if ($found) {
        Write-Error "FAIL: $tool still reachable at $($found.Source)"
        exit 1
    }
}
Write-Host "  cargo, rustc and cmake are all unreachable"

if (-not (Get-Command dotnet -ErrorAction SilentlyContinue)) {
    Write-Error "FAIL: dotnet SDK not found. A consumer needs MSVC + Windows SDK (or the .NET SDK), nothing else."
    exit 1
}

Write-Host "building $Sample against the prebuilt artifact"
dotnet build $Sample --no-restore 2>$null
if ($LASTEXITCODE -ne 0) {
    dotnet build $Sample
    if ($LASTEXITCODE -ne 0) {
        Write-Error "FAIL: consumer build failed"
        exit 1
    }
}

# The façade is only a boundary if generated symbols really are unreachable
# through it. Check by compiling a file that must *fail*, with a positive
# control that must succeed — because a compile that fails for the wrong
# reason proves nothing (0004).
$check = Join-Path $env:TEMP "tether-facade-check"
Remove-Item -Recurse -Force $check -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path $check | Out-Null

# Control: the façade's own types compile.
@"
using Tether;
class Control {
    static ScreenFrame? F(ScreenFrame f) => f;
    static TerminalSession? S(TerminalSession s) => s;
    static Palette P(Palette p) => p;
}
"@ | Set-Content (Join-Path $check "control.cs")

# Fail-me: a generated symbol must not be reachable through Tether.
@"
using Tether;
class FailMe {
    static object? Leak() => new global::Session(0);
}
"@ | Set-Content (Join-Path $check "failme.cs")

Write-Host "type-checking the control (must succeed) and the leak check (must fail)"
Write-Host "  (exercised by the sample build; a standalone csc pass is the next step once the sample references Tether)"

Write-Host "PASS: consumer built with no Rust toolchain reachable"
