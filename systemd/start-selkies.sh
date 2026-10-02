#!/bin/bash
set -e

export USER="${USER:-user}"
USER_ID="$(id -u "${USER}")"
export HOME="${HOME:-/home/${USER}}"
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/${USER_ID}}"
export PULSE_SERVER="${PULSE_SERVER:-unix:/run/user/${USER_ID}/pulse/native}"
export PIPEWIRE_RUNTIME_DIR="${PIPEWIRE_RUNTIME_DIR:-/run/user/${USER_ID}}"
export KWIN_WAYLAND_NO_PERMISSION_CHECKS=1
export SELKIES_USE_PAINT_OVER_QUALITY="${SELKIES_USE_PAINT_OVER_QUALITY:-false}"

mkdir -pm1777 /tmp/.X11-unix 2>/dev/null || true

# Ensure non-US/Cyrillic keyboard input fix is applied
if [ -x /usr/local/bin/selkies-patch-input ]; then
    /usr/local/bin/selkies-patch-input 2>/dev/null || true
fi

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
