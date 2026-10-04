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
GPU_OVERRIDE=""             # "true", "false", or "" (auto-detect)
RECONFIGURE=false
CONFIG_FILE="/etc/dahdesk/dahdesk.conf"
CONFIG_EXISTS=false

# Load previously saved configuration if present
if [ -f "$CONFIG_FILE" ]; then
    CONFIG_EXISTS=true
    # shellcheck source=/dev/null
    . "$CONFIG_FILE" 2>/dev/null || true
fi

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
        --gpu|--with-gpu|--enable-gpu)
            GPU_OVERRIDE="true"
            shift
            ;;
        --no-gpu|--without-gpu|--disable-gpu)
            GPU_OVERRIDE="false"
            shift
            ;;
        -r|--reconfigure)
            RECONFIGURE=true
            shift
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
            echo "  --gpu                      Force enable GPU acceleration (Mesa, VA-API, and video codecs)"
            echo "  --no-gpu                   Force disable GPU detection and use software rendering"
            echo "  --keyboard <layouts>       XKB keyboard layouts, comma-separated (e.g. 'us,ua')"
            echo "  --keyboard-variants <v>    XKB variants, comma-separated (e.g. ',phonetic')"
            echo "  --keyboard-options <opts>  XKB options (e.g. 'grp:alt_shift_toggle')"
            echo "  -r, --reconfigure          Ignore saved configuration and prompt for settings again"
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

if [ "${ID:-}" != "fedora" ] && [[ ! "${ID_LIKE:-}" =~ fedora ]]; then
    echo "Error: DahDesk only supports Fedora (Fedora 44+)." >&2
    exit 1
fi

ARCH="$(uname -m)"
case "$ARCH" in
    x86_64)
        LAYER_ARCH="amd64"
        SELKIES_ARCH="x86_64"
        ;;
    aarch64|arm64)
        LAYER_ARCH="arm64v8"
        SELKIES_ARCH="aarch64"
        ;;
    *)
        echo "Error: Unsupported CPU architecture ($ARCH)." >&2
        exit 1
        ;;
esac

DISTRO="fedora"
KWIN_LAYER="${LAYER_ARCH}-fedora44-kwin"

TARGET_BACKEND="Wayland (Native Zero-Copy)"
if [ -z "$KWIN_LAYER" ]; then
    TARGET_BACKEND="X11 (Fallback)"
fi
if [ -n "$BACKEND_OVERRIDE" ]; then
    TARGET_BACKEND="$BACKEND_OVERRIDE (Manual Override)"
fi

# Detect GPU availability and vendor
DETECTED_GPU=""
GPU_VENDOR=""
GPU_FOUND=false

detect_gpu() {
    # 1. Check NVIDIA device nodes
    if compgen -G "/dev/nvidia*" >/dev/null 2>&1; then
        GPU_FOUND=true
        GPU_VENDOR="nvidia"
        if [ -f /proc/driver/nvidia/version ]; then
            DETECTED_GPU="NVIDIA ($(head -n 1 /proc/driver/nvidia/version 2>/dev/null | awk '{print $1, $8}'))"
        elif command -v nvidia-smi &>/dev/null; then
            DETECTED_GPU="NVIDIA ($(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -n 1 || echo 'GPU'))"
        else
            DETECTED_GPU="NVIDIA GPU (/dev/nvidia*)"
        fi
    fi

    # 2. Check DRM devices in /dev/dri
    if compgen -G "/dev/dri/renderD*" >/dev/null 2>&1 || compgen -G "/dev/dri/card*" >/dev/null 2>&1; then
        GPU_FOUND=true
        if [ -z "$DETECTED_GPU" ]; then
            local vendor_id=""
            for dev in /sys/class/drm/card[0-9] /sys/class/drm/renderD[0-9]*; do
                if [ -r "${dev}/device/vendor" ]; then
                    vendor_id=$(cat "${dev}/device/vendor" 2>/dev/null || true)
                    break
                fi
            done
            case "$vendor_id" in
                0x8086)
                    DETECTED_GPU="Intel Graphics (DRI/VA-API)"
                    GPU_VENDOR="intel"
                    ;;
                0x1002)
                    DETECTED_GPU="AMD Radeon (DRI/VA-API)"
                    GPU_VENDOR="amd"
                    ;;
                0x10de)
                    DETECTED_GPU="NVIDIA GPU (DRI)"
                    GPU_VENDOR="nvidia"
                    ;;
                0x1af4)
                    DETECTED_GPU="VirtIO GPU (Virtual/DRI)"
                    GPU_VENDOR="virtual"
                    ;;
                0x15ad)
                    DETECTED_GPU="VMware SVGA (Virtual/DRI)"
                    GPU_VENDOR="virtual"
                    ;;
                *)
                    if command -v lspci &>/dev/null; then
                        local pci_gpu
                        pci_gpu=$(lspci 2>/dev/null | grep -iE 'vga|3d|display' | head -n 1 | sed 's/.*: //')
                        if [ -n "$pci_gpu" ]; then
                            DETECTED_GPU="$pci_gpu"
                            if echo "$pci_gpu" | grep -iq intel; then
                                GPU_VENDOR="intel"
                            elif echo "$pci_gpu" | grep -iqE "amd|radeon|ati"; then
                                GPU_VENDOR="amd"
                            elif echo "$pci_gpu" | grep -iq nvidia; then
                                GPU_VENDOR="nvidia"
                            fi
                        fi
                    fi
                    if [ -z "$DETECTED_GPU" ]; then
                        local dri_nodes
                        dri_nodes=$(ls -m /dev/dri/ 2>/dev/null | tr -d '\n')
                        DETECTED_GPU="DRM/DRI device (/dev/dri: ${dri_nodes})"
                        GPU_VENDOR="generic"
                    fi
                    ;;
            esac
        fi
    fi

    DRI_RENDER_NODE=""
    if compgen -G "/dev/dri/renderD*" >/dev/null 2>&1; then
        DRI_RENDER_NODE=$(ls /dev/dri/renderD* 2>/dev/null | head -n 1 || true)
    fi

    # 3. Fallback check sysfs DRM
    if [ "$GPU_FOUND" = false ] && compgen -G "/sys/class/drm/card*" >/dev/null 2>&1; then
        GPU_FOUND=true
        DETECTED_GPU="DRM Display Device (/sys/class/drm)"
        GPU_VENDOR="generic"
    fi
}

detect_gpu

if [ -n "$GPU_OVERRIDE" ]; then
    if [ "$GPU_OVERRIDE" = "true" ]; then
        GPU_ENABLED=true
        [ -z "$DETECTED_GPU" ] && DETECTED_GPU="Forced by --gpu"
        [ -z "$GPU_VENDOR" ] && GPU_VENDOR="generic"
    else
        GPU_ENABLED=false
        DETECTED_GPU="Disabled by --no-gpu"
        GPU_VENDOR=""
    fi
else
    GPU_ENABLED="$GPU_FOUND"
fi

# Detect existing non-root users (UID >= 1000 and not nobody)
mapfile -t DETECTED_USERS < <(awk -F: '$3 >= 1000 && $3 != 65534 && $7 !~ /(nologin|false)$/ {print $1}' /etc/passwd 2>/dev/null || true)

# Check if previously installed and not explicitly reconfiguring
if [ "$CONFIG_EXISTS" = true ] && [ "$RECONFIGURE" = false ]; then
    echo "=================================================="
    echo "   DahDesk - Existing Installation Detected"
    echo "=================================================="
    echo "Detected OS:       $DISTRO ($ARCH)"
    echo "Display Backend:   $TARGET_BACKEND"
    if [ "$GPU_ENABLED" = true ]; then
        echo "Hardware GPU:      Detected (${DETECTED_GPU})"
    else
        echo "Hardware GPU:      None detected (Software rendering)"
    fi
    echo ""
    echo "Using saved configuration from ${CONFIG_FILE}:"
    echo "  Profile:      ${PROFILE}"
    echo "  Desktop User: ${DESKTOP_USER}"
    echo "  Web Port:     ${PORT}"
    if [ "${KEYBOARD_LAYOUTS}" != "us" ]; then
        echo "  Keyboard:     ${KEYBOARD_LAYOUTS}${KEYBOARD_OPTIONS:+ ($KEYBOARD_OPTIONS)}"
    else
        echo "  Keyboard:     Universal Client-Sync (Auto layout from browser)"
    fi
    echo ""
    echo "  (Run with --reconfigure to change these settings)"
    echo "=================================================="
    NON_INTERACTIVE=true
fi

# Interactive configuration prompt
if [ "$NON_INTERACTIVE" = false ] && [ -c /dev/tty ]; then
    echo "=================================================="
    echo "   DahDesk - KDE Plasma Desktop Setup"
    echo "=================================================="
    echo "Detected OS:       $DISTRO ($ARCH)"
    echo "Display Backend:   $TARGET_BACKEND"
    if [ "$GPU_ENABLED" = true ]; then
        echo "Hardware GPU:      Detected (${DETECTED_GPU})"
    else
        echo "Hardware GPU:      None detected (Software rendering)"
    fi
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
    read -r -p "Enter choice [1-2] (default: 1): " choice_profile < /dev/tty || choice_profile=""
    choice_profile="${choice_profile:-1}"
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
        read -r -p "Enter choice [1-${idx}] (default: 1): " choice_user < /dev/tty || choice_user=""
        choice_user="${choice_user:-1}"

        if [[ "$choice_user" =~ ^[0-9]+$ ]] && [ "$choice_user" -ge 1 ] && [ "$choice_user" -le "${#DETECTED_USERS[@]}" ]; then
            DESKTOP_USER="${DETECTED_USERS[$((choice_user - 1))]}"
            echo "Selected existing user: ${DESKTOP_USER}"
            read -r -p "Change Linux password for '${DESKTOP_USER}'? [y/N]: " change_pass < /dev/tty || change_pass=""
            change_pass="${change_pass:-n}"
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
    read -r -p "[3/3] Web Streaming Port (default: $PORT): " input_port < /dev/tty || input_port=""
    PORT="${input_port:-$PORT}"

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
    echo "  Hardware GPU: $([ "$GPU_ENABLED" = true ] && echo "Enabled (${DETECTED_GPU})" || echo "Disabled (Software rendering)")"
    echo "  Desktop User: $DESKTOP_USER ($USER_STATUS)"
    echo "  Web Port:     $PORT"
    if [ "${KEYBOARD_LAYOUTS}" != "us" ]; then
        echo "  Keyboard:     ${KEYBOARD_LAYOUTS}${KEYBOARD_OPTIONS:+ ($KEYBOARD_OPTIONS)}"
    else
        echo "  Keyboard:     Universal Client-Sync (Auto layout from browser)"
    fi
    echo "  HTTP Auth:    Disabled (Direct Web Access)"
    echo "--------------------------------------------------"
    read -r -p "Proceed with installation? [Y/n]: " proceed < /dev/tty || proceed=""
    proceed="${proceed:-y}"
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
if [ "$GPU_ENABLED" = true ]; then
    echo "Hardware GPU acceleration enabled: ${DETECTED_GPU}"
else
    echo "Hardware GPU acceleration disabled / not detected (using software rendering)."
fi

case "$DISTRO" in
    fedora)
        BASE_PKGS=(
            systemd systemd-udev systemd-pam systemd-networkd systemd-resolved
            dbus dbus-tools dbus-x11 sudo procps-ng psmisc iproute net-tools curl tar libcap
            python3-dnf-plugin-versionlock libdnf5-plugin-actions NetworkManager openssh-server
            pipewire pipewire-pulse pipewire-utils wireplumber pulseaudio-utils
            xorg-x11-server-Xvfb xrandr xrdb libxkbcommon wl-clipboard xdotool
            kwin kwin-x11 breeze-icon-theme konsole plasma-desktop plasma-workspace plasma-workspace-x11
            dolphin plasma-systemsettings plasma-pa plasma-nm kwrite ark gwenview spectacle kdialog
            polkit polkit-kde xdg-desktop-portal xdg-desktop-portal-kde
        )
        if [ "$GPU_ENABLED" = true ]; then
            echo "Enabling RPM Fusion repositories for hardware video codecs..."
            dnf install -y --nogpgcheck \
                "https://mirrors.rpmfusion.org/free/fedora/rpmfusion-free-release-$(rpm -E %fedora).noarch.rpm" \
                "https://mirrors.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-$(rpm -E %fedora).noarch.rpm" 2>/dev/null || true

            echo "Configuring GPU acceleration packages for ${DETECTED_GPU}..."
            BASE_PKGS+=(
                mesa-dri-drivers
                mesa-vulkan-drivers
                mesa-libGL
                mesa-libEGL
                mesa-libgbm
                libva
                libva-utils
                gstreamer1-plugin-libav
                gstreamer1-plugins-bad-free
                gstreamer1-plugins-good
                gstreamer1-plugins-ugly-free
                gstreamer1-vaapi
            )

            # Vendor-targeted hardware video decoding drivers
            if [ "$ARCH" = "x86_64" ]; then
                case "$GPU_VENDOR" in
                    intel)
                        BASE_PKGS+=(
                            intel-media-driver
                            libva-intel-driver
                        )
                        ;;
                    nvidia)
                        BASE_PKGS+=(
                            libva-nvidia-driver
                        )
                        ;;
                    amd)
                        # AMD uses radeonsi_drv_video.so (part of mesa-dri-drivers on F44+).
                        # On older Fedora releases, mesa-va-drivers-freeworld provides hardware decoding.
                        BASE_PKGS+=(
                            mesa-va-drivers-freeworld
                        )
                        ;;
                    *)
                        BASE_PKGS+=(
                            mesa-va-drivers-freeworld
                            intel-media-driver
                        )
                        ;;
                esac
            fi
        fi

        echo "Installing distribution and desktop packages..."
        dnf install -y --setopt=install_weak_deps=False --nodocs --skip-unavailable --allowerasing "${BASE_PKGS[@]}"

        if [ "$PROFILE" = "full" ]; then
            echo "Installing complete Fedora KDE Desktop group..."
            dnf group install -y --setopt=install_weak_deps=False kde-desktop || true
            dnf install -y --setopt=install_weak_deps=False \
                chromium || true
        fi
        ;;
esac

echo "Installing Selkies Streamer package..."
case "$DISTRO" in
    fedora)
        RPM_URL="https://github.com/selkies-project/selkies/releases/download/${SELKIES_VERSION}/selkies-${SELKIES_VERSION}-fc-${SELKIES_ARCH}.rpm"
        dnf install -y "$RPM_URL"
        dnf versionlock add kwin kwin-libs kwin-x11 kwin-common selkies wl-clipboard 2>/dev/null || true
        ;;
esac

echo "Checking Rust wl-clipboard (wl-clipboard-rs-tools)..."
_install_rust_wl_clipboard() {
    if [ -x /usr/local/bin/wl-copy ] && /usr/local/bin/wl-copy --version 2>&1 | grep -qE "^wl-copy [0-9]"; then
        echo "Rust wl-clipboard is already installed ($( /usr/local/bin/wl-copy --version 2>&1 | head -n 1 ))."
        cp -f /usr/local/bin/wl-copy /usr/local/bin/wl-paste /usr/bin/ 2>/dev/null || true
        return 0
    fi

    echo "Building Rust wl-clipboard (wl-clipboard-rs-tools) for improved clipboard performance..."
    local _CARGO_HOME="/root/.cargo-wl-tmp"
    if ! command -v cargo &>/dev/null; then
        echo "Installing Rust and Cargo toolchain..."
        dnf install -y --setopt=install_weak_deps=False --nodocs cargo rust || return 0
    fi
    CARGO_HOME="$_CARGO_HOME" cargo install --force --root /usr/local wl-clipboard-rs-tools \
        2>&1 | tail -5 || true
    rm -rf "$_CARGO_HOME"
    if [ -x /usr/local/bin/wl-copy ]; then
        cp -f /usr/local/bin/wl-copy /usr/local/bin/wl-paste /usr/bin/ 2>/dev/null || true
    fi
    if [ -x /usr/bin/wl-copy ] && /usr/bin/wl-copy --version 2>&1 | grep -qE "^wl-copy [0-9]"; then
        echo "Rust wl-clipboard installed successfully ($( /usr/bin/wl-copy --version 2>&1 | head -n 1 ))."
    else
        echo "Warning: Rust wl-clipboard build failed; keeping system version."
    fi
}
_install_rust_wl_clipboard

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

    # Update library cache and ensure libkwin symlink points to patched binary
    for kwin_dir in /usr/lib64 /usr/lib; do
        if [ -d "$kwin_dir" ]; then
            latest_kwin=$(find "$kwin_dir" -maxdepth 1 -name "libkwin.so.6.*" 2>/dev/null | sort -V | tail -n 1 || true)
            if [ -n "$latest_kwin" ] && [ -f "$latest_kwin" ]; then
                ln -sf "$(basename "$latest_kwin")" "${kwin_dir}/libkwin.so.6" 2>/dev/null || true
            fi
        fi
    done
    ldconfig 2>/dev/null || true
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
loginctl enable-linger "${DESKTOP_USER}" 2>/dev/null || true
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

# Setup KWin helper rules for seamless clipboard/input injection
if [ ! -f "${USER_HOME}/.config/kwinrulesrc" ]; then
    cat << 'EOF' > "${USER_HOME}/.config/kwinrulesrc"
[General]
count=1
rules=1

[1]
Description=wl-clipboard support
fsplevel=3
fsplevelrule=2
noborder=true
noborderrule=2
skipswitcher=true
skipswitcherrule=2
skiptaskbar=true
skiptaskbarrule=2
wmclass=wl-(copy|paste)
wmclassmatch=3
EOF
    chown "${USER_ID}:${USER_GROUP}" "${USER_HOME}/.config/kwinrulesrc"
fi

# Strip plasma-keyboard virtual keyboard settings from Fedora KDE profile to prevent input interception
for rc in /usr/share/kde-settings/kde-profile/default/xdg/kwinrc /etc/xdg/kwinrc "${USER_HOME}/.config/kwinrc"; do
    if [ -f "$rc" ]; then
        sed -i -e '/^InputMethod/d' -e '/^VirtualKeyboardEnabled/d' "$rc" 2>/dev/null || true
    fi
done

# Configure keyboard layout (Universal client-sync or custom XKB)
mkdir -p "${USER_HOME}/.config"
if [ "${KEYBOARD_LAYOUTS}" != "us" ]; then
    echo "Configuring custom guest keyboard layout (${KEYBOARD_LAYOUTS})..."
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
else
    echo "Universal keyboard mode enabled: client layouts handled dynamically via Selkies."
    rm -f "${USER_HOME}/.config/kxkbrc"
fi

# Configure Konsole shortcut for Ctrl+V paste (allows universal typing/paste fallback in terminal)
for kdir in "${USER_HOME}/.local/share/kxmlgui6/konsole" "${USER_HOME}/.config/kxmlgui6/konsole"; do
    mkdir -p "${kdir}"
    if [ ! -f "${kdir}/konsoleui.rc" ]; then
        cat << 'EOF' > "${kdir}/konsoleui.rc"
<!DOCTYPE gui SYSTEM 'kpartgui.dtd'>
<gui name="konsole" version="1">
 <ActionProperties>
  <Action name="edit_paste" shortcut="Ctrl+V; Ctrl+Shift+V; Shift+Ins"/>
 </ActionProperties>
</gui>
EOF
    fi
done
chown -R "${USER_ID}:${USER_GROUP}" "${USER_HOME}/.local" "${USER_HOME}/.config"

# Disable fwupd and power management sleep targets in headless/container environments
systemctl disable fwupd.service 2>/dev/null || true
systemctl mask fwupd.service sleep.target suspend.target hibernate.target hybrid-sleep.target 2>/dev/null || true

echo "Deploying system services and updater..."
cat << 'EOF' > /usr/local/bin/selkies-patch-input
#!/usr/bin/env python3
import glob
import os
import pwd
import re
import sys

def patch_selkies_core_js():
    patterns = [
        "/opt/selkies/lib/python*/site-packages/selkies/selkies_web/src/selkies-core.js",
        "/opt/selkies/lib64/python*/site-packages/selkies/selkies_web/src/selkies-core.js",
        "/usr/lib/python*/site-packages/selkies/selkies_web/src/selkies-core.js",
        "/usr/lib64/python*/site-packages/selkies/selkies_web/src/selkies-core.js",
        "/usr/local/lib/python*/site-packages/selkies/selkies_web/src/selkies-core.js",
    ]
    target_files = []
    for p in patterns:
        target_files.extend(glob.glob(p))

    old_arms = [
        "this._altGrTimeout=setTimeout(()=>{this._altGrArmed=!1,this._sendKeyEvent(A.XK_Control_L,`ControlLeft`,!0)},20);return",
        "this._altGrTimeout=setTimeout(()=>{this._altGrArmed=!1,this._sendKeyEvent(A.XK_Control_L,`ControlLeft`,!0)},100);return",
        "this._altGrTimeout=setTimeout(()=>{this._altGrArmed=!1,this._sendKeyEvent(A.XK_Control_L,`ControlLeft`,!0)},20)",
        "this._altGrTimeout=setTimeout(()=>{this._altGrArmed=!1,this._sendKeyEvent(A.XK_Control_L,`ControlLeft`,!0)},100)",
    ]
    new_arm = "this._sendKeyEvent(A.XK_Control_L,`ControlLeft`,!0);return"

    old_altright = "r===`AltRight`&&t.timeStamp-this._altGrCtrlTime<50?i=A.XK_ISO_Level3_Shift:this._sendKeyEvent(A.XK_Control_L,`ControlLeft`,!0)"
    new_altright = "r===`AltRight`&&t.timeStamp-this._altGrCtrlTime<50?(this._sendKeyEvent(A.XK_Control_L,`ControlLeft`,!1),i=A.XK_ISO_Level3_Shift):null"

    for file_path in target_files:
        try:
            with open(file_path, "r", encoding="utf-8") as f:
                content = f.read()

            changed = False
            for old_arm in old_arms:
                if old_arm in content:
                    content = content.replace(old_arm, new_arm)
                    changed = True

            if old_altright in content:
                content = content.replace(old_altright, new_altright)
                changed = True

            if changed:
                with open(file_path, "w", encoding="utf-8") as f:
                    f.write(content)
                print(f"[selkies-patch-input] Applied AltGr/Ctrl immediate dispatch fix to: {file_path}")
        except Exception as e:
            print(f"[selkies-patch-input] Warning: failed patching {file_path}: {e}", file=sys.stderr)

def patch_selkies_input():
    patterns = [
        "/opt/selkies/lib/python*/site-packages/selkies/input_handler.py",
        "/opt/selkies/lib64/python*/site-packages/selkies/input_handler.py",
        "/usr/lib/python*/site-packages/selkies/input_handler.py",
        "/usr/lib64/python*/site-packages/selkies/input_handler.py",
        "/usr/local/lib/python*/site-packages/selkies/input_handler.py",
    ]

    target_files = []
    for p in patterns:
        target_files.extend(glob.glob(p))

    new_inject_fn = '''    async def _inject_text_via_clipboard(self, text: str) -> bool:
        """Type `text` via clipboard with debounced restore and zero typing lag."""
        async with self._clipboard_inject_lock:
            self._clipboard_inject_active = True
            held_modifiers = list(self.active_modifiers)
            try:
                for mod_keysym in held_modifiers:
                    await self.send_x11_keypress(mod_keysym, down=False)

                # Cancel any pending restore from previous keystrokes
                restore_task = getattr(self, '_clipboard_restore_task', None)
                if restore_task and not restore_task.done():
                    restore_task.cancel()

                # Save the user's real clipboard once before consecutive typing starts
                if getattr(self, '_saved_user_clipboard', None) is None:
                    try:
                        old_data, old_mime = await self.read_clipboard(use_binary=True)
                        self._saved_user_clipboard = (old_data, old_mime)
                    except Exception:
                        self._saved_user_clipboard = (None, None)

                if not await self.write_clipboard(text):
                    return False

                # Fast, reliable Ctrl+V chord (~60ms total chord window)
                ctrl_keysym = 0xFFE1  # Shift (Shift+Insert paste works in terminals too)
                v_keysym = 0xFF63  # Insert
                await asyncio.sleep(0.01)
                await self.send_x11_keypress(ctrl_keysym, down=True)
                await asyncio.sleep(0.02)
                await self.send_x11_keypress(v_keysym, down=True, neutralize=False)
                await asyncio.sleep(0.02)
                await self.send_x11_keypress(v_keysym, down=False)
                await asyncio.sleep(0.01)
                await self.send_x11_keypress(ctrl_keysym, down=False)

                # Debounced asynchronous restore: wait 0.6s of typing idle before restoring
                async def _restore_after_idle():
                    try:
                        await asyncio.sleep(0.6)
                        saved = getattr(self, '_saved_user_clipboard', None)
                        self._saved_user_clipboard = None
                        if saved:
                            data, mime = saved
                            if data is not None:
                                await self.write_clipboard(data, mime or "text/plain")
                            elif self.is_wayland:
                                await self._clear_injected_clipboard()
                    except asyncio.CancelledError:
                        pass
                    except Exception as err:
                        logger_webrtc_input.debug(f"debounced clipboard restore failed: {err}")

                self._clipboard_restore_task = asyncio.create_task(_restore_after_idle())
                return True
            except Exception as e:
                logger_webrtc_input.error(f"Clipboard text injection failed: {e}")
                return False
            finally:
                for mod_keysym in held_modifiers:
                    if mod_keysym in self.active_modifiers:
                        await self.send_x11_keypress(mod_keysym, down=True)
                self._clipboard_inject_active = False
\n'''

    old_timeout = 'msg_type, data = await asyncio.wait_for(self.keyboard_queue.get(), timeout=0.05)'
    new_timeout = 'msg_type, data = await asyncio.wait_for(self.keyboard_queue.get(), timeout=0.015)'

    inject_pattern = re.compile(
        r'    async def _inject_text_via_clipboard\(self, text: str\) -> bool:.*?\n    async def _clear_injected_clipboard',
        re.DOTALL
    )

    cyr_builder = """
def _build_cyrillic_qwerty_map():
    key_pairs = [
        ('q', 'й'), ('w', 'ц'), ('e', 'у'), ('r', 'к'), ('t', 'е'),
        ('y', 'н'), ('u', 'г'), ('i', 'ш'), ('o', 'щ'), ('p', 'з'),
        ('[', 'х'), (']', 'ъ'), (']', 'ї'),
        ('a', 'ф'), ('s', 'ы'), ('s', 'і'), ('d', 'в'), ('f', 'а'),
        ('g', 'п'), ('h', 'р'), ('j', 'о'), ('k', 'л'), ('l', 'д'),
        (';', 'ж'), ("'", 'э'), ("'", 'є'),
        ('z', 'я'), ('x', 'ч'), ('c', 'с'), ('v', 'м'), ('b', 'и'),
        ('n', 'т'), ('m', 'ь'), (',', 'б'), ('.', 'ю'),
        ('`', 'ё'), ('\\\\', 'ґ')
    ]
    x11_legacy = {
        'а': 0x06C1, 'б': 0x06C2, 'в': 0x06D7, 'г': 0x06C7, 'д': 0x06C4,
        'е': 0x06C5, 'ё': 0x06A3, 'ж': 0x06D6, 'з': 0x06DA, 'и': 0x06C9,
        'й': 0x06CA, 'к': 0x06CB, 'л': 0x06CC, 'м': 0x06CD, 'н': 0x06CE,
        'о': 0x06CF, 'п': 0x06D0, 'р': 0x06D2, 'с': 0x06D3, 'т': 0x06D4,
        'у': 0x06D5, 'ф': 0x06C6, 'х': 0x06C8, 'ц': 0x06C3, 'ч': 0x06DE,
        'ш': 0x06DB, 'щ': 0x06DD, 'ъ': 0x06DF, 'ы': 0x06D9, 'ь': 0x06D8,
        'э': 0x06DC, 'ю': 0x06C0, 'я': 0x06D1,
        'є': 0x06A4, 'і': 0x06A6, 'ї': 0x06A7, 'ґ': 0x06AD
    }
    m = {}
    for latin, cyr in key_pairs:
        lat_lower = ord(latin.lower())
        lat_upper = ord(latin.upper())
        m[0x01000000 | ord(cyr.lower())] = lat_lower
        m[0x01000000 | ord(cyr.upper())] = lat_upper
        m[ord(cyr.lower())] = lat_lower
        m[ord(cyr.upper())] = lat_upper
        if cyr in x11_legacy:
            leg_lower = x11_legacy[cyr]
            leg_upper = leg_lower + 0x20 if leg_lower >= 0x06C0 else leg_lower - 0x10
            m[leg_lower] = lat_lower
            m[leg_upper] = lat_upper
    return m

CYRILLIC_TO_QWERTY_KEYSYM.update(_build_cyrillic_qwerty_map())
"""

    old_block_1 = """                    if msg_type == "kd":
                        if (is_unicode_fallback and not native_inject()
                                and (not self.active_modifiers
                                     or self._has_separate_app_compositor())):"""

    new_block_1 = """                    if msg_type == "kd":
                        if (is_unicode_fallback and not native_inject()
                                and not (self.active_modifiers & self.ACTION_MODIFIER_KEYSYMS)
                                and (not self.active_modifiers
                                     or self._has_separate_app_compositor())):"""

    old_block_2 = """                        if (not is_unicode_fallback
                                and keysym is not None and not native_inject()
                                and keysym not in self.MODIFIER_KEYSYMS
                                and not ((self.active_modifiers & self.ACTION_MODIFIER_KEYSYMS)
                                         and keysym in CYRILLIC_TO_QWERTY_KEYSYM)):
                            char_to_type = keysym_to_character(keysym)
                            if char_to_type is not None:
                                owner = await self._ensure_wayland_keymap_owner()
                                if owner is None or not owner.resolves(keysym):
                                    unicode_buffer.append(char_to_type)
                                    self._route_key_as_text(keysym)
                                    continue"""

    clean_block_2 = """                        if (not is_unicode_fallback
                                and keysym is not None and not native_inject()
                                and keysym not in self.MODIFIER_KEYSYMS
                                and not (self.active_modifiers & self.ACTION_MODIFIER_KEYSYMS)):
                            char_to_type = keysym_to_character(keysym)
                            if char_to_type is not None:
                                owner = await self._ensure_wayland_keymap_owner()
                                if owner is None or not owner.resolves(keysym):
                                    unicode_buffer.append(char_to_type)
                                    self._route_key_as_text(keysym)
                                    continue"""

    level_match_block = """                        if (not is_unicode_fallback
                                and keysym is not None and not native_inject()
                                and keysym not in self.MODIFIER_KEYSYMS
                                and not (self.active_modifiers & self.ACTION_MODIFIER_KEYSYMS)):
                            char_to_type = keysym_to_character(keysym)
                            if char_to_type is not None:
                                owner = await self._ensure_wayland_keymap_owner()
                                level_match = False
                                if owner is not None and owner.resolves(keysym):
                                    resolved = getattr(owner, '_map', {}).get(keysym)
                                    if resolved is not None:
                                        _, lvl = resolved
                                        shift_needed = bool(lvl & 1)
                                        shift_held = bool(self.active_modifiers & {0xFFE1, 0xFFE2})
                                        altgr_needed = bool(lvl & 2)
                                        altgr_held = bool(self.active_modifiers & {0xFE03, 0xFF7E, 65027})
                                        level_match = (shift_needed == shift_held and altgr_needed == altgr_held)
                                if not level_match:
                                    unicode_buffer.append(char_to_type)
                                    self._route_key_as_text(keysym)
                                    continue"""

    old_block_3 = """                        if keysym in self.MODIFIER_KEYSYMS:
                            self.active_modifiers.add(keysym)

                        await self.send_x11_keypress(keysym, down=True)"""

    new_block_3 = """                        if keysym in self.MODIFIER_KEYSYMS:
                            self.active_modifiers.add(keysym)

                        await self.send_x11_keypress(keysym, down=True)
                        if keysym in self.ACTION_MODIFIER_KEYSYMS:
                            await asyncio.sleep(0.005)"""

    old_wl_press_release = '''        lifted = self._held_conflicts(set(mods)) if neutralize else []
        for m in lifted:
            self._inject(m, 0)
        synthed = []
        for m in mods:
            already = (m in self._down
                       or (m == self._shift_kc and self._shift_r_kc in self._down))
            if already and m not in self._mod_refs:
                continue
            self._mod_refs[m] = self._mod_refs.get(m, 0) + 1
            if self._mod_refs[m] == 1:
                self._inject(m, 1)
            synthed.append(m)
        self._pressed[keysym] = (kc, tuple(synthed))
        self._inject(kc, 1)
        for m in reversed(lifted):
            self._inject(m, 1)

    def release(self, keysym: int) -> None:
        """Release a pressed keysym and un-refcount the modifiers its press synthesized."""
        held = self._pressed.pop(keysym, None)
        if held is None:
            return
        kc, mods = held
        self._inject(kc, 0)
        for m in reversed(mods):
            refs = self._mod_refs.get(m, 0) - 1
            if refs <= 0:
                self._mod_refs.pop(m, None)
                self._inject(m, 0)
            else:
                self._mod_refs[m] = refs'''

    new_wl_press_release = '''        lifted = self._held_conflicts(set(mods)) if neutralize else []
        for m in lifted:
            self._inject(m, 0)
        if lifted:
            time.sleep(0.005)
        synthed = []
        for m in mods:
            already = (m in self._down
                       or (m == self._shift_kc and self._shift_r_kc in self._down))
            if already and m not in self._mod_refs:
                continue
            self._mod_refs[m] = self._mod_refs.get(m, 0) + 1
            if self._mod_refs[m] == 1:
                self._inject(m, 1)
            synthed.append(m)
        self._pressed[keysym] = (kc, tuple(synthed), tuple(lifted))
        self._inject(kc, 1)

    def release(self, keysym: int) -> None:
        """Release a pressed keysym and un-refcount the modifiers its press synthesized."""
        held = self._pressed.pop(keysym, None)
        if held is None:
            return
        kc = held[0]
        mods = held[1]
        lifted = held[2] if len(held) > 2 else ()
        self._inject(kc, 0)
        for m in reversed(mods):
            refs = self._mod_refs.get(m, 0) - 1
            if refs <= 0:
                self._mod_refs.pop(m, None)
                self._inject(m, 0)
            else:
                self._mod_refs[m] = refs
        if lifted:
            time.sleep(0.005)
            active_mods = getattr(self, 'active_modifiers', None)
            for m in reversed(lifted):
                should_restore = True
                if active_mods is not None:
                    if m == self._shift_kc and 0xFFE1 not in active_mods:
                        should_restore = False
                    elif m == self._shift_r_kc and 0xFFE2 not in active_mods:
                        should_restore = False
                    elif m == self._altgr_kc and not (active_mods & {0xFE03, 0xFF7E, 65027}):
                        should_restore = False
                if should_restore and m not in self._down:
                    self._inject(m, 1)'''

    old_owner_build = '''                def _build():
                    text = self.wayland_input.get_xkb_keymap_string()
                    owner = _WaylandKeymapOwner(self.wayland_input, text)
                    if previous is not None:
                        owner.adopt_held(previous)
                    return owner'''

    new_owner_build = '''                def _build():
                    text = self.wayland_input.get_xkb_keymap_string()
                    owner = _WaylandKeymapOwner(self.wayland_input, text)
                    owner.active_modifiers = self.active_modifiers
                    if previous is not None:
                        owner.adopt_held(previous)
                    return owner'''

    old_owner_cached = '''        if self._wl_keymap_owner is not None and not self._wl_keymap_stale:
            return self._wl_keymap_owner'''

    new_owner_cached = '''        if self._wl_keymap_owner is not None and not self._wl_keymap_stale:
            self._wl_keymap_owner.active_modifiers = self.active_modifiers
            return self._wl_keymap_owner'''

    old_xtest = '''        xtest.fake_input(self._d, Xlib.X.KeyPress, kc)
        self._pressed_kc[keysym] = kc
        for m in reversed(lifted):
            xtest.fake_input(self._d, Xlib.X.KeyPress, m)
        self._d.flush()

    def release(self, keysym: int) -> None:
        """Release a keysym, replaying its press-time keycode.

        Only an untracked press is re-resolved: the layout may have changed
        mid-keystroke, so a re-resolve of a tracked one could miss the key.
        """
        kc = self._pressed_kc.pop(keysym, None)
        if kc is None:
            kc, _, _ = self._resolve(keysym)
            self._settle()
        self._leave_group(keysym)
        xtest.fake_input(self._d, Xlib.X.KeyRelease, kc)
        for m in reversed(self._synth_mods.pop(keysym, ())):
            xtest.fake_input(self._d, Xlib.X.KeyRelease, m)'''

    new_xtest = '''        if lifted:
            if not hasattr(self, '_lifted_mods'):
                self._lifted_mods = {}
            self._lifted_mods[keysym] = tuple(lifted)
        xtest.fake_input(self._d, Xlib.X.KeyPress, kc)
        self._pressed_kc[keysym] = kc
        self._d.flush()

    def release(self, keysym: int) -> None:
        """Release a keysym, replaying its press-time keycode.

        Only an untracked press is re-resolved: the layout may have changed
        mid-keystroke, so a re-resolve of a tracked one could miss the key.
        """
        kc = self._pressed_kc.pop(keysym, None)
        if kc is None:
            kc, _, _ = self._resolve(keysym)
            self._settle()
        self._leave_group(keysym)
        xtest.fake_input(self._d, Xlib.X.KeyRelease, kc)
        for m in reversed(self._synth_mods.pop(keysym, ())):
            xtest.fake_input(self._d, Xlib.X.KeyRelease, m)
        for m in reversed(getattr(self, '_lifted_mods', {}).pop(keysym, ())):
            xtest.fake_input(self._d, Xlib.X.KeyPress, m)'''

    for file_path in target_files:
        try:
            with open(file_path, "r", encoding="utf-8") as f:
                content = f.read()

            changed = False
            if '_restore_after_idle' not in content and inject_pattern.search(content):
                content = inject_pattern.sub(new_inject_fn + '    async def _clear_injected_clipboard', content)
                changed = True

            if old_timeout in content:
                content = content.replace(old_timeout, new_timeout)
                changed = True

            if "ctrl_keysym = 0xFFE3" in content and "_restore_after_idle" in content:
                content = content.replace("ctrl_keysym = 0xFFE3", "ctrl_keysym = 0xFFE1").replace("v_keysym = 0x0076", "v_keysym = 0xFF63")
                changed = True

            if "_build_cyrillic_qwerty_map" not in content and "CYRILLIC_TO_QWERTY_KEYSYM = {" in content:
                idx = content.find("CYRILLIC_TO_QWERTY_KEYSYM = {")
                end_idx = content.find("}", idx) + 1
                content = content[:end_idx] + "\n" + cyr_builder + content[end_idx:]
                changed = True

            if "not (self.active_modifiers & self.ACTION_MODIFIER_KEYSYMS)" not in content and old_block_1 in content:
                content = content.replace(old_block_1, new_block_1)
                changed = True

            if clean_block_2 in content:
                content = content.replace(clean_block_2, level_match_block)
                changed = True
            elif old_block_2 in content:
                content = content.replace(old_block_2, level_match_block)
                changed = True

            if "await asyncio.sleep(0.02)" in content:
                content = content.replace("await asyncio.sleep(0.02)", "await asyncio.sleep(0.005)")
                changed = True
            elif "await asyncio.sleep(0.015)" in content:
                content = content.replace("await asyncio.sleep(0.015)", "await asyncio.sleep(0.005)")
                changed = True
            elif "await asyncio.sleep(0.005)" not in content and old_block_3 in content:
                content = content.replace(old_block_3, new_block_3)
                changed = True

            if old_wl_press_release in content:
                content = content.replace(old_wl_press_release, new_wl_press_release)
                changed = True

            if old_owner_build in content:
                content = content.replace(old_owner_build, new_owner_build)
                changed = True

            if old_owner_cached in content:
                content = content.replace(old_owner_cached, new_owner_cached)
                changed = True

            if old_xtest in content:
                content = content.replace(old_xtest, new_xtest)
                changed = True

            if changed:
                with open(file_path, "w", encoding="utf-8") as f:
                    f.write(content)
                print(f"[selkies-patch-input] Applied input chord/timing fix to: {file_path}")
        except Exception as e:
            print(f"[selkies-patch-input] Warning: failed patching {file_path}: {e}", file=sys.stderr)

    # Configure Konsole shortcut to paste on Ctrl+V in addition to standard terminal paste shortcuts
    konsole_xml = """<!DOCTYPE gui SYSTEM 'kpartgui.dtd'>
<gui name="konsole" version="1">
 <ActionProperties>
  <Action name="edit_paste" shortcut="Ctrl+V; Ctrl+Shift+V; Shift+Ins"/>
 </ActionProperties>
</gui>
"""
    # System-wide
    for sys_dir in ["/etc/xdg/kxmlgui6/konsole", "/etc/xdg/ui"]:
        try:
            os.makedirs(sys_dir, exist_ok=True)
            kfile = os.path.join(sys_dir, "konsoleui.rc")
            if not os.path.exists(kfile):
                with open(kfile, "w", encoding="utf-8") as f:
                    f.write(konsole_xml)
        except Exception:
            pass

    # User homes
    try:
        for u in pwd.getpwall():
            if u.pw_uid >= 1000 and os.path.isdir(u.pw_dir):
                for sub in [".local/share/kxmlgui6/konsole", ".config/kxmlgui6/konsole"]:
                    user_kdir = os.path.join(u.pw_dir, sub)
                    try:
                        os.makedirs(user_kdir, exist_ok=True)
                        user_kfile = os.path.join(user_kdir, "konsoleui.rc")
                        if not os.path.exists(user_kfile):
                            with open(user_kfile, "w", encoding="utf-8") as f:
                                f.write(konsole_xml)
                            os.chown(user_kfile, u.pw_uid, u.pw_gid)
                        os.chown(user_kdir, u.pw_uid, u.pw_gid)
                    except Exception:
                        pass
    except Exception:
        pass

def patch_selkies_session():
    patterns = [
        "/opt/selkies/lib/python*/site-packages/selkies/session.py",
        "/opt/selkies/lib64/python*/site-packages/selkies/session.py",
        "/usr/lib/python*/site-packages/selkies/session.py",
        "/usr/lib64/python*/site-packages/selkies/session.py",
        "/usr/local/lib/python*/site-packages/selkies/session.py",
    ]

    target_files = []
    for p in patterns:
        target_files.extend(glob.glob(p))

    for file_path in target_files:
        try:
            with open(file_path, "r", encoding="utf-8") as f:
                content = f.read()

            changed = False

            old_spawn = 'self.spawn(bus + shlex.split(entry["Exec"]), env=env)'
            new_spawn = 'proc = self.spawn(bus + shlex.split(entry["Exec"]), env=env)\n        self.desktop_proc = proc\n        return proc'

            if old_spawn in content and 'self.desktop_proc = ' not in content:
                content = content.replace(old_spawn, new_spawn)
                changed = True

            old_loop = '''        while session.selkies.poll() is None and not stopping:
            time.sleep(0.5)'''

            new_loop = '''        while session.selkies.poll() is None and not stopping:
            dproc = getattr(session, "desktop_proc", None)
            if dproc is not None and dproc.poll() is not None:
                log(f"desktop session exited with code {dproc.returncode}; stopping session for auto-restart")
                break
            time.sleep(0.5)'''

            if old_loop in content and 'dproc = ' not in content:
                content = content.replace(old_loop, new_loop)
                changed = True

            if changed:
                with open(file_path, "w", encoding="utf-8") as f:
                    f.write(content)
                print(f"[selkies-patch-input] Applied session auto-restart on logout fix to: {file_path}")
        except Exception as e:
            print(f"[selkies-patch-input] Warning: failed patching session {file_path}: {e}", file=sys.stderr)

def patch_kwin_settings():
    kwinrc_paths = [
        "/usr/share/kde-settings/kde-profile/default/xdg/kwinrc",
        "/etc/xdg/kwinrc",
    ]
    try:
        for u in pwd.getpwall():
            if u.pw_uid >= 1000 and os.path.isdir(u.pw_dir):
                kwinrc_paths.append(os.path.join(u.pw_dir, ".config/kwinrc"))
    except Exception:
        pass

    for p in kwinrc_paths:
        if os.path.exists(p):
            try:
                with open(p, "r", encoding="utf-8") as f:
                    lines = f.readlines()
                new_lines = [l for l in lines if not l.startswith("InputMethod") and not l.startswith("VirtualKeyboardEnabled")]
                if len(new_lines) != len(lines):
                    with open(p, "w", encoding="utf-8") as f:
                        f.writelines(new_lines)
                    print(f"[selkies-patch-input] Stripped plasma-keyboard settings from: {p}")
            except Exception as e:
                pass

if __name__ == "__main__":
    patch_selkies_core_js()
    patch_selkies_input()
    patch_selkies_session()
    patch_kwin_settings()
EOF
chmod +x /usr/local/bin/selkies-patch-input
/usr/local/bin/selkies-patch-input || true

cat << 'EOF' > /usr/local/bin/start-selkies.sh
#!/bin/bash
set -e

export USER="${USER:-user}"
USER_ID="$(id -u "${USER}")"
export HOME="${HOME:-/home/${USER}}"
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/${USER_ID}}"
export PULSE_SERVER="${PULSE_SERVER:-unix:/run/user/${USER_ID}/pulse/native}"
export PIPEWIRE_RUNTIME_DIR="${PIPEWIRE_RUNTIME_DIR:-/run/user/${USER_ID}}"
export KWIN_WAYLAND_NO_PERMISSION_CHECKS=1

mkdir -pm1777 /tmp/.X11-unix 2>/dev/null || true

# Ensure non-US/Cyrillic keyboard input fix is applied
if [ -x /usr/local/bin/selkies-patch-input ]; then
    /usr/local/bin/selkies-patch-input 2>/dev/null || true
fi

# Strip plasma-keyboard virtual keyboard settings from Fedora KDE profile to prevent input interception
for rc in /usr/share/kde-settings/kde-profile/default/xdg/kwinrc /etc/xdg/kwinrc "${HOME}/.config/kwinrc"; do
    if [ -f "$rc" ]; then
        sed -i -e '/^InputMethod/d' -e '/^VirtualKeyboardEnabled/d' "$rc" 2>/dev/null || true
    fi
done

for i in {1..10}; do
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

# Ensure power management sleep targets remain masked in headless/container environments
systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target 2>/dev/null || true

# Verify and maintain device permissions
if [ -d /dev/dri ]; then
    chmod 0666 /dev/dri/* 2>/dev/null || true
fi
if compgen -G "/dev/nvidia*" >/dev/null 2>&1; then
    chmod 0666 /dev/nvidia* 2>/dev/null || true
fi

# Ensure Rust wl-clipboard remains active in /usr/bin if an RPM update replaced it
if [ -x /usr/local/bin/wl-copy ]; then
    if ! /usr/bin/wl-copy --version 2>&1 | grep -qE "^wl-copy [0-9]"; then
        cp -f /usr/local/bin/wl-copy /usr/local/bin/wl-paste /usr/bin/ 2>/dev/null || true
    fi
fi

# Auto-sync latest scripts from GitHub repository if reachable
REPO_URL="${SELKIES_REPO_URL:-https://raw.githubusercontent.com/Den4enko/DahDesk/main}"
TMP_DIR=$(mktemp -d)
trap 'rm -rf "${TMP_DIR}"' EXIT

sync_component() {
    local src_path="$1"
    local dest_path="$2"
    local name
    name=$(basename "$dest_path")
    local tmp_file="${TMP_DIR}/${name}"
    local tmp_dest="${dest_path}.tmp.$$"

    if curl -fsSL --max-time 5 "${REPO_URL}/${src_path}" -o "${tmp_file}" 2>/dev/null; then
        if [ -s "${tmp_file}" ] && ! cmp -s "${tmp_file}" "${dest_path}" 2>/dev/null; then
            echo "[selkies] Updating ${name} from repository..."
            cp "${tmp_file}" "${tmp_dest}"
            chmod +x "${tmp_dest}"
            mv -f "${tmp_dest}" "${dest_path}"
        fi
    fi
    rm -f "${tmp_dest}" 2>/dev/null || true
}

sync_component "selkies-sync" "/usr/local/bin/selkies-sync"
sync_component "selkies-update" "/usr/local/bin/selkies-update"
sync_component "selkies-patch-input" "/usr/local/bin/selkies-patch-input"
sync_component "systemd/start-selkies.sh" "/usr/local/bin/start-selkies.sh"

# If invoked standalone (not inside a running DNF transaction), run full GitHub install.sh update
if ! (pgrep -x dnf >/dev/null 2>&1 || pgrep -x dnf5 >/dev/null 2>&1); then
    echo "[selkies] Checking for and applying full DahDesk updates from GitHub..."
    curl -fsSL --max-time 15 "${REPO_URL}/install.sh" | bash -s -- -y || true
fi

# Ensure Selkies non-US keyboard input patch is intact (fixes Cyrillic/Ukrainian typing without clipboard conflicts)
if [ -x /usr/local/bin/selkies-patch-input ]; then
    /usr/local/bin/selkies-patch-input || true
fi

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
esac

cat << 'EOF' > /usr/local/bin/selkies-update
#!/bin/bash
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
    echo "Error: selkies-update must be run as root." >&2
    exit 1
fi

echo "=================================================="
echo "  DahDesk - Updating System Packages & DahDesk"
echo "=================================================="

echo "Running system package updates..."
dnf update -y

REPO_URL="${SELKIES_REPO_URL:-https://raw.githubusercontent.com/Den4enko/DahDesk/main}"
echo ""
echo "Applying latest DahDesk configuration from GitHub repository..."
if curl -fsSL --max-time 15 "${REPO_URL}/install.sh" | bash -s -- -y; then
    echo "DahDesk update completed successfully."
else
    echo "Warning: DahDesk online sync failed (offline or network error). Local installation preserved."
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

# Build optional GPU env lines for the service unit
GPU_SERVICE_ENV=""
if [ "$GPU_ENABLED" = true ]; then
    GPU_SERVICE_ENV="Environment=DISABLE_DRI3=false
Environment=__GL_SYNC_TO_VBLANK=0"
    if [ -n "$DRI_RENDER_NODE" ]; then
        GPU_SERVICE_ENV="${GPU_SERVICE_ENV}
Environment=DRI_NODE=${DRI_RENDER_NODE}"
    fi
fi

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
Environment=KWIN_WAYLAND_NO_PERMISSION_CHECKS=1
${XKB_VARIANT_LINE}
${XKB_OPTIONS_LINE}
${GPU_SERVICE_ENV}
ExecStartPre=+/bin/sh -c "setcap -r /usr/bin/kwin_wayland 2>/dev/null || setcap -r /usr/sbin/kwin_wayland 2>/dev/null || true; [ -d /dev/dri ] && chmod 0666 /dev/dri/* 2>/dev/null || true; compgen -G '/dev/nvidia*' >/dev/null 2>&1 && chmod 0666 /dev/nvidia* 2>/dev/null || true"
ExecStart=/usr/local/bin/start-selkies.sh
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable selkies.service 2>/dev/null || true
systemctl enable NetworkManager.service 2>/dev/null || true
systemctl enable sshd.service 2>/dev/null || systemctl enable ssh.service 2>/dev/null || true

# Save / update persistent DahDesk configuration
mkdir -p /etc/dahdesk
cat << EOF > "$CONFIG_FILE"
# DahDesk Configuration - saved on $(date -u +"%Y-%m-%dT%H:%M:%SZ")
PROFILE="${PROFILE}"
DESKTOP_USER="${DESKTOP_USER}"
PORT="${PORT}"
BACKEND_OVERRIDE="${BACKEND_OVERRIDE}"
KEYBOARD_LAYOUTS="${KEYBOARD_LAYOUTS}"
KEYBOARD_VARIANTS="${KEYBOARD_VARIANTS}"
KEYBOARD_OPTIONS="${KEYBOARD_OPTIONS}"
GPU_OVERRIDE="${GPU_OVERRIDE}"
INSTALLED=true
LAST_UPDATED="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
EOF
chmod 0600 "$CONFIG_FILE"

echo "=================================================="
echo "  DahDesk Installation Complete!"
echo "=================================================="
echo "Profile:      ${PROFILE}"
echo "Backend:      ${INITIAL_BACKEND}"
echo "Hardware GPU: $([ "$GPU_ENABLED" = true ] && echo "Active (${DETECTED_GPU})" || echo "None / Software rendering")"
echo "Web URL:      https://<server-ip>:${PORT}/"
echo "Desktop User: ${DESKTOP_USER}"
if [ "$SET_PASSWORD" = true ]; then
    echo "Linux Pass:   [Configured - Hidden]"
fi
echo "HTTP Auth:    None (Direct Stream Access)"
echo "Updater:      sudo selkies-update"
echo "=================================================="

# Function to detect if script was invoked from within an active graphical desktop / terminal session
is_in_gui_session() {
    [ -n "${WAYLAND_DISPLAY:-}" ] && return 0
    [ -n "${DISPLAY:-}" ] && return 0
    local p=$$
    while [ "$p" -gt 1 ] 2>/dev/null; do
        local comm
        comm=$(cat "/proc/$p/comm" 2>/dev/null || true)
        case "$comm" in
            konsole*|ptyxis*|gnome-terminal*|xterm*|alacritty*|kitty*|foot*|kwin*|plasma*|selkies*)
                return 0
                ;;
        esac
        p=$(awk '{print $4}' "/proc/$p/stat" 2>/dev/null || echo 1)
    done
    return 1
}

if pidof systemd &>/dev/null; then
    systemctl start "user@${USER_ID}.service" 2>/dev/null || true
    if systemctl is-active --quiet selkies 2>/dev/null; then
        if is_in_gui_session; then
            echo ""
            echo "Notice: Active desktop session detected."
            echo "DahDesk will reload in 3 seconds to apply all updates..."
            ( nohup bash -c 'sleep 3 && systemctl restart selkies' >/dev/null 2>&1 & )
        else
            systemctl restart selkies
        fi
    else
        systemctl start selkies 2>/dev/null || true
    fi
fi
