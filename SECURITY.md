# Security Baseline

LocalCloud Stack is designed for private data. It can reduce exposure, but operators are still responsible for host security, Cloudflare policies, secrets, and backups.

## Exposure Tiers

Every service belongs to exactly one exposure tier. The tier decides how it is published, who can reach it, and which controls are mandatory.

| Tier | Name | Transport | Binding | Identity | Examples |
|---|---|---|---|---|---|
| A | Public | Cloudflare Tunnel | `edge-net` only | per-hostname Cloudflare Access policy | gitea (HTTP), n8n, glances, mattermost* |
| B | Private | Tailscale (tailnet) | tailscale0 address only | tailnet membership + ACL + service auth | appdb (PostgreSQL)*, appdb-adminer* |
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
- Implemented services in this tier: the `db` profile's PostgreSQL (`appdb`) and Adminer (`appdb-adminer`). They bind `${TAILSCALE_IP}` through compose's required-variable form, so an empty address fails the render instead of falling back to every interface. `install.sh` refuses the profile unless `TAILSCALE_ENABLED=true` and probes that podman-compose actually implements that form, and CI asserts both behaviors.
- These services are deliberately absent from `edge-net`. `cloudflared` reaches only that network, so a public hostname created by mistake still cannot route to the database. The exposure boundary is the network topology, not a dashboard setting.
- Adminer has no accounts of its own; the PostgreSQL credentials are the only authentication. Tailnet membership is therefore the outer perimeter, not a convenience.
- Still planned for this tier: an env/secret store, and Gitea SSH (moved from its LAN bind).

Tier C - Internal:

- No `ports:` in compose. Internal bridges use `internal: true`.
- Reachable via SSH plus `podman exec`, `psql`, or an admin shell on the container network.
- The backup sidecar runs with `network_mode: none` - the reference extreme for this tier.

### CI Enforcement

`docker-compose.yml` and `compose.dev.yml` must never publish a port whose host part is anything other than `127.0.0.1`, `${LAN_IP…}`, or `${TAILSCALE_IP…}`. `tests/compose-guards.sh` enforces that, asserts that no Tier B service joins `edge-net`, and asserts the fail-closed property directly: rendering the `db` profile with an empty `TAILSCALE_IP` must fail, and rendering it with one set must bind that address and no wildcard. CI runs the script on every push, and you can run it yourself with `./tests/compose-guards.sh`.

Tier B services bind to the tailscale0 address, Tier A services are reached through the tunnel without published ports, and Tier C services publish nothing.

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

The `db` profile needs no rule of its own beyond `sudo ufw allow in on tailscale0`: PostgreSQL and Adminer bind the tailscale0 address, so the default-deny public interface already covers them.

## Secrets

`.env` must be mode `600`.

Generate required secrets:

```sh
openssl rand -hex 32      # N8N_ENCRYPTION_KEY
openssl rand -base64 48   # RESTIC_PASSWORD
openssl rand -hex 32      # MATTERMOST_DB_PASSWORD if enabling --profile chat
openssl rand -hex 32      # APPDB_SUPERUSER_PASSWORD and APPDB_APP_PASSWORD if enabling --profile db
```

Prefer hex for values embedded in connection strings. Store `N8N_ENCRYPTION_KEY` and `RESTIC_PASSWORD` outside the backup disk. Losing either can make data unrecoverable.

## Backups

Backups are encrypted restic snapshots at `${BACKUP_DEST_PATH}/restic-repo`.

Backup coverage is independent of the exposure tier: Tier B and C data (databases, future env store) is backed up by the same restic sidecar through read-only `./data/<service>` mounts, with logical `pg_dump`s written before the nightly snapshot where applicable.

Production baseline:

- LUKS-encrypted physical backup disk. This is a second layer, not the only one:
  restic already encrypts every snapshot under `RESTIC_PASSWORD`, so a plain
  disk does not mean plain backups. What LUKS adds is protection for the disk
  itself once it leaves your control.
- Mounting is manual by default, so a power cut stops backups until an operator
  notices. `./backup-automount.sh` configures boot-time mounting - `fstab` for a
  plain disk, plus a root-owned keyfile and `/etc/crypttab` for a LUKS one
  ([deployment.md section 12](deployment.md)). `install.sh` never runs it. For a
  LUKS disk the keyfile lives on the host root disk, so the disk stays protected
  when it leaves on its own and stops protecting anything once the whole machine
  is taken; the script keeps the existing passphrase as a second key slot and
  backs up the LUKS header first.
- ext4 filesystem inside the unlocked LUKS volume.
- `BACKUP_REQUIRE_MOUNT=true`.
- Restore tested before storing important data.
- Cold/manual backups before major upgrades, especially when the `chat` profile is enabled and PostgreSQL is active.
- Host disk encryption recommended when using `chat`, because `./data/mattermost` contains the live PostgreSQL database and logical dumps of message history before restic encrypts the backup copy.
- The same applies to `db`: `./data/appdb` holds the live application database plus logical dumps, including `globals-latest.sql`, which carries every role's password hash.

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
