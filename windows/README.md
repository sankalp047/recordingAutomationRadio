# PM Radio Logs — Windows

The same archive browser as the Mac app, built with Electron so it runs on
Windows. Find a recording, Status and History, with the same sign-in.

## Run it during development

```bash
cd windows
npm install
npm start
```

## Build the .exe

```bash
npm run dist:win          # installer + portable, x64
```

**Always pass `--x64`.** electron-builder otherwise follows the host
architecture, so building on an Apple Silicon Mac silently produces an **arm64**
`.exe` that will not start on an ordinary Windows PC.

Two artifacts land in `dist/`:

| file | use |
|---|---|
| `PM Radio Logs-1.0.0-x64.exe` | installer — Start menu and desktop shortcuts |
| `PM Radio Logs-1.0.0-portable.exe` | single file, runs with no install |

A GitHub Actions workflow builds both on a real Windows runner: run
**Build Windows app** from the Actions tab, or push a `win-v*` tag.

## Signing

Unsigned, Windows SmartScreen shows *"Windows protected your PC"*. The user can
click **More info → Run anyway**, but it looks alarming and reappears for each
new version.

To remove it you need a code-signing certificate (OV is roughly $200–400/year;
EV clears SmartScreen immediately, OV builds reputation over time). With one,
set `CSC_LINK` and `CSC_KEY_PASSWORD` and electron-builder signs during the
build.

## Notes

- Sign-in opens a real Cloudflare Access window; the session cookie is shared
  with the app, so no token is stored anywhere.
- Playback streams with HTTP Range, so seeking does not download the whole hour.
- The app only reads. It has no control that changes or deletes a recording.
- The icon is generated from `../macos/branding/logo.png`.
