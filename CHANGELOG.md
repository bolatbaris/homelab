# Changelog

Notable changes to LocalCloud Stack. Format loosely follows
[Keep a Changelog](https://keepachangelog.com/).

## [Unreleased]

### Added
- `backup-autounlock.sh` - configures the LUKS backup disk to unlock and mount
  itself at boot, so backups survive a power cut with nobody present. Backs up
  the LUKS header first, adds the keyfile as an additional slot while keeping
  the existing passphrase, writes UUID-keyed `crypttab` and `fstab` entries with
  `nofail`, and is idempotent. `--rollback` reverses it and refuses to run if
  that would leave fewer than two key slots. `install.sh` never calls it: the
  keyfile lives on the host root disk, which changes what the disk encryption
  protects against, so it stays an explicit operator decision. The installer
  does note when the backup path is absent from `/etc/fstab`.
- Deployment runbook section on power loss and unattended restart: what returns
  on its own, what does not, and the post-outage verification checklist.
- Documented that a backup disk mounted while the stack is already running needs
  `podman restart backup`, because Podman resolves the bind mount at container
  creation and does not follow a host mount that appears afterwards.
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
- Backup failures are visible again. `backup.sh` wrote aborts only to a log file
  inside the container, which cron also captured and which disappears when the
  container is recreated, so a stack whose nightly backup had been aborting said
  nothing. Both aborts and run progress now also go to the container's stdout,
  where `podman logs backup` shows them.
- The installer warns when `TAILSCALE_ENABLED=true` but `tailscaled` is not
  enabled at boot, since remote access would otherwise not return after a power
  cut.
- Mattermost and its dump sidecar order on `depends_on` alone instead of
  `condition: service_healthy`. Podman runs healthchecks as systemd user timers;
  when that timer cannot be created the health state stays `starting` forever,
  so a health-gated dependency blocked `up -d` until the unit's start timeout
  even though PostgreSQL was accepting connections the whole time. The
  healthcheck is kept for visibility and manual runs.
- Generated systemd unit bounds its restart loop (`StartLimitBurst=3`) and gets
  `TimeoutStopSec=300`. A failing start previously retried indefinitely, and
  every retry SIGKILLed the unit cgroup including each container's `conmon`,
  which left containers stuck in the `Stopping` state that only a force-remove
  clears.
- Gitea data directory ownership. The installer mapped the rootless uid for n8n
  and Mattermost but never for Gitea, whose process runs as uid 1000 inside the
  container. With `./data/<svc>` hardened to 0700 the directory reads as
  root-owned inside the user namespace, so Gitea failed with
  `stat /data/gitea/conf/app.ini: permission denied` and crash-looped until the
  unit hit its start timeout.
- Images are pulled before the stack is handed to systemd, and the unit's
  `TimeoutStartSec` is raised to 900s. A cold install previously expired the
  120s timeout mid-pull and left a half-started stack.
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
