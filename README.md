# tailnet-dns-failover

Keeps a Tailscale tailnet's DNS going through a self-hosted Pi-hole, and fails over to a
public resolver when the machine that hosts the Pi-hole goes offline. Runs every 5 minutes
on GitHub Actions, so it keeps working when everything at home is down.

## Why

Tailscale queries **all** global nameservers in parallel and uses the first answer. A public
resolver listed as a "backup" next to a Pi-hole is a competitor: some queries skip the
Pi-hole and ads get through. The only way to make every query go through the Pi-hole is to
list it alone. That leaves no DNS while it is down, and this workflow covers that case:

| Watched device | Tailnet nameservers |
|---|---|
| online (or seen in the last `OFFLINE_GRACE_SECONDS`) | `PRIMARY_DNS` (the Pi-hole) |
| offline | `FALLBACK_DNS` (Quad9 by default) |

It only switches between those two lists. If someone edits the nameservers by hand to
anything else, the workflow leaves them alone until they are set back to one of the two.

Detection uses the Tailscale API (`connectedToControl` / `lastSeen` of the device). It sees
the host going down, not the Pi-hole service crashing on a live host.

## Setup

1. Tailscale admin console › Settings › OAuth clients: create a client with scopes
   `dns` (write) and `devices:core` (read).
2. Repository secrets:

   | Secret | Value |
   |---|---|
   | `TS_OAUTH_CLIENT_ID` | OAuth client ID |
   | `TS_OAUTH_CLIENT_SECRET` | OAuth client secret |
   | `TS_DEVICE` | hostname of the machine running the Pi-hole |
   | `PRIMARY_DNS` | Pi-hole address(es), comma-separated |

3. Optional repository variables: `FALLBACK_DNS` (default `9.9.9.9,149.112.112.112`),
   `OFFLINE_GRACE_SECONDS` (default `180`).
4. Actions › dns-failover › Run workflow (dry run on) to check the setup.

Logs are public in a public repository; the script never prints the device name or the
resolver addresses, and the secrets are masked by GitHub.

## Limits

- GitHub runs scheduled workflows every 5 minutes at best and often a few minutes late, so
  failover and recovery take roughly 5–15 minutes.
- GitHub disables schedules in public repositories after 60 days without activity. A weekly
  step re-enables the workflow through the API; if GitHub still warns by e-mail, re-enable
  it in the Actions tab.

## Development

```bash
shellcheck failover.sh tests/fake-curl
bats tests/
```

The tests run `failover.sh` against `tests/fake-curl`, which serves fixtures and records
every write, so they never touch a real tailnet.
