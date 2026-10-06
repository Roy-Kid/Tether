# Tether for Windows

The unpackaged Windows 11 application is a consumer of the Tether .NET SDK.

## Build and publish

```powershell
dotnet build app-win/TetherApp.Windows.csproj -c Debug -p:Platform=x64
./scripts/publish-windows.ps1
```

Publishing produces one self-contained compressed executable and
`artifacts/windows-portable/Tether-win-x64.zip`. The native library must be
built before using `-SkipNativeBuild`. Debug output retains separate files.

## Branding and metadata

- `../assets/logo.png` is the shared logo source. `Assets/Tether.ico` is its
  Windows derivative, containing 16, 20, 24, 32, 40, 48, 64, 128 and 256 px
  images. Regenerate it with `python scripts/windows-icon.py` from the repository
  root (Pillow required only for regeneration).
- The project embeds this ICO in both the executable's Windows resources and
  the managed assembly. `AppBranding` sets the same icon on main and auxiliary
  windows without shipping a separate image file.
- `Roy-Kid.Tether` is the process AppUserModelID and manifest identity.
- Product, description, copyright, repository, license and version metadata are
  declared in `TetherApp.Windows.csproj`. Version `0.0.0` matches the current
  SDK and Apple app; update the manifest's four-part version with release bumps.
- `app.manifest` requests normal user privileges, Windows 10/11 compatibility,
  per-monitor DPI awareness and long-path support. The project minimum is
  Windows 11 (build 22621).
- The MIT license is embedded as `TetherApp.License`. The project does not
  fabricate signing credentials or package publisher identities.
