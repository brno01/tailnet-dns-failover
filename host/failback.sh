#!/usr/bin/env bash
# Host-side failback: run on the Pi-hole host every few minutes. If the tailnet is still
# pushing the fallback resolvers to this node while the local Pi-hole answers, dispatch the
# failover workflow (dry_run=false) so the tailnet goes back to the Pi-hole without waiting
# for GitHub's scheduled run, which GitHub often skips.
#
# It only handles failback, and only when the tailnet resolvers are exactly the fallback
# (every FALLBACK_DNS address listed, no primary address). Any other list is left alone.
# When in doubt (cannot read the resolvers) it changes nothing.
#
# Needs: tailscale, dig, jq and gh (logged in with the `workflow` scope).
# Output never contains the tailnet name, device names or addresses: the repo is public.
#
# Optional env: PRIMARY_DNS (comma-separated; default: `tailscale ip -4` and `-6` of this host),
#               FALLBACK_DNS (default 9.9.9.9,149.112.112.112, as in failover.sh), PROBE_NAME (default example.com),
#               REPO (default brno01/tailnet-dns-failover), MIN_INTERVAL_SECONDS (default 600; doubles per
#               consecutive dispatch, capped at 6 h),
#               STATE_DIR (default ${XDG_STATE_HOME:-$HOME/.local/state}/tailnet-dns-failover),
#               DRY_RUN=1, NOW (epoch, for tests)
# Exit: 0 for every handled case (including inconclusive), non-zero for real errors.
set -euo pipefail

PROBE_NAME=${PROBE_NAME:-example.com}
REPO=${REPO:-brno01/tailnet-dns-failover}
MIN_INTERVAL_SECONDS=${MIN_INTERVAL_SECONDS:-600}
STATE_DIR=${STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/tailnet-dns-failover}
FALLBACK_DNS=${FALLBACK_DNS:-9.9.9.9,149.112.112.112}
MAX_INTERVAL_SECONDS=21600
DRY_RUN=${DRY_RUN:-0}

log() { printf '%s\n' "$*" >&2; }
die() { printf 'error: %s\n' "$*" >&2; exit "${2:-1}"; }

for tool in gh jq dig tailscale; do
    command -v "$tool" > /dev/null || die "$tool not found"
done

# normalize "a, b ,c" -> "a,b,c" (same as failover.sh)
normalize() { tr -d '[:space:]' <<< "$1"; }

# primary addresses (one per line); the first is probed
if [ -n "${PRIMARY_DNS:-}" ]; then
    primaries=$(normalize "$PRIMARY_DNS" | tr ',' '\n' | grep -v '^$' || true)
else
    ip4=$(tailscale ip -4 2> /dev/null | head -n 1) || ip4=""
    ip6=$(tailscale ip -6 2> /dev/null | head -n 1) || ip6=""
    primaries=$(printf '%s\n%s\n' "$ip4" "$ip6" | grep -v '^$' || true)
    [ -n "$ip4" ] || primaries=""
fi
if [ -z "$primaries" ]; then
    log "could not determine the primary address; nothing changed"
    exit 0
fi
probe_addr=$(head -n 1 <<< "$primaries")
fallbacks=$(normalize "$FALLBACK_DNS" | tr ',' '\n' | grep -v '^$' || true)

if ! status_out=$(tailscale dns status 2> /dev/null); then
    log "could not read the tailnet DNS status; nothing changed"
    exit 0
fi
resolvers=$(awk '
    /^Resolvers \(in preference order\):/ { in_sec = 1; next }
    in_sec && /^  - / { sub(/^  - /, ""); print $1; next }
    in_sec { exit }
' <<< "$status_out")
if [ -z "$resolvers" ]; then
    log "no resolvers found in the tailnet DNS status; nothing changed"
    exit 0
fi

mkdir_state() { mkdir -p "$STATE_DIR"; }
stamp="$STATE_DIR/last-dispatch"
counter="$STATE_DIR/dispatch-count"

# primary listed: the normal case, runs every few minutes. Stay quiet, reset the backoff.
if grep -Fxqf <(printf '%s\n' "$primaries") <<< "$resolvers"; then
    [ "$DRY_RUN" = 1 ] || rm -f "${counter:?}"
    exit 0
fi

# fallback active = every FALLBACK_DNS address is listed (IPv6 pairs may come along)
for addr in $fallbacks; do
    if ! grep -Fxq -- "$addr" <<< "$resolvers"; then
        log "resolvers are neither primary nor fallback; leaving them alone"
        exit 0
    fi
done
if [ -z "$fallbacks" ]; then
    log "resolvers are neither primary nor fallback; leaving them alone"
    exit 0
fi

answers=$(dig +short +time=2 +tries=2 @"$probe_addr" "$PROBE_NAME" A 2> /dev/null \
    | grep -E '^[0-9]{1,3}(\.[0-9]{1,3}){3}$' || true)
if [ -z "$answers" ]; then
    log "Pi-hole not answering; leaving DNS as is"
    exit 0
fi
log "fallback active while the Pi-hole answers"

now=${NOW:-$(date +%s)}
count=0
if [ -r "$counter" ]; then
    count=$(head -n 1 "$counter")
    [[ "$count" =~ ^[0-9]+$ ]] || count=0
fi
interval=$MIN_INTERVAL_SECONDS
for ((i = 0; i < count && interval < MAX_INTERVAL_SECONDS; i++)); do
    interval=$((interval * 2))
done
[ "$interval" -le "$MAX_INTERVAL_SECONDS" ] || interval=$MAX_INTERVAL_SECONDS
if [ -r "$stamp" ]; then
    last=$(head -n 1 "$stamp")
    # a timestamp in the future (clock went back) counts as expired
    if [[ "$last" =~ ^[0-9]+$ ]] && [ "$last" -le "$now" ] && [ $((now - last)) -lt "$interval" ]; then
        log "dispatched less than ${interval}s ago; skipping"
        exit 0
    fi
fi

for state in in_progress queued; do
    runs=$(gh run list -R "$REPO" --workflow failover.yml --status "$state" --json databaseId) \
        || die "could not list $state workflow runs"
    n=$(jq 'if type == "array" then length else error("not an array") end' <<< "$runs") \
        || die "unexpected output listing $state workflow runs"
    if [ "$n" -gt 0 ]; then
        log "a failover run is already $state; skipping"
        exit 0
    fi
done

if [ "$DRY_RUN" = 1 ]; then
    log "would dispatch failback run (dry run)"
    exit 0
fi

# record the attempt first: a failing dispatch must not be retried every few minutes
mkdir_state
printf '%s\n' "$now" > "$stamp"
printf '%s\n' $((count + 1)) > "$counter"
gh workflow run failover.yml -R "$REPO" -f dry_run=false || die "could not dispatch the workflow"
log "dispatched failback run"
