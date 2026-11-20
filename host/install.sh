#!/usr/bin/env bash
# Install (or --uninstall) the host-side failback as systemd user units.
# Does not enable or start the timer; it prints the command for that.
set -euo pipefail

[ "$(id -u)" -ne 0 ] || { echo "error: run as the unprivileged user that has gh logged in, not root" >&2; exit 1; }

src=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
bin="${HOME:?}/.local/bin/tailnet-dns-failback"
units="${HOME:?}/.config/systemd/user"
timer=tailnet-dns-failback.timer
service=tailnet-dns-failback.service

case "${1:-}" in
    --uninstall)
        # also stops a timer that is active but not enabled; "not loaded" errors are fine
        systemctl --user disable --now "$timer" 2> /dev/null || true
        rm -f "${bin:?}" "${units:?}/${timer:?}" "${units:?}/${service:?}"
        systemctl --user daemon-reload
        echo "uninstalled"
        ;;
    "")
        install -D -m 0755 "$src/failback.sh" "$bin"
        install -D -m 0644 "$src/$service" "$units/$service"
        install -D -m 0644 "$src/$timer" "$units/$timer"
        systemctl --user daemon-reload
        echo "installed (timer not enabled yet)"
        echo "enable:  systemctl --user enable --now $timer"
        echo "watch:   journalctl --user -u tailnet-dns-failback -f"
        ;;
    *)
        echo "usage: $0 [--uninstall]" >&2
        exit 2
        ;;
esac
