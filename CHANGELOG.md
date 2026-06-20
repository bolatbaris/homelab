# Changelog

Notable changes to LocalCloud Stack. Format loosely follows
[Keep a Changelog](https://keepachangelog.com/).

## [Unreleased]

### Added
- Open-source release as **LocalCloud Stack** under the MIT license.
- `install.sh` validated installer (fail-closed secret checks; generates the
  user systemd unit for the actual checkout path). `run.sh` kept as a
  compatibility wrapper.
- `restore.sh` — ownership-safe restore from the encrypted restic backup.
- Encrypted, versioned **restic** backups with daily/weekly/monthly retention,
  replacing the plain rsync mirror.
- Network segmentation: `edge`, `mgmt`, `db` (internal), and `dns` bridges; the
  backup container runs with no network access.
- Opt-in profiles, all off by default: `dns` (AdGuard), `mgmt` (Portainer),
  `chat` (Mattermost + PostgreSQL).
- `CODE_OF_CONDUCT.md`, `CONTRIBUTING.md`, `SECURITY.md`, GitHub CI, and
  issue/PR templates.

### Changed
- AdGuard moved behind the `dns` profile; the installer reconfigures the host
  resolver only when that profile is enabled.
- Gitea registration and anonymous view locked down; n8n hardened (explicit
  encryption key, SSRF protection, public API and higher-risk nodes disabled).
- Dev ports moved from an auto-loaded override to an explicit `compose.dev.yml`
  bound to `127.0.0.1`.
- Mattermost and PostgreSQL images are overridable via `.env`.

### Fixed
- Backup mount guard now checks a marker file on the volume. The previous
  `mountpoint -q` check was defeated by the container bind-mount and never
  fired, so an unmounted disk could silently fill the host filesystem.
- Backup run history persists on the backup volume (survives container
  recreation).

### Security
- All examples genericized; personal domain and IP removed from the working
  tree and from git history.
