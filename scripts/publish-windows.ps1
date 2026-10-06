#!/usr/bin/env pwsh
# Builds the release native library, then publishes a compressed portable EXE.
param([switch]$SkipNativeBuild)

$ErrorActionPreference = 'Stop'
$repositoryRoot = Split-Path $PSScriptRoot -Parent
Push-Location $repositoryRoot
try {
    if (-not $SkipNativeBuild) {
        & "$PSScriptRoot/build-windows.ps1"
        if ($LASTEXITCODE -ne 0) { throw 'Native build failed' }
    }
    $outputDirectory = Join-Path $repositoryRoot 'artifacts/windows-portable'
    # Unique output avoids including stale files from an earlier publish.
    $publishDirectory = Join-Path $outputDirectory ([Guid]::NewGuid().ToString('N'))
    dotnet publish app-win/TetherApp.Windows.csproj -c Release -p:Platform=x64 -p:PublishProfile=Portable -warnaserror -o $publishDirectory
    if ($LASTEXITCODE -ne 0) { throw 'Portable publish failed' }
    $publishedFiles = @(Get-ChildItem -LiteralPath $publishDirectory -File -Recurse)
    if ($publishedFiles.Count -ne 1 -or $publishedFiles[0].Name -ne 'TetherApp.Windows.exe') {
        throw 'Portable publish must contain exactly one TetherApp.Windows.exe'
    }
    $archive = Join-Path $outputDirectory 'Tether-win-x64.zip'
    Compress-Archive -Path "$publishDirectory/*" -DestinationPath $archive -CompressionLevel Optimal -Force
    Write-Host "Portable files: $publishDirectory"
    Write-Host "Archive: $archive"
} finally {
    Pop-Location
}
