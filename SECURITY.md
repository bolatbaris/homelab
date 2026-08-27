# Security Baseline

LocalCloud Stack is designed for private data. It can reduce exposure, but operators are still responsible for host security, Cloudflare policies, secrets, and backups.

## Exposure Tiers

Every service belongs to exactly one exposure tier. The tier decides how it is published, who can reach it, and which controls are mandatory.

| Tier | Name | Transport | Binding | Identity | Examples |
|---|---|---|---|---|---|
| A | Public | Cloudflare Tunnel | `edge-net` only | per-hostname Cloudflare Access policy | gitea (HTTP), n8n, glances, mattermost* |
| B | Private | Tailscale (tailnet) | tailscale0 address only | tailnet membership + ACL + service auth | planned: postgres, env store |
| C | Internal | SSH / `podman exec` | loopback or no published port | host shell access | mattermost-postgres, backup, portainer* |

\* profile-gated optional services.

### Decision Rule

Ask one question about a new service: **who must reach it?**

- Anonymous or guest users -> Tier A.
- Only the operator's enrolled devices and first-party app containers -> Tier B.
- Only host processes and interactive shell sessions -> Tier C.

When in doubt, start one tier lower (more restrictive) and promote deliberately.

### Mandatory Controls Per Tier

Tier A - Public:

- Publish only through Cloudflare Tunnel. No router HTTP port forwards.
- Every hostname has a documented Access policy. Admin-style UIs require Access + MFA.
- Anonymous bypass is allowed only for exact paths that must be callable (for example the n8n webhook path).

Tier B - Private:

- Bind to the tailscale0 address, or publish no host port at all. Never bind to `0.0.0.0`, `::`, or a bare port.
- ufw allows inbound on `tailscale0` only; the public interface stays default-deny.
- Tailscale ACLs grant only the required ports from the required devices.
- Planned services of this tier: PostgreSQL, env/secret store, and Gitea SSH (moved from its LAN bind).

Tier C - Internal:

- No `ports:` in compose. Internal bridges use `internal: true`.
- Reachable via SSH plus `podman exec`, `psql`, or an admin shell on the container network.
- The backup sidecar runs with `network_mode: none` - the reference extreme for this tier.

### CI Enforcement

`docker-compose.yml` and `compose.dev.yml` must never publish a bare `"<port>:<port>"` without an explicit interface address. CI rejects unbounded publishes (see `.github/workflows/ci.yml`). Tier B services bind to the tailscale0 address, Tier A services are reached through the tunnel without published ports, and Tier C services publish nothing.

## Remote Access Policy (Tailscale)

Tailscale is the Tier B transport. Design and implementation plan: [docs/tailscale.md](docs/tailscale.md).

- Tailscale runs on the host, never as a stack container: rootless Podman stays rootless, and remote access survives a broken stack.
- The perimeter is the operator's SSO account. It must have MFA; a hardware key is recommended. New-device login notifications stay enabled.
- No subnet routing. The tailnet reaches this host, not the whole LAN.
- Tailscale ACLs are least-privilege; the default `allow all` is replaced.
- Key expiry is disabled for the server node only; client devices keep rotating keys.
- MagicDNS stays on, but "Override local DNS" stays OFF on the server: the `dns` profile owns `/etc/resolv.conf`.
- Goal after a stabilization period: SSH accepts connections on `tailscale0` only.

## Host Firewall

Default stance:

```sh
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw allow OpenSSH
sudo ufw allow from <LAN_CIDR> to any port 53 proto tcp
sudo ufw allow from <LAN_CIDR> to any port 53 proto udp
sudo ufw allow from <LAN_CIDR> to any port 3001 proto tcp
sudo ufw allow from <LAN_CIDR> to any port 2222 proto tcp
sudo ufw allow in on tailscale0
sudo ufw enable
```

The port 53 and 3001 rules are only needed when the `dns` profile is enabled; port 2222 is Gitea SSH. The `tailscale0` rule is only needed once Tailscale is installed on the host.

## Secrets

`.env` must be mode `600`.

Generate required secrets:

```sh
openssl rand -hex 32      # N8N_ENCRYPTION_KEY
openssl rand -base64 48   # RESTIC_PASSWORD
openssl rand -hex 32      # MATTERMOST_DB_PASSWORD if enabling --profile chat
```

Prefer hex for values embedded in connection strings. Store `N8N_ENCRYPTION_KEY` and `RESTIC_PASSWORD` outside the backup disk. Losing either can make data unrecoverable.

## Backups

Backups are encrypted restic snapshots at `${BACKUP_DEST_PATH}/restic-repo`.

Backup coverage is independent of the exposure tier: Tier B and C data (databases, future env store) is backed up by the same restic sidecar through read-only `./data/<service>` mounts, with logical `pg_dump`s written before the nightly snapshot where applicable.

Production baseline:

- LUKS-encrypted physical backup disk. Unlocking is manual by default, so a
  power cut stops backups until an operator unlocks the disk. Unattended unlock
  via a root-owned keyfile and `/etc/crypttab` is documented in
  [deployment.md section 12](deployment.md) and is never configured by the
  installer: it keeps the disk protected when it leaves on its own, and stops
  protecting anything once the whole machine is taken, so the choice belongs to
  whoever knows where the hardware sits.
- ext4 filesystem inside the unlocked LUKS volume.
- `BACKUP_REQUIRE_MOUNT=true`.
- Restore tested before storing important data.
- Cold/manual backups before major upgrades, especially when the `chat` profile is enabled and PostgreSQL is active.
- Host disk encryption recommended when using `chat`, because `./data/mattermost` contains the live PostgreSQL database and logical dumps of message history before restic encrypts the backup copy.

## Updates

For production, replace `latest` image refs in `.env` with version tags or digests and update deliberately.

Suggested routine:

```sh
podman-compose -f docker-compose.yml pull
podman-compose -f docker-compose.yml up -d
podman image prune
```

Take a restic snapshot before updates.

## Responsible Disclosure

Report security vulnerabilities privately - do not open a public issue. Preferred: open a GitHub private security advisory ("Report a vulnerability" under the repository **Security** tab). Maintainers aim to acknowledge within a few days and to coordinate a fix and disclosure timeline with the reporter.

If you run a fork or hosted product based on this project, replace this section with your own monitored security contact.
