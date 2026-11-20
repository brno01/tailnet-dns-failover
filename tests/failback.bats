#!/usr/bin/env bats
# Runs host/failback.sh against fake tailscale/dig/gh on PATH. Nothing touches the real
# tailnet or GitHub; every `gh workflow run` call is recorded in $FAKE_DIR/dispatches.

setup() {
    REPO_DIR=$(cd "$BATS_TEST_DIRNAME/.." && pwd)
    FAKE_BIN="$BATS_TEST_TMPDIR/bin"
    mkdir -p "$FAKE_BIN"
    export FAKE_DIR="$BATS_TEST_TMPDIR/fake"
    mkdir -p "$FAKE_DIR"

    # tailscale: `ip -4` prints the primary; `dns status` prints $FAKE_DIR/dns-status
    # unless $FAKE_DIR/dns-fail exists
    cat > "$FAKE_BIN/tailscale" <<'EOF2'
#!/usr/bin/env bash
case "$1 ${2:-}" in
    "ip -4") printf '100.64.0.53\n100.64.0.99\n' ;;
    "ip -6") printf 'fd7a:115c::53\n' ;;
    "dns status") [ -e "$FAKE_DIR/dns-fail" ] && exit 1; cat "$FAKE_DIR/dns-status" ;;
    *) exit 64 ;;
esac
EOF2
    # dig answers an A record unless $FAKE_DIR/dig-fail exists (then prints nothing)
    cat > "$FAKE_BIN/dig" <<'EOF2'
#!/usr/bin/env bash
echo x >> "$FAKE_DIR/dig-calls"
[ -e "$FAKE_DIR/dig-fail" ] && exit 0
echo 93.184.216.34
EOF2
    # gh: `run list --status S` prints $FAKE_DIR/runs-S (default []); `workflow run`
    # records its args and fails if $FAKE_DIR/gh-fail exists
    cat > "$FAKE_BIN/gh" <<'EOF2'
#!/usr/bin/env bash
if [ "$1 $2" = "run list" ]; then
    while [ $# -gt 0 ]; do
        [ "$1" = --status ] && state=$2
        shift
    done
    if [ -e "$FAKE_DIR/runs-$state" ]; then cat "$FAKE_DIR/runs-$state"; else echo '[]'; fi
elif [ "$1 $2" = "workflow run" ]; then
    echo "$*" >> "$FAKE_DIR/dispatches"
    [ -e "$FAKE_DIR/gh-fail" ] && exit 1
    exit 0
else
    exit 64
fi
EOF2
    chmod +x "$FAKE_BIN"/*
    ln -s "$(command -v jq)" "$FAKE_BIN/jq"
    export PATH="$FAKE_BIN:$PATH"

    export STATE_DIR="$BATS_TEST_TMPDIR/state"
    export NOW=1800000000
    unset PRIMARY_DNS FALLBACK_DNS DRY_RUN MIN_INTERVAL_SECONDS PROBE_NAME REPO
}

dns_status() { # dns_status <resolver>...
    {
        echo '=== MagicDNS configuration ==='
        echo
        echo 'Resolvers (in preference order):'
        for r in "$@"; do echo "  - $r"; done
        echo
        echo 'Split DNS Routes:'
        echo '  - ts.net.                        -> 199.247.155.53'
    } > "$FAKE_DIR/dns-status"
}
on_primary() { dns_status 100.64.0.53; }
on_fallback() { dns_status 9.9.9.9 149.112.112.112 2620:fe::fe 2620:fe::9; }
dispatches() { cat "$FAKE_DIR/dispatches" 2>/dev/null || true; }

@test "resolvers already include primary -> quiet, no dispatch, no probe" {
    on_primary
    run "$REPO_DIR/host/failback.sh"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [ -z "$(dispatches)" ]
    [ ! -e "$FAKE_DIR/dig-calls" ]
}

@test "fallback active and pihole answers -> dispatch with dry_run=false" {
    on_fallback
    run "$REPO_DIR/host/failback.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == *"dispatched failback run"* ]]
    [ "$(dispatches)" = "workflow run failover.yml -R brno01/tailnet-dns-failover -f dry_run=false" ]
    [ "$(cat "$STATE_DIR/last-dispatch")" = "$NOW" ]
}

@test "pihole not answering -> no dispatch" {
    on_fallback; touch "$FAKE_DIR/dig-fail"
    run "$REPO_DIR/host/failback.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Pi-hole not answering; leaving DNS as is"* ]]
    [ -z "$(dispatches)" ]
}

@test "tailscale dns status fails -> exit 0, no dispatch" {
    on_fallback; touch "$FAKE_DIR/dns-fail"
    run "$REPO_DIR/host/failback.sh"
    [ "$status" -eq 0 ]
    [ -z "$(dispatches)" ]
}

@test "no resolvers in dns status -> exit 0, no dispatch" {
    printf '=== MagicDNS configuration ===\n\nResolvers (in preference order):\n  (no resolvers configured)\n' > "$FAKE_DIR/dns-status"
    run "$REPO_DIR/host/failback.sh"
    [ "$status" -eq 0 ]
    [ -z "$(dispatches)" ]
}

@test "split DNS routes are not mistaken for resolvers" {
    printf 'Resolvers (in preference order):\n\nSplit DNS Routes:\n  - 100.64.0.53\n' > "$FAKE_DIR/dns-status"
    run "$REPO_DIR/host/failback.sh"
    [ "$status" -eq 0 ]
    [ -z "$(dispatches)" ]
}

@test "rate limit: recent dispatch -> no dispatch" {
    on_fallback; mkdir -p "$STATE_DIR"; echo $((NOW - 100)) > "$STATE_DIR/last-dispatch"
    run "$REPO_DIR/host/failback.sh"
    [ "$status" -eq 0 ]
    [ -z "$(dispatches)" ]
}

@test "rate limit: old dispatch -> dispatches again" {
    on_fallback; mkdir -p "$STATE_DIR"; echo $((NOW - 601)) > "$STATE_DIR/last-dispatch"
    run "$REPO_DIR/host/failback.sh"
    [ "$status" -eq 0 ]
    [ -n "$(dispatches)" ]
}

@test "rate limit honours MIN_INTERVAL_SECONDS" {
    on_fallback; mkdir -p "$STATE_DIR"; echo $((NOW - 100)) > "$STATE_DIR/last-dispatch"
    MIN_INTERVAL_SECONDS=50 run "$REPO_DIR/host/failback.sh"
    [ -n "$(dispatches)" ]
}

@test "run already in progress -> no dispatch" {
    on_fallback; echo '[{"databaseId":1}]' > "$FAKE_DIR/runs-in_progress"
    run "$REPO_DIR/host/failback.sh"
    [ "$status" -eq 0 ]
    [ -z "$(dispatches)" ]
}

@test "run already queued -> no dispatch" {
    on_fallback; echo '[{"databaseId":2}]' > "$FAKE_DIR/runs-queued"
    run "$REPO_DIR/host/failback.sh"
    [ "$status" -eq 0 ]
    [ -z "$(dispatches)" ]
}

@test "DRY_RUN=1 -> no dispatch and no timestamp" {
    on_fallback
    DRY_RUN=1 run "$REPO_DIR/host/failback.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == *"would dispatch"* ]]
    [ -z "$(dispatches)" ]
    [ ! -e "$STATE_DIR/last-dispatch" ]
}

@test "PRIMARY_DNS from env wins over tailscale ip" {
    dns_status 9.9.9.9 10.0.0.1
    PRIMARY_DNS=10.0.0.1 run "$REPO_DIR/host/failback.sh"
    [ "$status" -eq 0 ]
    [ -z "$(dispatches)" ]
}

@test "PRIMARY_DNS from tailscale ip -4 (first line only)" {
    dns_status 9.9.9.9 149.112.112.112 100.64.0.99   # second address of the fake must not count
    run "$REPO_DIR/host/failback.sh"
    [ "$status" -eq 0 ]
    [ -n "$(dispatches)" ]
}

@test "primary found via tailscale ip -6 -> quiet" {
    dns_status fd7a:115c::53
    run "$REPO_DIR/host/failback.sh"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [ -z "$(dispatches)" ]
}

@test "PRIMARY_DNS may be comma-separated; any listed one counts, first is probed" {
    dns_status 9.9.9.9 10.0.0.1
    PRIMARY_DNS="10.0.0.9, 10.0.0.1" run "$REPO_DIR/host/failback.sh"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [ ! -e "$FAKE_DIR/dig-calls" ]
}

@test "other lists are left alone: manual edit, partial fallback, unrelated" {
    for l in "1.1.1.1 1.0.0.1" "9.9.9.9" "9.9.9.9 8.8.8.8"; do
        # shellcheck disable=SC2086
        dns_status $l
        run "$REPO_DIR/host/failback.sh"
        [ "$status" -eq 0 ]
        [[ "$output" == *"neither primary nor fallback; leaving them alone"* ]]
        [ -z "$(dispatches)" ]
    done
}

@test "fallback order does not matter; annotations after the address are tolerated" {
    printf 'Resolvers (in preference order):\n  - 149.112.112.112 (some note)\n  - 9.9.9.9\n\n' > "$FAKE_DIR/dns-status"
    run "$REPO_DIR/host/failback.sh"
    [ "$status" -eq 0 ]
    [ -n "$(dispatches)" ]
}

@test "custom FALLBACK_DNS with spaces is normalized" {
    dns_status 1.1.1.1 1.0.0.1
    FALLBACK_DNS="1.0.0.1, 1.1.1.1" run "$REPO_DIR/host/failback.sh"
    [ "$status" -eq 0 ]
    [ -n "$(dispatches)" ]
}

@test "missing tools fail closed (exit 1, no dispatch)" {
    on_fallback
    for t in gh jq dig tailscale; do
        mkdir "$BATS_TEST_TMPDIR/bin-$t"
        cp -a "$FAKE_BIN/." "$BATS_TEST_TMPDIR/bin-$t/"
        rm "$BATS_TEST_TMPDIR/bin-$t/$t"
        PATH="$BATS_TEST_TMPDIR/bin-$t" run "$(command -v bash)" "$REPO_DIR/host/failback.sh"
        [ "$status" -eq 1 ]
        [[ "$output" == *"$t not found"* ]]
        [ -z "$(dispatches)" ]
    done
}

@test "gh run list failing or returning non-JSON -> error, no dispatch" {
    on_fallback; echo 'garbage' > "$FAKE_DIR/runs-in_progress"
    run "$REPO_DIR/host/failback.sh"
    [ "$status" -ne 0 ]
    [ -z "$(dispatches)" ]
    echo '{"a":1}' > "$FAKE_DIR/runs-in_progress"
    run "$REPO_DIR/host/failback.sh"
    [ "$status" -ne 0 ]
    [ -z "$(dispatches)" ]
}

@test "backoff: interval doubles with consecutive dispatches" {
    on_fallback; mkdir -p "$STATE_DIR"; echo 2 > "$STATE_DIR/dispatch-count"
    echo $((NOW - 2300)) > "$STATE_DIR/last-dispatch"   # interval is 2400
    run "$REPO_DIR/host/failback.sh"
    [ -z "$(dispatches)" ]
    echo $((NOW - 2500)) > "$STATE_DIR/last-dispatch"
    run "$REPO_DIR/host/failback.sh"
    [ -n "$(dispatches)" ]
    [ "$(cat "$STATE_DIR/dispatch-count")" = 3 ]
}

@test "backoff is capped at 6 hours" {
    on_fallback; mkdir -p "$STATE_DIR"; echo 40 > "$STATE_DIR/dispatch-count"
    echo $((NOW - 21000)) > "$STATE_DIR/last-dispatch"
    run "$REPO_DIR/host/failback.sh"
    [ -z "$(dispatches)" ]
    echo $((NOW - 21601)) > "$STATE_DIR/last-dispatch"
    run "$REPO_DIR/host/failback.sh"
    [ -n "$(dispatches)" ]
}

@test "backoff counter resets when the primary is back" {
    on_primary; mkdir -p "$STATE_DIR"; echo 3 > "$STATE_DIR/dispatch-count"
    run "$REPO_DIR/host/failback.sh"
    [ ! -e "$STATE_DIR/dispatch-count" ]
}

@test "timestamp in the future counts as expired" {
    on_fallback; mkdir -p "$STATE_DIR"; echo $((NOW + 5000)) > "$STATE_DIR/last-dispatch"
    run "$REPO_DIR/host/failback.sh"
    [ -n "$(dispatches)" ]
}

@test "DRY_RUN=1 does not touch the counter" {
    on_fallback
    DRY_RUN=1 run "$REPO_DIR/host/failback.sh"
    [ ! -e "$STATE_DIR/dispatch-count" ]
}

@test "output never contains the addresses" {
    on_fallback
    run "$REPO_DIR/host/failback.sh"
    [[ "$output" != *100.64.0.53* ]]
    [[ "$output" != *9.9.9.9* ]]
    [[ "$output" != *149.112.112.112* ]]
    touch "$FAKE_DIR/dig-fail"
    run "$REPO_DIR/host/failback.sh"
    [[ "$output" != *100.64.0.53* ]]
    [[ "$output" != *9.9.9.9* ]]
}

@test "dispatch failure -> non-zero exit, attempt still recorded (no retry storm)" {
    on_fallback; touch "$FAKE_DIR/gh-fail"
    run "$REPO_DIR/host/failback.sh"
    [ "$status" -ne 0 ]
    [ "$(cat "$STATE_DIR/last-dispatch")" = "$NOW" ]
    rm "$FAKE_DIR/dispatches"
    run "$REPO_DIR/host/failback.sh"
    [ "$status" -eq 0 ]
    [ -z "$(dispatches)" ]
}
