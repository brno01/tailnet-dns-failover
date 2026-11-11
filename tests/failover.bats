#!/usr/bin/env bats
# Runs failover.sh against a fake curl (tests/fake-curl) that serves fixtures and
# records every POST body, so no network or real tailnet is touched.

setup() {
    REPO=$(cd "$BATS_TEST_DIRNAME/.." && pwd)
    FAKE_BIN="$BATS_TEST_TMPDIR/bin"
    mkdir -p "$FAKE_BIN"
    cp "$BATS_TEST_DIRNAME/fake-curl" "$FAKE_BIN/curl"
    chmod +x "$FAKE_BIN/curl"
    export PATH="$FAKE_BIN:$PATH"

    export FAKE_DIR="$BATS_TEST_TMPDIR/fake"
    mkdir -p "$FAKE_DIR"

    export TS_API=http://fake.invalid/api/v2
    export TS_OAUTH_CLIENT_ID=id TS_OAUTH_CLIENT_SECRET=secret
    export TS_DEVICE=watched-host PRIMARY_DNS=100.64.0.53
    export NOW=1800000000   # 2027-01-15T08:00:00Z
    unset FALLBACK_DNS DRY_RUN GITHUB_ACTIONS OFFLINE_GRACE_SECONDS
}

device() { # device <connected> <lastSeen>
    printf '{"devices":[{"hostname":"other","connectedToControl":true},{"hostname":"watched-host","connectedToControl":%s,"lastSeen":"%s"}]}' \
        "$1" "$2" > "$FAKE_DIR/devices.json"
}
nameservers() { printf '{"dns":%s}' "$1" > "$FAKE_DIR/nameservers.json"; }
posted() { cat "$FAKE_DIR/posts" 2>/dev/null || true; }

@test "online and on primary: no change" {
    device true 2027-01-15T07:59:00Z; nameservers '["100.64.0.53"]'
    run "$REPO/failover.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == *"dns: primary (no change)"* ]]
    [ -z "$(posted)" ]
}

@test "offline past the grace period: switches to the fallback" {
    device false 2027-01-15T07:50:00Z; nameservers '["100.64.0.53"]'
    run "$REPO/failover.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == *"switched primary -> fallback"* ]]
    [ "$(posted)" = '{"dns":["9.9.9.9","149.112.112.112"]}' ]
}

@test "back online: switches back to the primary" {
    device true 2027-01-15T08:00:00Z; nameservers '["9.9.9.9","149.112.112.112"]'
    run "$REPO/failover.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == *"switched fallback -> primary"* ]]
    [ "$(posted)" = '{"dns":["100.64.0.53"]}' ]
}

@test "disconnected but seen inside the grace period: stays on primary" {
    device false 2027-01-15T07:58:30Z; nameservers '["100.64.0.53"]'
    run "$REPO/failover.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == *"device: online"* ]]
    [ -z "$(posted)" ]
}

@test "hand-edited nameservers are left alone" {
    device false 2027-01-15T07:00:00Z; nameservers '["100.64.0.53","100.64.0.54"]'
    run "$REPO/failover.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == *"changed by hand"* ]]
    [ -z "$(posted)" ]
}

@test "dry run reports the switch without posting" {
    device false 2027-01-15T07:00:00Z; nameservers '["100.64.0.53"]'
    DRY_RUN=1 run "$REPO/failover.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == *"would switch primary -> fallback"* ]]
    [ -z "$(posted)" ]
}

@test "custom fallback list with spaces is normalized" {
    device false 2027-01-15T07:00:00Z; nameservers '["100.64.0.53"]'
    FALLBACK_DNS="1.1.1.1, 1.0.0.1" run "$REPO/failover.sh"
    [ "$status" -eq 0 ]
    [ "$(posted)" = '{"dns":["1.1.1.1","1.0.0.1"]}' ]
}

@test "finds the device by MagicDNS name, ignoring case" {
    printf '{"devices":[{"hostname":"localhost","name":"Phone-12.example.ts.net","connectedToControl":false,"lastSeen":"2027-01-15T07:00:00Z"}]}' \
        > "$FAKE_DIR/devices.json"
    nameservers '["100.64.0.53"]'
    TS_DEVICE=phone-12 run "$REPO/failover.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == *"switched primary -> fallback"* ]]
}

@test "watched device missing: fails without changing anything" {
    printf '{"devices":[{"hostname":"other","connectedToControl":true}]}' > "$FAKE_DIR/devices.json"
    nameservers '["100.64.0.53"]'
    run "$REPO/failover.sh"
    [ "$status" -eq 1 ]
    [ -z "$(posted)" ]
}

@test "API failure: fails without changing anything" {
    device true 2027-01-15T08:00:00Z; nameservers '["100.64.0.53"]'
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
    device false 2027-01-15T07:00:00Z; nameservers '["100.64.0.53"]'
    run "$REPO/failover.sh"
    [ "$status" -eq 0 ]
    [[ "$output" != *watched-host* ]]
    [[ "$output" != *100.64.0.53* ]]
    [[ "$output" != *9.9.9.9* ]]
}

@test "masks the token in GitHub Actions" {
    device true 2027-01-15T08:00:00Z; nameservers '["100.64.0.53"]'
    GITHUB_ACTIONS=true run "$REPO/failover.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == *"::add-mask::fake-token"* ]]
}
