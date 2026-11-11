#!/usr/bin/env bash
# Tailnet DNS failover: keep the tailnet's global nameservers pointed at the primary
# resolver (a Pi-hole) while it answers, and switch them to a public fallback while it
# does not.
#
# Tailscale races every global nameserver in parallel and takes the first answer, so a
# "backup" resolver in the list is really a competitor that bypasses the Pi-hole. This
# script keeps only one set in the list at a time instead.
#
# Health, when the runner joined the tailnet (TAILNET_JOINED=1):
#   Pi-hole answers a DNS query                              -> primary
#   no answer, host offline in the control plane             -> fallback
#   no answer, host online and answers `tailscale ping`      -> fallback (Pi-hole is down)
#   no answer, host online but unreachable from the runner   -> no change (inconclusive)
# Without the tailnet (TAILNET_JOINED=0) only "host offline" can be proven, so it can
# switch to the fallback but never back to the primary.
#
# It only ever switches between PRIMARY_DNS and FALLBACK_DNS. If the current list is
# anything else (a manual change), it leaves it alone.
#
# Output never contains the device name or resolver addresses, because the logs of a
# public repository are public.
#
# Required env: TS_OAUTH_CLIENT_ID, TS_OAUTH_CLIENT_SECRET (scopes: dns, devices:core:read),
#               TS_DEVICE (hostname or MagicDNS name of the Pi-hole host, any case),
#               PRIMARY_DNS (comma-separated; the first one is probed)
# Optional env: FALLBACK_DNS (default Quad9), OFFLINE_GRACE_SECONDS (default 180),
#               TAILNET_JOINED (default 0), PROBE_NAME (default example.com),
#               PROBE_ATTEMPTS (default 3), PROBE_INTERVAL (seconds, default 4),
#               DRY_RUN=1, TS_API, TS_TAILNET (default "-"),
#               TAILSCALE (command, may include sudo), DIG, NOW (epoch, for tests)
set -euo pipefail

TS_API=${TS_API:-https://api.tailscale.com/api/v2}
TS_TAILNET=${TS_TAILNET:--}
FALLBACK_DNS=${FALLBACK_DNS:-9.9.9.9,149.112.112.112}
OFFLINE_GRACE_SECONDS=${OFFLINE_GRACE_SECONDS:-180}
TAILNET_JOINED=${TAILNET_JOINED:-0}
PROBE_NAME=${PROBE_NAME:-example.com}
PROBE_ATTEMPTS=${PROBE_ATTEMPTS:-3}
PROBE_INTERVAL=${PROBE_INTERVAL:-4}
DRY_RUN=${DRY_RUN:-0}
DIG=${DIG:-dig}
read -r -a TS_CMD <<< "${TAILSCALE:-tailscale}"

log() { printf '%s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit "${2:-1}"; }

for var in TS_OAUTH_CLIENT_ID TS_OAUTH_CLIENT_SECRET TS_DEVICE PRIMARY_DNS; do
    [ -n "${!var:-}" ] || die "missing required env $var" 2
done

# normalize "a, b ,c" -> "a,b,c"
normalize() { tr -d '[:space:]' <<< "$1"; }
PRIMARY=$(normalize "$PRIMARY_DNS")
FALLBACK=$(normalize "$FALLBACK_DNS")
[ "$PRIMARY" != "$FALLBACK" ] || die "PRIMARY_DNS and FALLBACK_DNS must differ" 2
PROBE_ADDR=${PRIMARY%%,*}

token=$(curl -fsS --retry 2 \
    --data-urlencode "client_id=$TS_OAUTH_CLIENT_ID" \
    --data-urlencode "client_secret=$TS_OAUTH_CLIENT_SECRET" \
    "$TS_API/oauth/token" | jq -r '.access_token // empty') || die "could not get an OAuth token"
[ -n "$token" ] || die "OAuth token response had no access_token"
[ "${GITHUB_ACTIONS:-}" = true ] && echo "::add-mask::$token"

api_get() { curl -fsS --retry 2 -H "Authorization: Bearer $token" "$TS_API$1"; }

devices=$(api_get "/tailnet/$TS_TAILNET/devices?fields=all") || die "could not list devices"
# match the OS hostname or the MagicDNS name (first label), ignoring case
device=$(jq -c --arg h "$TS_DEVICE" '
    ($h | ascii_downcase) as $want
    | [.devices[] | select(
        ((.hostname // "") | ascii_downcase) == $want
        or ((.name // "") | split(".") | (.[0] // "") | ascii_downcase) == $want)]
    | first // empty' <<< "$devices")
[ -n "$device" ] || die "watched device not found in the tailnet; nothing changed"

connected=$(jq -r '.connectedToControl // false' <<< "$device")
last_seen=$(jq -r '.lastSeen // empty' <<< "$device")
host_ip=$(jq -r '.addresses[0] // empty' <<< "$device")
now=${NOW:-$(date -u +%s)}

online=false
if [ "$connected" = true ]; then
    online=true
elif [ -n "$last_seen" ]; then
    seen=$(date -u -d "$last_seen" +%s) || die "could not parse lastSeen"
    [ $((now - seen)) -lt "$OFFLINE_GRACE_SECONDS" ] && online=true
fi

current=$(api_get "/tailnet/$TS_TAILNET/dns/nameservers" | jq -r '.dns // [] | join(",")') \
    || die "could not read the tailnet nameservers"

label() {
    case "$1" in
        "$PRIMARY") echo primary ;;
        "$FALLBACK") echo fallback ;;
        *) echo other ;;
    esac
}
current_label=$(label "$current")

probe_dns() {
    local i
    for ((i = 1; i <= PROBE_ATTEMPTS; i++)); do
        if "$DIG" +tries=1 +time=3 "@$PROBE_ADDR" "$PROBE_NAME" A 2>/dev/null | grep -q 'status: NOERROR'; then
            return 0
        fi
        [ "$i" -lt "$PROBE_ATTEMPTS" ] && sleep "$PROBE_INTERVAL"
    done
    return 1
}

host_reachable() {
    [ -n "$host_ip" ] || return 1
    "${TS_CMD[@]}" ping -c 1 --timeout 5s --until-direct=false "$host_ip" > /dev/null 2>&1
}

if [ "$online" = true ]; then
    log "host: online"
else
    log "host: offline (not connected for at least ${OFFLINE_GRACE_SECONDS}s)"
fi

# healthy: true -> primary, false -> fallback, unknown -> leave as is
if [ "$TAILNET_JOINED" = 1 ]; then
    if probe_dns; then
        healthy=true; log "pihole: answers"
    elif [ "$online" = false ]; then
        healthy=false; log "pihole: no answer (host offline)"
    elif host_reachable; then
        healthy=false; log "pihole: no answer while its host is reachable (service down)"
    else
        healthy=unknown; log "pihole: no answer and host unreachable from the runner (inconclusive)"
    fi
elif [ "$online" = false ]; then
    healthy=false; log "pihole: not probed (runner not on the tailnet); host offline"
else
    healthy=unknown; log "pihole: not probed (runner not on the tailnet); host online, cannot confirm the pihole"
fi

if [ "$current_label" = other ]; then
    log "dns: the nameservers were changed by hand (neither primary nor fallback); leaving them alone"
    exit 0
fi

case "$healthy" in
    true) desired=$PRIMARY ;;
    false) desired=$FALLBACK ;;
    *) log "dns: $current_label (no change: health unknown)"; exit 0 ;;
esac
desired_label=$(label "$desired")

if [ "$current" = "$desired" ]; then
    log "dns: $current_label (no change)"
    exit 0
fi

if [ "$DRY_RUN" = 1 ]; then
    log "dns: would switch $current_label -> $desired_label (dry run)"
    exit 0
fi

body=$(jq -cn --arg list "$desired" '{dns: ($list | split(","))}')
curl -fsS --retry 2 -X POST \
    -H "Authorization: Bearer $token" \
    -H "Content-Type: application/json" \
    --data "$body" \
    "$TS_API/tailnet/$TS_TAILNET/dns/nameservers" > /dev/null || die "could not update the nameservers"
log "dns: switched $current_label -> $desired_label"
