# tailnet-dns-failover

Keeps a Tailscale tailnet's DNS going through a self-hosted Pi-hole, and fails over to a
public resolver while the Pi-hole does not answer: its host is down **or** just the
Pi-hole service is. Runs every 5 minutes on GitHub Actions, so it keeps working when
everything at home is down.

## Why

Tailscale queries **all** global nameservers in parallel and uses the first answer. A public
resolver listed as a "backup" next to a Pi-hole is a competitor: some queries skip the
Pi-hole and ads get through. The only way to make every query go through the Pi-hole is to
list it alone. That leaves no DNS while it is down, and this workflow covers that case.

## How it decides

Each run joins the tailnet as an ephemeral node tagged `tag:dns-failover` and sends a DNS
query to the Pi-hole (3 attempts).

| Probe result | Tailnet nameservers |
|---|---|
| Pi-hole answers | `PRIMARY_DNS` (the Pi-hole) |
| no answer, host offline in the control plane | `FALLBACK_DNS` (Quad9 by default) |
| no answer, host online and answering `tailscale ping` (service down) | `FALLBACK_DNS` |
| no answer, host online but unreachable from the runner | no change (inconclusive) |
| runner could not join the tailnet | only "host offline" switches to the fallback; never back |

It only switches between those two lists. If someone edits the nameservers by hand to
anything else, the workflow leaves them alone until they are set back to one of the two.

## Setup

1. Tailnet policy: a tag for the runner that can reach only the Pi-hole's port 53.

   ```jsonc
   "tagOwners": { "tag:dns-failover": ["autogroup:admin"] },
   "grants": [
     { "src": ["tag:dns-failover"], "dst": ["<pihole-ip>"], "ip": ["udp:53", "tcp:53"] }
   ]
   ```

2. Tailscale admin console › Settings › OAuth clients: create a client with scopes
   `dns` (write), `devices:core` (read) and `auth_keys` (write), restricted to
   `tag:dns-failover`.
3. Repository secrets:

   | Secret | Value |
   |---|---|
   | `TS_OAUTH_CLIENT_ID` | OAuth client ID |
   | `TS_OAUTH_CLIENT_SECRET` | OAuth client secret |
   | `TS_DEVICE` | hostname or MagicDNS name of the machine running the Pi-hole |
   | `PRIMARY_DNS` | Pi-hole address(es), comma-separated; the first one is probed |

4. Optional repository variables: `FALLBACK_DNS` (default `9.9.9.9,149.112.112.112`),
   `OFFLINE_GRACE_SECONDS` (default `180`).
5. Actions › dns-failover › Run workflow (dry run on) to check the setup.

Logs are public in a public repository; the script never prints the device name or the
resolver addresses, and the secrets are masked by GitHub.

## Limits

- GitHub runs scheduled workflows every 5 minutes at best and often a few minutes late, so
  failover and recovery take roughly 5–15 minutes. During a GitHub Actions outage nothing
  switches.
- GitHub disables schedules in public repositories after 60 days without activity. A weekly
  step re-enables the workflow through the API; if GitHub still warns by e-mail, re-enable
  it in the Actions tab.

## Development

```bash
shellcheck failover.sh tests/fake-curl
bats tests/
```

The tests run `failover.sh` against fake `curl`, `dig` and `tailscale`, which serve fixtures
and record every write, so they never touch a real tailnet.
