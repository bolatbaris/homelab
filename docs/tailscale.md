# Tailscale Integration Plan

Status: **Phase V2 implemented** - installer integration and documentation are
in place; Phase V1 (host install) is a manual step, see
[deployment.md section 11](../deployment.md#11-private-tier-tailscale).
Phase V3 (first Tier B service) is a separate design. Policy context:
[SECURITY.md](../SECURITY.md). Once a phase lands, its operational steps live in
[deployment.md](../deployment.md) and this file stays as the design reference.

## Why Tailscale

- Tier B transport: private services (PostgreSQL, env store) reachable only by
  enrolled devices, with no route from LAN or internet.
- Zero open ports: NAT traversal + DERP relay. The router stays untouched and
  `ufw default deny incoming` survives unchanged.
- MFA through the operator's SSO provider, per-device ACLs, MagicDNS names.
- WireGuard encryption end to end; the coordination server sees connection
  metadata, not traffic.

## Why Not The Alternatives

- **Container sidecar**: needs `/dev/net/tun` + `NET_ADMIN` (a root container) -
  violates the rootless rule, and the VPN dies exactly when the stack does.
- **Raw WireGuard**: requires a forwarded UDP port (a documented exception to
  the zero-port rule) and manual peer key management.
- **OpenVPN**: same forwarded port, heavier PKI lifecycle, no MFA in the
  community edition, breaks behind CGNAT.

## Architecture

```
enrolled devices --WireGuard--> tailscale0 (host, 100.x.y.z) --> ufw --> tier B services
public visitors  --TLS--------> Cloudflare Tunnel (outbound) --------> tier A services
```

`tailscaled` is a **host service** (systemd system unit, apt-managed), treated
like ufw or netplan - it is infrastructure, not part of the compose stack. The
stack changes only in that Tier B services later bind to the tailscale0 address
instead of a LAN IP.

## Foundations Compatibility

| Foundation | Impact |
|---|---|
| Single-command install | `install.sh` only **validates** (tailscale binary present, tailscale0 address matches `.env`); it never installs the host package |
| restic backups | none - the backup container has `network_mode: none`; Tailscale adds no state under `./data` |
| Cloudflare Tunnel | coexists; both are outbound-only, no port overlap |
| `dns` profile (AdGuard) | "Override local DNS" stays OFF on the server so MagicDNS never fights `install.sh` over `/etc/resolv.conf` |
| systemd user service | unaffected - `tailscaled` is a system unit, outside the linger/user chain |

## Phases

### Phase V1 - Host Install And Hardening (manual, ~30 min)

1. Install from the official apt repository:

   ```sh
   curl -fsSL https://tailscale.com/install.sh | sh
   ```

2. `sudo tailscale up` and authenticate with SSO (2FA mandatory on that account).
3. Firewall: `sudo ufw allow in on tailscale0`.
4. Admin console:
   - replace the default ACL with a least-privilege one (only named devices ->
     named ports on the server);
   - disable key expiry for the server node only;
   - MagicDNS on; "Override local DNS" OFF on the server.
5. No subnet routing (`--advertise-routes` stays unset).

Verify:

```sh
tailscale status
tailscale ip -4                       # the tailscale0 address
sudo ufw status | grep tailscale0
ssh <tailscale-ip>                    # from a device on a foreign network
```

### Phase V2 - Installer Integration

`.env.example` additions:

```
# Private (Tier B) transport. Set true only after Phase V1 is done on the host.
TAILSCALE_ENABLED=false
# tailscale0 IPv4 of this server (tailscale ip -4). Required when TAILSCALE_ENABLED=true.
TAILSCALE_IP=
```

`install.sh` additions (fail-closed, mirroring the existing profile checks):

- when `TAILSCALE_ENABLED=true`: require the `tailscale` binary, read the
  tailscale0 IPv4, fail if absent, and fail on a `TAILSCALE_IP` mismatch;
- export `TAILSCALE_IP` to compose so Tier B services bind to it;
- print the ufw + ACL reminder on completion.

CI addition: reject unbounded `"<port>:<port>"` publishes in compose files
(implemented together with the SECURITY.md exposure-tier change).

### Phase V3 - First Tier B Service (PostgreSQL)

Separate design, follows the Tier B controls from SECURITY.md: bind to
`${TAILSCALE_IP}`, live on `db-net` (`internal: true`), and reuse the existing
backup pattern (pg_dump sidecar + read-only restic mount). Not part of this plan
beyond the interface contract.

### Phase V4 - Documentation And SSH Tightening

Documentation updates (same change-set as the Phase V2 code, or a follow-up PR):

- `README.md`:
  - Requirements: add optional Tailscale for the Private tier;
  - "What It Includes": mention the exposure tiers (Public / Private / Internal);
  - Security Model: link the Tier B policy in SECURITY.md.
- `deployment.md`: new "Private Tier (Tailscale)" runbook section - host install,
  `.env` flags, ufw rule, ACL guidance, and a verification checklist
  (`tailscale status`, `ss -tlnp | grep <tier-b-port>` showing only the
  tailscale0 address).
- `architecture.md`: Network Model gains the tailscale0 plane; Exposure Model
  references the three tiers instead of the flat list.
- `CHANGELOG.md`: entry for the Tailscale integration.
- `SECURITY.md`: already updated (exposure tiers + Remote Access Policy).

SSH tightening (deliberate, after a stabilization period):

- allow SSH only on `tailscale0` (remove the LAN/public SSH rule);
- optionally move the Gitea SSH bind from `LAN_IP` to `${TAILSCALE_IP}` -
  decide when the first Tier B service lands.

## Rollback

```sh
sudo tailscale down && sudo apt remove tailscale
sudo ufw delete allow in on tailscale0
```

Set `TAILSCALE_ENABLED=false` in `.env` and rerun `./install.sh`. Tier A and C
behavior is unaffected throughout.
