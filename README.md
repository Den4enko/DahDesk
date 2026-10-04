# DahDesk

Turnkey, zero-copy Wayland desktop streaming. KDE Plasma 6, PipeWire audio, and self-healing native package hooks — delivered by a single shell script.

> **Inspired by and built on the shoulders of:**
> - [**Selkies**](https://github.com/selkies-project/selkies) — the open-source WebRTC desktop streaming engine that powers DahDesk's entire streaming pipeline.
> - [**Linuxserver.io Webtop**](https://github.com/linuxserver/docker-webtop) — the containerised desktop project whose KWin patches and `linuxserver/selkies-layers` OCI layer approach DahDesk borrows directly to achieve unprivileged zero-copy Wayland streaming on bare metal and LXC.

DahDesk is an opinionated installer that wires these upstream projects together into a native systemd service, adds package-manager hooks for automatic self-healing, and handles the KWin capability stripping required in unprivileged environments.

---

## What DahDesk Does

1. **Installs KDE Plasma 6** (Wayland session) and PipeWire audio.
2. **Installs the official Selkies streamer package** from the upstream GitHub release.
3. **Applies the Linuxserver KWin patch** — pulled directly from `ghcr.io/linuxserver/selkies-layers` — which enables zero-copy GPU capture under nested/unprivileged Wayland.
4. **Creates a systemd user service** (`selkies.service`) that starts the desktop and streaming stack automatically on boot.
5. **Installs native package-manager hooks** so every normal system update automatically maintains required KWin capabilities, verifies device permissions, and self-syncs latest components from GitHub without interrupting active user sessions:
   - **Fedora:** DNF5 Actions Plugin (`/etc/dnf/libdnf5-plugins/actions.d/selkies-sync.actions`)
6. **Locks critical packages** (`kwin`, `kwin-libs`, `selkies`) against unintended upstream upgrades that could break streaming.

Once installed, just update your system normally — DahDesk keeps itself consistent automatically.

---

## Supported Distribution

DahDesk is built exclusively for **Fedora** (Fedora 44+).

| Distribution | Display Backend | KWin Patch | Package Manager | Auto-Hook |
|---|---|---|---|---|
| **Fedora 44+** | Native Wayland (zero-copy) | `linuxserver/selkies-layers` overlay | `dnf` / `dnf5` | DNF5 Actions |

---

## Quickstart

```bash
# Interactive setup — prompts for profile, user, port:
curl -fsSL https://raw.githubusercontent.com/Den4enko/DahDesk/main/install.sh | sudo bash

# Or with wget:
wget -qO- https://raw.githubusercontent.com/Den4enko/DahDesk/main/install.sh | sudo bash
```

### Non-Interactive (Flags)

```bash
# Essential desktop, auto-select/create user, no prompts:
curl -fsSL .../install.sh | sudo bash -s -- --essential -y

# Full KDE suite:
curl -fsSL .../install.sh | sudo bash -s -- --full -y

# Custom user, password, port, keyboard:
curl -fsSL .../install.sh | sudo bash -s -- --user admin --password secret --port 8443 --keyboard us,ua -y
```

### All Options

| Flag | Description | Default |
|---|---|---|
| `--essential` | Lightweight desktop — Plasma 6, Dolphin, Konsole, KWrite, audio/network applets | default |
| `--full` | Complete official KDE Spin suite + web browser | |
| `--user <name>` | Desktop username (uses existing or creates new) | auto-detect |
| `--password <pwd>` | Linux user password | username |
| `--port <port>` | Web streaming port | `8080` |
| `--backend <mode>` | Force `wayland` or `x11` | auto |
| `--gpu` | Force enable GPU hardware acceleration (Mesa, VA-API, and video codecs) | auto-detect |
| `--no-gpu` | Disable GPU detection and use software rendering | auto-detect |
| `--keyboard <layouts>` | XKB layouts, comma-separated (e.g. `us,ua`) | `us` |
| `--keyboard-variants <v>` | XKB variants, comma-separated | |
| `--keyboard-options <opts>` | XKB options (e.g. `grp:alt_shift_toggle`) | |
| `-y` / `--yes` | Non-interactive mode | |

---

## Installation Profiles

### Essential Desktop (`--essential`, default)
Clean, lightweight daily-driver (~600 MB RAM):
- KDE Plasma 6 + KWin (Wayland)
- Dolphin, Konsole, KWrite, Ark, Spectacle, Gwenview, KDialog
- PipeWire WebRTC stereo audio
- Network Manager + volume applets

### Full Workstation (`--full`)
Everything in Essential, plus the complete official KDE Spin group:
- Discover Software Center, Plasma System Monitor, Flatpak integration
- Filelight, full thumbnailers, multimedia codecs
- Chromium

---

## Accessing the Desktop

| Item | Value |
|---|---|
| **Web UI** | `https://<host-ip>:<port>/` |
| **TLS** | Self-signed (accept browser prompt once) — required by WebCodecs/WebRTC |
| **Auth** | None — direct stream access (no login dialog) |
| **Desktop user** | Chosen during setup or via `--user` flag |
| **SSH** | Port `22` |

---

## Normal System Updates (Self-Healing & Auto-Sync)

No special scripts needed — just update your system normally:

```bash
# Fedora
sudo dnf update
```

After every DNF transaction, the native DNF5 actions hook automatically runs `/usr/local/bin/selkies-sync`, which:
- Re-strips `kwin_wayland` Linux capabilities (`setcap -r`) for unprivileged container/LXC compatibility
- Verifies and maintains `/dev/dri/*` and `/dev/nvidia*` device permissions for hardware acceleration
- Syncs all components directly from GitHub (`selkies-sync`, `selkies-update`, `selkies-patch-input`, `start-selkies.sh`) with atomic replacement and execution bit preservation
- Maintains Selkies non-US keyboard input patch and session auto-restart hooks
- Leaves active streaming sessions running uninterrupted

Manual trigger (if needed): `sudo selkies-update`

---

## Credits & Acknowledgements

DahDesk is made possible by the following open-source projects:

- **[Selkies](https://github.com/selkies-project/selkies)** — WebRTC-based open-source desktop streaming engine. DahDesk uses the official Selkies release packages and the `selkies-session` binary as its entire streaming backend.
- **[Linuxserver.io Webtop](https://github.com/linuxserver/docker-webtop)** — containerised desktop environment project. DahDesk directly uses the `ghcr.io/linuxserver/selkies-layers` OCI image layers for the KWin nested Wayland patches, following the same patching approach pioneered in Webtop.

If you find DahDesk useful, consider starring and contributing to both upstream projects.
