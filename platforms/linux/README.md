# PortKiller for Linux

A native Linux desktop app built with **Zig + GTK4** for discovering listening TCP ports and terminating the owning process from a single window.

## Features

- 🔍 Scans listening TCP ports using `ss -ltnp`
- ⚡ Kill the process attached to a port (SIGTERM, then SIGKILL fallback)
- 🔎 Search by port number or process name
- 🔄 Manual refresh and optional auto-refresh (every 5 seconds)
- 🖥️ GTK4 desktop window UI

## Requirements

- Linux distribution with GTK4 development files
- Zig `0.13.0` or newer
- `ss` command (provided by `iproute2`)

### Ubuntu/Debian

```bash
sudo apt update
sudo apt install -y zig libgtk-4-dev iproute2
```

## Build

```bash
cd platforms/linux
zig build
```

## Run

```bash
cd platforms/linux
zig build run
```

## Build AppImage

Requires `appimagetool`.

```bash
cd platforms/linux
zig build appimage
```

Output file is written to `zig-out/PortKiller-<arch>.AppImage`.

If `appimagetool` is not in `PATH`, set it explicitly:

```bash
APPIMAGETOOL=/path/to/appimagetool zig build appimage
```

## Notes

- Killing processes may require elevated privileges depending on process owner.
- The app currently focuses on port scanning and process termination in an application window.
