#!/usr/bin/env pwsh
# Produces tether_ffi.dll + import lib and refreshes the checked-in C# bindings.
#
# Consumers never run this: it needs the Rust toolchain and uniffi-bindgen-cs,
# which the spec says they must not. It runs here and in CI, and its outputs
# are what ship (Decisions/0004, 0017).
#
# Usage: pwsh scripts/build-windows.ps1 [-Target x86_64-pc-windows-msvc] [-Release]
param(
    [string]$Target = "x86_64-pc-windows-msvc",
    [switch]$DebugBuild
)

$ErrorActionPreference = "Stop"
Set-Location (Join-Path $PSScriptRoot "..")

$profile = if ($DebugBuild) { "debug" } else { "--release"; "release" }
if ($DebugBuild) {
    $cargoArgs = @()
    $profileName = "debug"
} else {
    $cargoArgs = @("--release")
    $profileName = "release"
}

Write-Host "building tether-ffi (render) for $Target"
cargo build @cargoArgs -p tether-ffi --features render --target $Target
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

$dll = "target/$Target/$profileName/tether_ffi.dll"
if (-not (Test-Path $dll)) {
    # host-target builds land in target/<profile> without the triple
    $dll = "target/$profileName/tether_ffi.dll"
}
if (-not (Test-Path $dll)) {
    Write-Error "tether_ffi.dll not found"
    exit 1
}

# Generated C# is checked in so a consumer needs no Rust to build.
# CI re-runs this and fails on a diff; it is never hand-edited.
Write-Host "generating C# bindings"
$bindgen = Get-Command uniffi-bindgen-cs -ErrorAction SilentlyContinue
if (-not $bindgen) {
    Write-Error "uniffi-bindgen-cs not found. Install with: cargo install uniffi-bindgen-cs --git https://github.com/NordSecurity/uniffi-bindgen-cs --tag v0.11.0+v0.31.0"
    exit 1
}
& uniffi-bindgen-cs --library $dll --out-dir dotnet/Tether/Generated
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

# The DLL and import lib are build outputs. Stage them where the façade
# expects them; never commit them (Decisions/0017).
$stage = "dotnet/Tether/runtimes/win-x64/native"
New-Item -ItemType Directory -Force -Path $stage | Out-Null
Copy-Item $dll $stage -Force
Copy-Item ($dll + ".lib") $stage -Force -ErrorAction SilentlyContinue
Copy-Item ($dll -replace '\.dll$', '.pdb') $stage -Force -ErrorAction SilentlyContinue

Write-Host "wrote $dll and dotnet/Tether/Generated/tether_ffi.cs"
Write-Host "staged natives under $stage"
