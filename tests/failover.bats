#!/usr/bin/env bats
# Runs failover.sh against fake curl/dig/tailscale (tests/fake-curl and stubs below) that
# serve fixtures and record every POST body, so no network or real tailnet is touched.

setup() {
    REPO=$(cd "$BATS_TEST_DIRNAME/.." && pwd)
    FAKE_BIN="$BATS_TEST_TMPDIR/bin"
    mkdir -p "$FAKE_BIN"
    cp "$BATS_TEST_DIRNAME/fake-curl" "$FAKE_BIN/curl"

    export FAKE_DIR="$BATS_TEST_TMPDIR/fake"
    mkdir -p "$FAKE_DIR"

    # dig answers NOERROR unless $FAKE_DIR/dig-fail exists; counts calls
    cat > "$FAKE_BIN/dig" <<'EOF'
#!/usr/bin/env bash
echo x >> "$FAKE_DIR/dig-calls"
[ -e "$FAKE_DIR/dig-fail" ] && exit 9
echo ';; ->>HEADER<<- opcode: QUERY, status: NOERROR, id: 1'
EOF
    # tailscale ping succeeds unless $FAKE_DIR/ping-fail exists
    cat > "$FAKE_BIN/tailscale" <<'EOF'
#!/usr/bin/env bash
[ "$1" = ping ] || exit 64
[ -e "$FAKE_DIR/ping-fail" ] && exit 1
echo pong
EOF
    chmod +x "$FAKE_BIN"/*
    export PATH="$FAKE_BIN:$PATH"

    export TS_API=http://fake.invalid/api/v2
    export TS_OAUTH_CLIENT_ID=id TS_OAUTH_CLIENT_SECRET=secret
    export TS_DEVICE=watched-host PRIMARY_DNS=100.64.0.53
    export NOW=1800000000   # 2027-01-15T08:00:00Z
    export PROBE_INTERVAL=0
    unset FALLBACK_DNS DRY_RUN GITHUB_ACTIONS OFFLINE_GRACE_SECONDS TAILNET_JOINED
}

device() { # device <connected> <lastSeen>
    printf '{"devices":[{"hostname":"other","connectedToControl":true},{"hostname":"watched-host","addresses":["100.64.0.53"],"connectedToControl":%s,"lastSeen":"%s"}]}' \
        "$1" "$2" > "$FAKE_DIR/devices.json"
}
online() { device true 2027-01-15T08:00:00Z; }
offline() { device false 2027-01-15T07:50:00Z; }
nameservers() { printf '{"dns":%s}' "$1" > "$FAKE_DIR/nameservers.json"; }
on_primary() { nameservers '["100.64.0.53"]'; }
on_fallback() { nameservers '["9.9.9.9","149.112.112.112"]'; }
posted() { cat "$FAKE_DIR/posts" 2>/dev/null || true; }
TO_FALLBACK='{"dns":["9.9.9.9","149.112.112.112"]}'
TO_PRIMARY='{"dns":["100.64.0.53"]}'

# --- with the runner on the tailnet (normal case) ---

@test "joined: pihole answers on primary -> no change" {
    online; on_primary
    TAILNET_JOINED=1 run "$REPO/failover.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == *"pihole: answers"* ]]
    [[ "$output" == *"dns: primary (no change)"* ]]
    [ -z "$(posted)" ]
}

@test "joined: pihole answers again -> back to primary" {
    online; on_fallback
    TAILNET_JOINED=1 run "$REPO/failover.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == *"switched fallback -> primary"* ]]
    [ "$(posted)" = "$TO_PRIMARY" ]
}

@test "joined: pihole down on a reachable host -> fallback" {
    online; on_primary; touch "$FAKE_DIR/dig-fail"
    TAILNET_JOINED=1 run "$REPO/failover.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == *"service down"* ]]
    [ "$(posted)" = "$TO_FALLBACK" ]
}

@test "joined: host offline -> fallback" {
    offline; on_primary; touch "$FAKE_DIR/dig-fail"
    TAILNET_JOINED=1 run "$REPO/failover.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == *"switched primary -> fallback"* ]]
    [ "$(posted)" = "$TO_FALLBACK" ]
}

@test "joined: no answer and host unreachable from the runner -> no change" {
    online; on_primary; touch "$FAKE_DIR/dig-fail" "$FAKE_DIR/ping-fail"
    TAILNET_JOINED=1 run "$REPO/failover.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == *"inconclusive"* ]]
    [ -z "$(posted)" ]
}

@test "joined: retries the probe before giving up" {
    online; on_primary; touch "$FAKE_DIR/dig-fail"
    TAILNET_JOINED=1 PROBE_ATTEMPTS=3 run "$REPO/failover.sh"
    [ "$(wc -l < "$FAKE_DIR/dig-calls")" -eq 3 ]
}

# --- without the tailnet (the join step failed) ---

@test "not joined: host offline past the grace period -> fallback" {
    offline; on_primary
    run "$REPO/failover.sh"
    [ "$status" -eq 0 ]
    [ "$(posted)" = "$TO_FALLBACK" ]
}

@test "not joined: host online on fallback -> no change (cannot confirm the pihole)" {
    online; on_fallback
    run "$REPO/failover.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == *"health unknown"* ]]
    [ -z "$(posted)" ]
}

@test "not joined: disconnected but seen inside the grace period -> no change" {
    device false 2027-01-15T07:58:30Z; on_primary
    run "$REPO/failover.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == *"host: online"* ]]
    [ -z "$(posted)" ]
}

# --- general ---

@test "hand-edited nameservers are left alone" {
    offline; nameservers '["100.64.0.53","100.64.0.54"]'
    TAILNET_JOINED=1 run "$REPO/failover.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == *"changed by hand"* ]]
    [ -z "$(posted)" ]
}

@test "dry run reports the switch without posting" {
    offline; on_primary
    DRY_RUN=1 run "$REPO/failover.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == *"would switch primary -> fallback"* ]]
    [ -z "$(posted)" ]
}

@test "custom fallback list with spaces is normalized" {
    offline; on_primary
    FALLBACK_DNS="1.1.1.1, 1.0.0.1" run "$REPO/failover.sh"
    [ "$status" -eq 0 ]
    [ "$(posted)" = '{"dns":["1.1.1.1","1.0.0.1"]}' ]
}

@test "finds the device by MagicDNS name, ignoring case" {
    printf '{"devices":[{"hostname":"localhost","name":"Phone-12.example.ts.net","connectedToControl":false,"lastSeen":"2027-01-15T07:00:00Z"}]}' \
        > "$FAKE_DIR/devices.json"
    on_primary
    TS_DEVICE=phone-12 run "$REPO/failover.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == *"switched primary -> fallback"* ]]
}

@test "watched device missing: fails without changing anything" {
    printf '{"devices":[{"hostname":"other","connectedToControl":true}]}' > "$FAKE_DIR/devices.json"
    on_primary
    run "$REPO/failover.sh"
    [ "$status" -eq 1 ]
    [ -z "$(posted)" ]
}

@test "API failure: fails without changing anything" {
    online; on_primary
    touch "$FAKE_DIR/fail-devices"
    run "$REPO/failover.sh"
    [ "$status" -ne 0 ]
    [ -z "$(posted)" ]
}

@test "missing required env exits 2" {
    unset PRIMARY_DNS
    run "$REPO/failover.sh"
    [ "$status" -eq 2 ]
}

@test "output never leaks the device name or resolver addresses" {
    online; on_primary; touch "$FAKE_DIR/dig-fail"
    TAILNET_JOINED=1 run "$REPO/failover.sh"
    [ "$status" -eq 0 ]
    [[ "$output" != *watched-host* ]]
    [[ "$output" != *100.64.0.53* ]]
    [[ "$output" != *9.9.9.9* ]]
}

@test "masks the token in GitHub Actions" {
    online; on_primary
    GITHUB_ACTIONS=true run "$REPO/failover.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == *"::add-mask::fake-token"* ]]
}
