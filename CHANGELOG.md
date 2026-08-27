# Changelog

Notable changes to LocalCloud Stack. Format loosely follows
[Keep a Changelog](https://keepachangelog.com/).

## [Unreleased]

### Added
- Open-source release as **LocalCloud Stack** under the MIT license.
- `install.sh` validated installer (fail-closed secret checks; generates the
  user systemd unit for the actual checkout path). `run.sh` kept as a
  compatibility wrapper.
- `restore.sh` - ownership-safe restore from the encrypted restic backup.
- `mattermost-postgres-dump` sidecar for the `chat` profile, creating logical
  PostgreSQL dumps of Mattermost chat history before the nightly restic backup.
- Encrypted, versioned **restic** backups with daily/weekly/monthly retention,
  replacing the plain rsync mirror.
- Network segmentation: `edge`, `mgmt`, `db` (internal), and `dns` bridges; the
  backup container runs with no network access.
- Opt-in profiles, all off by default: `dns` (AdGuard), `mgmt` (Portainer),
  `chat` (Mattermost + PostgreSQL).
- `CODE_OF_CONDUCT.md`, `CONTRIBUTING.md`, `SECURITY.md`, GitHub CI, and
  issue/PR templates.
- `docs/tailscale.md` - Tailscale integration design for the Private (Tier B)
  transport: host-level install, installer integration, and the first Tier B
  service contract.

### Changed
- `install.sh` validates `TAILSCALE_ENABLED`/`TAILSCALE_IP` fail-closed and
  persists the detected tailscale0 address to `.env` for future Tier B service
  binds.
- README, deployment runbook, and architecture docs updated for the
  three-tier exposure model and the optional Tailscale transport.
- SECURITY.md now defines a three-tier exposure model (Public / Private /
  Internal) with per-tier mandatory controls and a Tailscale remote-access
  policy.
- CI rejects unbounded `"<port>:<port>"` publishes in compose files so future
  Private-tier services cannot silently bind to all interfaces.
- AdGuard moved behind the `dns` profile; the installer reconfigures the host
  resolver only when that profile is enabled.
- Installer profile handling is now normalized and fail-closed; rerunning the
  installer stops any old LocalCloud containers before starting the selected
  profile set through the generated systemd user service.
- Gitea registration and anonymous view locked down; n8n hardened (explicit
  encryption key, SSRF protection, public API and higher-risk nodes disabled).
- Dev ports moved from an auto-loaded override to an explicit `compose.dev.yml`
  bound to `127.0.0.1`.
- Mattermost and PostgreSQL images are overridable via `.env`.

### Fixed
- Generated systemd user unit no longer quotes `WorkingDirectory`. systemd does
  not strip quotes from that directive, so the quoted path was not absolute and
  systemd >= 253 rejected the whole unit with "has a bad unit file setting".
  The reference unit in `systemd/` had the same defect, and CI now rejects
  quoted path directives.
- `install.sh` fails closed when `LOCALCLOUD_PROFILES` is set but the installed
  podman-compose has no `--profile` flag (added in 1.1.0; Ubuntu 24.04 ships
  1.0.6). Previously the pre-start cleanup swallowed the resulting
  `invalid choice: 'dns'` argparse error and the broken flags were still baked
  into the systemd unit.
- Installer surfaces real diagnostics (`systemctl status` + `journalctl`) when
  the stack fails to start, instead of exiting on a bare systemd error line.
- Backup mount guard now checks a marker file on the volume. The previous
  `mountpoint -q` check was defeated by the container bind-mount and never
  fired, so an unmounted disk could silently fill the host filesystem.
- Restore now uses the same validated optional profiles for stopping and
  restarting the stack.
- Backup run history persists on the backup volume (survives container
  recreation).
- Mattermost chat history now has a restore-friendly logical dump in addition
  to the raw PostgreSQL data directory snapshot.

### Security
- All examples genericized; personal domain and IP removed from the working
  tree and from git history.
