#!/bin/bash
set -euo pipefail

SELKIES_VERSION="2.0.0"
PROFILE="essential"
DESKTOP_USER=""
DESKTOP_PASS=""
SET_PASSWORD=false
PORT="8080"
BACKEND_OVERRIDE=""
NON_INTERACTIVE=false
KEYBOARD_LAYOUTS="us"       # comma-separated XKB layouts, e.g. "us,ua"
KEYBOARD_VARIANTS=""        # comma-separated variants (can be empty), e.g. ",phonetic"
KEYBOARD_OPTIONS=""         # XKB options, e.g. "grp:alt_shift_toggle"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --essential|--minimal)
            PROFILE="essential"
            shift
            ;;
        --full)
            PROFILE="full"
            shift
            ;;
        --user)
            DESKTOP_USER="$2"
            shift 2
            ;;
        --password)
            DESKTOP_PASS="$2"
            SET_PASSWORD=true
            shift 2
            ;;
        --port)
            PORT="$2"
            shift 2
            ;;
        --backend)
            BACKEND_OVERRIDE="$2"
            shift 2
            ;;
        --keyboard)
            KEYBOARD_LAYOUTS="$2"
            shift 2
            ;;
        --keyboard-variants)
            KEYBOARD_VARIANTS="$2"
            shift 2
            ;;
        --keyboard-options)
            KEYBOARD_OPTIONS="$2"
            shift 2
            ;;
        -y|--yes)
            NON_INTERACTIVE=true
            shift
            ;;
        -h|--help)
            echo "Usage: sudo bash install.sh [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --essential                Install essential desktop (KDE, Dolphin, Settings, Applets, Tools) [Default]"
            echo "  --full                     Install full workstation suite (Official KDE Spin / Workstation apps)"
            echo "  --user <name>              Desktop username (uses existing system user or creates new)"
            echo "  --password <pwd>           Desktop user password (sets Linux user password)"
            echo "  --port <port>              Web streaming port (default: 8080)"
            echo "  --backend <mode>           Display backend: wayland or x11 (default: auto)"
            echo "  --keyboard <layouts>       XKB keyboard layouts, comma-separated (e.g. 'us,ua')"
            echo "  --keyboard-variants <v>    XKB variants, comma-separated (e.g. ',phonetic')"
            echo "  --keyboard-options <opts>  XKB options (e.g. 'grp:alt_shift_toggle')"
            echo "  -y, --yes                  Non-interactive mode (use defaults or flags without prompting)"
            exit 0
            ;;
        *)
            shift
            ;;
    esac
done

if [ "$(id -u)" -ne 0 ]; then
    echo "Error: install.sh must be run as root." >&2
    exit 1
fi

if [ ! -f /etc/os-release ]; then
    echo "Error: /etc/os-release not found. Unsupported system." >&2
    exit 1
fi

. /etc/os-release

ARCH="$(uname -m)"
case "$ARCH" in
    x86_64)
        LAYER_ARCH="amd64"
        DEB_ARCH="amd64"
        SELKIES_ARCH="x86_64"
        ;;
    aarch64|arm64)
        LAYER_ARCH="arm64v8"
        DEB_ARCH="arm64"
        SELKIES_ARCH="aarch64"
        ;;
    *)
        echo "Error: Unsupported CPU architecture ($ARCH)." >&2
        exit 1
        ;;
esac

KWIN_LAYER=""
case "${ID:-}" in
    fedora)
        DISTRO="fedora"
        KWIN_LAYER="${LAYER_ARCH}-fedora44-kwin"
        ;;
    ubuntu)
        DISTRO="ubuntu"
        KWIN_LAYER="${LAYER_ARCH}-ubunturesolute-kwin"
        ;;
    arch|manjaro|endeavouros)
        DISTRO="arch"
        KWIN_LAYER="${LAYER_ARCH}-arch-kwin"
        ;;
    kali)
        DISTRO="kali"
        KWIN_LAYER="${LAYER_ARCH}-kali-kwin"
        ;;
    debian)
        DISTRO="debian"
        KWIN_LAYER=""
        ;;
    *)
        if [[ "${ID_LIKE:-}" =~ (fedora|rhel|centos) ]]; then
            DISTRO="fedora"
            KWIN_LAYER="${LAYER_ARCH}-fedora44-kwin"
        elif [[ "${ID_LIKE:-}" =~ (debian|ubuntu) ]]; then
            DISTRO="debian"
            KWIN_LAYER=""
        elif [[ "${ID_LIKE:-}" =~ arch ]]; then
            DISTRO="arch"
            KWIN_LAYER="${LAYER_ARCH}-arch-kwin"
        else
            echo "Error: Unsupported distribution ($ID)." >&2
            exit 1
        fi
        ;;
esac

TARGET_BACKEND="Wayland (Native Zero-Copy)"
if [ -z "$KWIN_LAYER" ]; then
    TARGET_BACKEND="X11 (Fallback)"
fi
if [ -n "$BACKEND_OVERRIDE" ]; then
    TARGET_BACKEND="$BACKEND_OVERRIDE (Manual Override)"
fi

# Detect existing non-root users (UID >= 1000 and not nobody)
mapfile -t DETECTED_USERS < <(awk -F: '$3 >= 1000 && $3 != 65534 && $7 !~ /(nologin|false)$/ {print $1}' /etc/passwd 2>/dev/null || true)

# Interactive configuration prompt
if [ "$NON_INTERACTIVE" = false ] && [ -c /dev/tty ]; then
    echo "=================================================="
    echo "   DahDesk - KDE Plasma Desktop Setup"
    echo "=================================================="
    echo "Detected OS:       $DISTRO ($ARCH)"
    echo "Display Backend:   $TARGET_BACKEND"
    echo ""
    echo "[1/3] Select Desktop Installation Profile:"
    echo "  1) Essential Desktop (Recommended)"
    echo "     -> Plasma 6, Dolphin file manager, System Settings,"
    echo "        Konsole, KWrite, Ark, Spectacle, Audio/Network applets."
    echo "     -> Clean, fast, lightweight (~600MB RAM)."
    echo ""
    echo "  2) Full Workstation"
    echo "     -> Complete official KDE Spin package group:"
    echo "        Discover App Store, System Monitor, Flatpak integration,"
    echo "        Full multimedia suite, Filelight, Web Browser."
    echo ""
    read -r -p "Enter choice [1-2] (default: 1): " choice_profile < /dev/tty || choice_profile="1"
    case "$choice_profile" in
        2|full|Full) PROFILE="full" ;;
        *) PROFILE="essential" ;;
    esac

    echo ""
    echo "[2/3] Desktop User Setup:"
    if [ "${#DETECTED_USERS[@]}" -gt 0 ]; then
        echo "  Found existing system user(s):"
        idx=1
        for u in "${DETECTED_USERS[@]}"; do
            echo "    ${idx}) Use existing user: ${u}"
            ((idx++))
        done
        echo "    ${idx}) Create a new user"
        echo ""
        read -r -p "Enter choice [1-${idx}] (default: 1): " choice_user < /dev/tty || choice_user="1"

        if [[ "$choice_user" =~ ^[0-9]+$ ]] && [ "$choice_user" -ge 1 ] && [ "$choice_user" -le "${#DETECTED_USERS[@]}" ]; then
            DESKTOP_USER="${DETECTED_USERS[$((choice_user - 1))]}"
            echo "Selected existing user: ${DESKTOP_USER}"
            read -r -p "Change Linux password for '${DESKTOP_USER}'? [y/N]: " change_pass < /dev/tty || change_pass="n"
            if [[ "$change_pass" =~ ^[yY] ]]; then
                read -s -r -p "Enter new password for ${DESKTOP_USER}: " input_pass < /dev/tty || input_pass=""
                echo ""
                if [ -n "$input_pass" ]; then
                    read -s -r -p "Confirm new password for ${DESKTOP_USER}: " confirm_pass < /dev/tty || confirm_pass=""
                    echo ""
                    if [ "$input_pass" = "$confirm_pass" ]; then
                        DESKTOP_PASS="$input_pass"
                        SET_PASSWORD=true
                    else
                        echo "Passwords do not match. Password was not changed."
                    fi
                fi
            fi
        else
            while true; do
                read -r -p "Enter new username (default: desktop): " new_u < /dev/tty || new_u=""
                new_u="${new_u:-desktop}"
                if [[ "$new_u" =~ ^[a-z_][a-z0-9_-]*$ ]]; then
                    DESKTOP_USER="$new_u"
                    break
                else
                    echo "Invalid username. Must start with a letter/underscore and contain [a-z0-9_-]."
                fi
            done
            read -s -r -p "Enter password for ${DESKTOP_USER} (default: ${DESKTOP_USER}): " input_pass < /dev/tty || input_pass=""
            echo ""
            DESKTOP_PASS="${input_pass:-$DESKTOP_USER}"
            SET_PASSWORD=true
        fi
    else
        echo "  No non-root user found."
        while true; do
            read -r -p "Enter username to create (default: desktop): " new_u < /dev/tty || new_u=""
            new_u="${new_u:-desktop}"
            if [[ "$new_u" =~ ^[a-z_][a-z0-9_-]*$ ]]; then
                DESKTOP_USER="$new_u"
                break
            else
                echo "Invalid username. Must start with a letter/underscore and contain [a-z0-9_-]."
            fi
        done
        read -s -r -p "Enter password for ${DESKTOP_USER} (default: ${DESKTOP_USER}): " input_pass < /dev/tty || input_pass=""
        echo ""
        DESKTOP_PASS="${input_pass:-$DESKTOP_USER}"
        SET_PASSWORD=true
    fi

    echo ""
    echo "[3/4] Keyboard Layout:"
    echo "  Enter XKB layout(s), comma-separated. Examples:"
    echo "    us          - US English only"
    echo "    us,ua       - US + Ukrainian (switch with Alt+Shift by default)"
    echo "    us,ru       - US + Russian"
    echo "    us,de       - US + German"
    echo ""
    read -r -p "Layout(s) (default: ${KEYBOARD_LAYOUTS}): " input_kbdl < /dev/tty || input_kbdl=""
    [ -n "$input_kbdl" ] && KEYBOARD_LAYOUTS="$input_kbdl"

    # If multiple layouts, ask for switch shortcut
    if [[ "$KEYBOARD_LAYOUTS" == *","* ]]; then
        echo ""
        echo "  Switch shortcut options:"
        echo "    1) Alt+Shift   (grp:alt_shift_toggle) [Default]"
        echo "    2) Ctrl+Shift  (grp:ctrl_shift_toggle)"
        echo "    3) Super+Space (grp:win_space_toggle)"
        echo "    4) CapsLock    (grp:caps_toggle)"
        echo "    5) Custom (enter manually)"
        echo ""
        read -r -p "Shortcut choice [1-5] (default: 1): " kbdopt < /dev/tty || kbdopt="1"
        case "$kbdopt" in
            2) KEYBOARD_OPTIONS="grp:ctrl_shift_toggle" ;;
            3) KEYBOARD_OPTIONS="grp:win_space_toggle" ;;
            4) KEYBOARD_OPTIONS="grp:caps_toggle" ;;
            5)
                read -r -p "Enter XKB option string: " KEYBOARD_OPTIONS < /dev/tty || KEYBOARD_OPTIONS=""
                ;;
            *) KEYBOARD_OPTIONS="grp:alt_shift_toggle" ;;
        esac
    fi

    echo ""
    read -r -p "[4/4] Web Streaming Port (default: $PORT): " input_port < /dev/tty || input_port=""
    [ -n "$input_port" ] && PORT="$input_port"

    USER_STATUS="New"
    if id -u "$DESKTOP_USER" &>/dev/null; then
        USER_STATUS="Existing"
    fi

    echo ""
    echo "--------------------------------------------------"
    echo "Installation Summary:"
    echo "  Distribution: $DISTRO ($ARCH)"
    echo "  Profile:      $PROFILE"
    echo "  Backend:      $TARGET_BACKEND"
    echo "  Desktop User: $DESKTOP_USER ($USER_STATUS)"
    echo "  Web Port:     $PORT"
    echo "  Keyboard:     ${KEYBOARD_LAYOUTS}${KEYBOARD_OPTIONS:+ ($KEYBOARD_OPTIONS)}"
    echo "  HTTP Auth:    Disabled (Direct Web Access)"
    echo "--------------------------------------------------"
    read -r -p "Proceed with installation? [Y/n]: " proceed < /dev/tty || proceed="y"
    case "$proceed" in
        n|N|no|No)
            echo "Installation cancelled."
            exit 0
            ;;
    esac
    echo ""
fi

# Fallback for non-interactive mode if DESKTOP_USER not specified
if [ -z "$DESKTOP_USER" ]; then
    if [ "${#DETECTED_USERS[@]}" -gt 0 ]; then
        DESKTOP_USER="${DETECTED_USERS[0]}"
    else
        DESKTOP_USER="desktop"
    fi
fi

echo "Installing distribution packages for profile: $PROFILE..."

case "$DISTRO" in
    fedora)
        BASE_PKGS=(
            systemd systemd-udev systemd-pam systemd-networkd systemd-resolved
            dbus dbus-tools dbus-x11 sudo procps-ng psmisc iproute net-tools curl tar libcap
            python3-dnf-plugin-versionlock libdnf5-plugin-actions NetworkManager openssh-server
            pipewire pipewire-pulse pipewire-utils wireplumber pulseaudio-utils
            xorg-x11-server-Xvfb xrandr xrdb
            kwin kwin-x11 breeze-icon-theme konsole plasma-desktop plasma-workspace plasma-workspace-x11
            dolphin plasma-systemsettings plasma-pa plasma-nm kwrite ark gwenview spectacle kdialog
        )
        dnf install -y --disablerepo=fedora-cisco-openh264 --setopt=install_weak_deps=False --nodocs "${BASE_PKGS[@]}"

        if [ "$PROFILE" = "full" ]; then
            echo "Installing complete Fedora KDE Desktop group..."
            dnf group install -y --disablerepo=fedora-cisco-openh264 --setopt=install_weak_deps=False kde-desktop || true
            dnf install -y --disablerepo=fedora-cisco-openh264 --setopt=install_weak_deps=False \
                plasma-discover-packagekit flatpak plasma-discover-flatpak \
                chromium || true
        fi
        ;;
    ubuntu|debian|kali)
        export DEBIAN_FRONTEND=noninteractive
        apt-get update
        BASE_PKGS=(
            systemd libpam-systemd dbus dbus-x11 sudo procps psmisc iproute2 net-tools curl tar libcap2-bin
            openssh-server network-manager
            pipewire pipewire-pulse wireplumber pulseaudio-utils
            xvfb x11-xserver-utils x11-utils
            kwin-wayland kwin-x11 breeze-icon-theme konsole plasma-desktop plasma-workspace
            dolphin systemsettings plasma-pa plasma-nm kwrite ark gwenview kde-spectacle kdialog
        )
        apt-get install -y --no-install-recommends "${BASE_PKGS[@]}"

        if [ "$PROFILE" = "full" ]; then
            echo "Installing full desktop suite..."
            apt-get install -y --no-install-recommends kubuntu-desktop 2>/dev/null || apt-get install -y --no-install-recommends kde-standard 2>/dev/null || true
            apt-get install -y --no-install-recommends chromium-browser 2>/dev/null || apt-get install -y --no-install-recommends chromium 2>/dev/null || true
        fi
        ;;
    arch)
        BASE_PKGS=(
            systemd dbus sudo procps-ng psmisc iproute2 net-tools curl tar libcap
            openssh networkmanager
            pipewire pipewire-pulse wireplumber libpulse
            xorg-server-xvfb xorg-xrandr xorg-xrdb
            kwin kwin-x11 breeze-icons konsole plasma-desktop plasma-workspace
            dolphin systemsettings plasma-pa plasma-nm kwrite ark gwenview spectacle kdialog
        )
        pacman -Syu --noconfirm --needed "${BASE_PKGS[@]}"

        if [ "$PROFILE" = "full" ]; then
            echo "Installing full KDE applications suite..."
            pacman -Syu --noconfirm --needed kde-applications chromium || true
        fi
        ;;
esac

echo "Installing Selkies Streamer package..."
case "$DISTRO" in
    fedora)
        RPM_URL="https://github.com/selkies-project/selkies/releases/download/${SELKIES_VERSION}/selkies-${SELKIES_VERSION}-fc-${SELKIES_ARCH}.rpm"
        dnf install -y "$RPM_URL"
        dnf versionlock add kwin kwin-libs kwin-x11 kwin-common selkies 2>/dev/null || true
        ;;
    ubuntu)
        UBUNTU_VER="${VERSION_ID:-24.04}"
        if [[ "$UBUNTU_VER" == "26.04"* ]]; then
            DEB_NAME="selkies-${SELKIES_VERSION}-ubuntu26.04-${DEB_ARCH}.deb"
        else
            DEB_NAME="selkies-${SELKIES_VERSION}-ubuntu24.04-${DEB_ARCH}.deb"
        fi
        DEB_URL="https://github.com/selkies-project/selkies/releases/download/${SELKIES_VERSION}/${DEB_NAME}"
        curl -fsSL "$DEB_URL" -o "/tmp/${DEB_NAME}"
        dpkg -i "/tmp/${DEB_NAME}" || apt-get install -f -y
        rm -f "/tmp/${DEB_NAME}"
        apt-mark hold kwin-wayland kwin-common selkies 2>/dev/null || true
        ;;
    debian|kali)
        DEB_NAME="selkies-${SELKIES_VERSION}-debianbookworm-${DEB_ARCH}.deb"
        if [ "${VERSION_CODENAME:-}" = "trixie" ] || [ "${VERSION_ID:-}" = "13" ]; then
            DEB_NAME="selkies-${SELKIES_VERSION}-debiantrixie-${DEB_ARCH}.deb"
        fi
        DEB_URL="https://github.com/selkies-project/selkies/releases/download/${SELKIES_VERSION}/${DEB_NAME}"
        curl -fsSL "$DEB_URL" -o "/tmp/${DEB_NAME}"
        dpkg -i "/tmp/${DEB_NAME}" || apt-get install -f -y
        rm -f "/tmp/${DEB_NAME}"
        apt-mark hold kwin-wayland kwin-common selkies 2>/dev/null || true
        ;;
    arch)
        PKG_NAME="selkies-${SELKIES_VERSION}-${SELKIES_ARCH}.pkg.tar.zst"
        PKG_URL="https://github.com/selkies-project/selkies/releases/download/${SELKIES_VERSION}/${PKG_NAME}"
        curl -fsSL "$PKG_URL" -o "/tmp/${PKG_NAME}"
        pacman -U --noconfirm "/tmp/${PKG_NAME}"
        rm -f "/tmp/${PKG_NAME}"
        if ! grep -q "^IgnorePkg.*kwin" /etc/pacman.conf; then
            sed -i '/^#IgnorePkg/a IgnorePkg = kwin selkies' /etc/pacman.conf 2>/dev/null || true
        fi
        ;;
esac

if [ -n "$KWIN_LAYER" ]; then
    echo "Applying KWin nested Wayland patch ($KWIN_LAYER)..."
    TOKEN=$(curl -s "https://ghcr.io/token?scope=repository:linuxserver/selkies-layers:pull" | grep -o '"token":"[^"]*' | cut -d'"' -f4)
    MANIFEST=$(curl -s -H "Authorization: Bearer $TOKEN" -H "Accept: application/vnd.oci.image.manifest.v1+json,application/vnd.docker.distribution.manifest.v2+json" "https://ghcr.io/v2/linuxserver/selkies-layers/manifests/$KWIN_LAYER")
    DIGEST=$(echo "$MANIFEST" | grep -o '"digest": *"sha256:[^"]*' | tail -n 1 | cut -d'"' -f4)
    if [ -n "$DIGEST" ]; then
        curl -sL -H "Authorization: Bearer $TOKEN" "https://ghcr.io/v2/linuxserver/selkies-layers/blobs/$DIGEST" | tar -xzf - -C / usr/ 2>/dev/null || true
    elif command -v podman &>/dev/null; then
        CID=$(podman create "ghcr.io/linuxserver/selkies-layers:$KWIN_LAYER")
        podman export "$CID" | tar -xf - -C / usr/
        podman rm "$CID" >/dev/null
    elif command -v docker &>/dev/null; then
        CID=$(docker create "ghcr.io/linuxserver/selkies-layers:$KWIN_LAYER")
        docker export "$CID" | tar -xf - -C / usr/
        docker rm "$CID" >/dev/null
    fi
else
    echo "No Wayland KWin patch available for $DISTRO. Using X11 backend."
fi

setcap -r /usr/bin/kwin_wayland 2>/dev/null || setcap -r /usr/sbin/kwin_wayland 2>/dev/null || true

# Disable obexd D-Bus auto-activation to prevent crash loops in virtual/headless environments
if [ -f /usr/share/dbus-1/services/org.bluez.obex.service ]; then
    mv /usr/share/dbus-1/services/org.bluez.obex.service /usr/share/dbus-1/services/org.bluez.obex.service.disabled 2>/dev/null || true
fi

echo "Configuring desktop user ($DESKTOP_USER)..."
if ! id -u "$DESKTOP_USER" &>/dev/null; then
    useradd -m -s /bin/bash "$DESKTOP_USER"
    if [ -z "$DESKTOP_PASS" ]; then
        DESKTOP_PASS="$DESKTOP_USER"
    fi
    echo "${DESKTOP_USER}:${DESKTOP_PASS}" | chpasswd
elif [ "$SET_PASSWORD" = true ] && [ -n "$DESKTOP_PASS" ]; then
    echo "${DESKTOP_USER}:${DESKTOP_PASS}" | chpasswd
fi

USER_ID=$(id -u "$DESKTOP_USER")
USER_GROUP=$(id -gn "$DESKTOP_USER")

for grp in video audio input render wheel sudo; do
    if getent group "$grp" &>/dev/null; then
        usermod -aG "$grp" "$DESKTOP_USER" 2>/dev/null || true
    fi
done

echo "${DESKTOP_USER} ALL=(ALL) ALL" > "/etc/sudoers.d/${DESKTOP_USER}"
chmod 0440 "/etc/sudoers.d/${DESKTOP_USER}"

mkdir -p /var/lib/systemd/linger
touch "/var/lib/systemd/linger/${DESKTOP_USER}"
mkdir -pm1777 /tmp/.X11-unix

USER_HOME=$(eval echo "~${DESKTOP_USER}")
mkdir -p "${USER_HOME}/.config/systemd/user/default.target.wants"

for unit in pipewire.service pipewire-pulse.service wireplumber.service; do
    unit_path=""
    if [ -f "/usr/lib/systemd/user/${unit}" ]; then
        unit_path="/usr/lib/systemd/user/${unit}"
    elif [ -f "/lib/systemd/user/${unit}" ]; then
        unit_path="/lib/systemd/user/${unit}"
    fi
    if [ -n "$unit_path" ]; then
        ln -sf "$unit_path" "${USER_HOME}/.config/systemd/user/default.target.wants/${unit}"
        if [ "$unit" = "wireplumber.service" ]; then
            ln -sf "$unit_path" "${USER_HOME}/.config/systemd/user/pipewire-session-manager.service"
        fi
    fi
done
chown -R "${USER_ID}:${USER_GROUP}" "${USER_HOME}/.config"

# Write KDE keyboard layout config (kxkbrc) — KWin reads this on Wayland
echo "Configuring keyboard layout (${KEYBOARD_LAYOUTS})..."
mkdir -p "${USER_HOME}/.config"
{
    echo "[Layout]"
    echo "LayoutList=${KEYBOARD_LAYOUTS}"
    echo "Model=pc105"
    if [ -n "${KEYBOARD_VARIANTS}" ]; then
        echo "VariantList=${KEYBOARD_VARIANTS}"
    fi
    if [ -n "${KEYBOARD_OPTIONS}" ]; then
        echo "Options=${KEYBOARD_OPTIONS}"
        echo "ResetOldOptions=true"
    fi
    echo "Use=true"
} > "${USER_HOME}/.config/kxkbrc"
chown "${USER_ID}:${USER_GROUP}" "${USER_HOME}/.config/kxkbrc"

# Persist XKB layout system-wide (for localectl / X11 fallback)
PRIMARY_LAYOUT="${KEYBOARD_LAYOUTS%%,*}"
if command -v localectl &>/dev/null && pidof systemd &>/dev/null; then
    localectl set-x11-keymap "${PRIMARY_LAYOUT}" pc105 "${KEYBOARD_VARIANTS%%,*}" "${KEYBOARD_OPTIONS}" 2>/dev/null || true
fi

# Disable fwupd service in headless/container environments (crashes without EFI/hardware access)
systemctl disable fwupd.service 2>/dev/null || true
systemctl mask fwupd.service 2>/dev/null || true

echo "Deploying system services and updater..."
cat << 'EOF' > /usr/local/bin/start-selkies.sh
#!/bin/bash
set -e

export USER="${USER:-user}"
USER_ID="$(id -u "${USER}")"
export HOME="${HOME:-/home/${USER}}"
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/${USER_ID}}"
export PULSE_SERVER="${PULSE_SERVER:-unix:/run/user/${USER_ID}/pulse/native}"
export PIPEWIRE_RUNTIME_DIR="${PIPEWIRE_RUNTIME_DIR:-/run/user/${USER_ID}}"

for i in {1..30}; do
    [ -S "${PULSE_SERVER#unix:}" ] && break
    sleep 0.5
done

pactl load-module module-null-sink sink_name=output sink_properties=device.description=Output 2>/dev/null || true
pactl set-default-sink output 2>/dev/null || true

BACKEND="${SELKIES_BACKEND:-wayland}"
PORT="${SELKIES_PORT:-8080}"

if [ "$BACKEND" = "wayland" ] && ! command -v startplasma-wayland &>/dev/null; then
    echo "startplasma-wayland not found, falling back to x11 session..."
    BACKEND="x11"
fi

if [ "$BACKEND" = "wayland" ]; then
    exec /usr/bin/selkies-session \
        --wayland \
        --session=plasma \
        --public \
        --port="${PORT}" \
        --enable-https=true \
        --enable-basic-auth=false \
        --audio-device-name=output.monitor
else
    exec /usr/bin/selkies-session \
        --session=plasmax11 \
        --public \
        --port="${PORT}" \
        --enable-https=true \
        --enable-basic-auth=false \
        --audio-device-name=output.monitor
fi
EOF
chmod +x /usr/local/bin/start-selkies.sh

cat << 'EOF' > /usr/local/bin/selkies-sync
#!/bin/bash
set -u

echo "[selkies] Running post-update checks..."

# Ensure kwin capabilities remain stripped for unprivileged containers
setcap -r /usr/bin/kwin_wayland 2>/dev/null || setcap -r /usr/sbin/kwin_wayland 2>/dev/null || true

# Auto-sync latest scripts from GitHub repository if reachable
REPO_URL="${SELKIES_REPO_URL:-https://raw.githubusercontent.com/Den4enko/DahDesk/main}"
TMP_DIR=$(mktemp -d)

if curl -fsSL --max-time 2 "${REPO_URL}/systemd/start-selkies.sh" -o "${TMP_DIR}/start-selkies.sh" 2>/dev/null; then
    if [ -s "${TMP_DIR}/start-selkies.sh" ] && ! cmp -s "${TMP_DIR}/start-selkies.sh" /usr/local/bin/start-selkies.sh 2>/dev/null; then
        echo "[selkies] Updated start-selkies.sh from repository (takes effect on next session restart)."
        cp "${TMP_DIR}/start-selkies.sh" /usr/local/bin/start-selkies.sh
        chmod +x /usr/local/bin/start-selkies.sh
    fi
fi

rm -rf "${TMP_DIR}"

echo "[selkies] Post-transaction checks completed."
EOF
chmod +x /usr/local/bin/selkies-sync

echo "Configuring package manager post-transaction hooks..."
case "$DISTRO" in
    fedora)
        mkdir -p /etc/dnf/libdnf5-plugins/actions.d
        cat << "EOF" > /etc/dnf/libdnf5-plugins/actions.d/selkies-sync.actions
post_transaction:*:in::/usr/local/bin/selkies-sync
EOF
        ;;
    ubuntu|debian|kali)
        mkdir -p /etc/apt/apt.conf.d
        cat << "EOF" > /etc/apt/apt.conf.d/99selkies-sync
DPkg::Post-Invoke {"/usr/local/bin/selkies-sync || true";};
EOF
        ;;
    arch)
        mkdir -p /etc/pacman.d/hooks
        cat << "EOF" > /etc/pacman.d/hooks/selkies-sync.hook
[Trigger]
Operation = Install
Operation = Upgrade
Type = Package
Target = *

[Action]
Description = Syncing DahDesk scripts and permissions...
When = PostTransaction
Exec = /usr/local/bin/selkies-sync
EOF
        ;;
esac

cat << 'EOF' > /usr/local/bin/selkies-update
#!/bin/bash
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
    echo "Error: selkies-update must be run as root." >&2
    exit 1
fi

echo "Running system package updates..."
if command -v dnf &>/dev/null; then
    dnf update -y --disablerepo=fedora-cisco-openh264
elif command -v apt-get &>/dev/null; then
    apt-get update && apt-get upgrade -y
elif command -v pacman &>/dev/null; then
    pacman -Syu --noconfirm
fi
EOF
chmod +x /usr/local/bin/selkies-update

INITIAL_BACKEND="wayland"
if [ -n "$BACKEND_OVERRIDE" ]; then
    INITIAL_BACKEND="$BACKEND_OVERRIDE"
elif [ -z "$KWIN_LAYER" ]; then
    INITIAL_BACKEND="x11"
fi

# Build optional XKB env lines for the service unit
XKB_VARIANT_LINE=""
[ -n "${KEYBOARD_VARIANTS}" ] && XKB_VARIANT_LINE="Environment=XKB_DEFAULT_VARIANT=${KEYBOARD_VARIANTS}"
XKB_OPTIONS_LINE=""
[ -n "${KEYBOARD_OPTIONS}" ] && XKB_OPTIONS_LINE="Environment=XKB_DEFAULT_OPTIONS=${KEYBOARD_OPTIONS}"

cat << EOF > /etc/systemd/system/selkies.service
[Unit]
Description=DahDesk - KDE Desktop Streaming Service
After=user@${USER_ID}.service network.target sound.target
Wants=user@${USER_ID}.service

[Service]
TasksMax=infinity
Type=simple
User=${DESKTOP_USER}
Group=${USER_GROUP}
WorkingDirectory=${USER_HOME}
Environment=HOME=${USER_HOME}
Environment=USER=${DESKTOP_USER}
Environment=LOGNAME=${DESKTOP_USER}
Environment=XDG_RUNTIME_DIR=/run/user/${USER_ID}
Environment=PULSE_SERVER=unix:/run/user/${USER_ID}/pulse/native
Environment=SELKIES_BACKEND=${INITIAL_BACKEND}
Environment=SELKIES_PORT=${PORT}
Environment=XKB_DEFAULT_LAYOUT=${KEYBOARD_LAYOUTS}
Environment=XKB_DEFAULT_MODEL=pc105
${XKB_VARIANT_LINE}
${XKB_OPTIONS_LINE}
ExecStartPre=+/bin/sh -c "setcap -r /usr/bin/kwin_wayland 2>/dev/null || setcap -r /usr/sbin/kwin_wayland 2>/dev/null || true"
ExecStart=/usr/local/bin/start-selkies.sh
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable selkies.service 2>/dev/null || true
systemctl enable NetworkManager.service 2>/dev/null || true
systemctl enable sshd.service 2>/dev/null || systemctl enable ssh.service 2>/dev/null || true

if pidof systemd &>/dev/null; then
    systemctl restart selkies
fi

echo "=================================================="
echo "  DahDesk Installation Complete!"
echo "=================================================="
echo "Profile:      ${PROFILE}"
echo "Backend:      ${INITIAL_BACKEND}"
echo "Web URL:      https://<server-ip>:${PORT}/"
echo "Desktop User: ${DESKTOP_USER}"
if [ "$SET_PASSWORD" = true ]; then
    echo "Linux Pass:   [Configured - Hidden]"
fi
echo "HTTP Auth:    None (Direct Stream Access)"
echo "Updater:      sudo selkies-update"
echo "=================================================="
