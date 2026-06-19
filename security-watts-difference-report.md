# Productization, Security, And Watts Report

Date: 2026-06-19

## Productization Summary

The repository was converted from a personal homelab configuration into a reusable self-hosted product template.

Important changes:

- Public project name: LocalCloud Stack.
- MIT license added.
- `install.sh` added as the primary installer.
- `run.sh` kept only as a compatibility wrapper.
- Personal domains, names, and fixed private assumptions removed from tracked docs and examples.
- `.env.example` now uses generic sample values.
- systemd unit is generated dynamically for the actual checkout path.
- public docs now describe install, security, architecture, contribution, and restore workflows.

## Security Difference

| Area | Before | After | Risk Change |
|---|---|---|---|
| Installation | manual/private deployment script | reusable `install.sh` with validation | lower operator error |
| Public identity | personal domain/IP in examples | generic sample domain/IP | safer public release |
| License | no public license | MIT license | legally reusable |
| Portainer | default-capable management surface | opt-in `mgmt` profile | high reduction |
| Mattermost | default-capable public chat/database | opt-in `chat` profile | high reduction |
| Dev ports | auto-loaded override risk | explicit `compose.dev.yml` | high reduction |
| Gitea | registration/install-lock risk in runtime config | locked registration/sign-in defaults | critical reduction |
| n8n | minimal security defaults | explicit key, SSRF protection, API/playground disabled, risky nodes blocked | high reduction |
| Backups | plain rsync mirror | encrypted/versioned restic snapshots | high reduction |
| Backup container | normal network access | `network_mode: none` | medium reduction |
| Networks | single flat bridge | separated edge/mgmt/db/dns networks | medium reduction |

## Watts Difference

No wall-meter measurement was taken. These are engineering estimates.

Expected idle reduction:

| Change | Expected Direction | Why |
|---|---|---|
| Mattermost disabled by default | lower | removes app server plus Postgres |
| Portainer disabled by default | slightly lower | removes management UI process |
| restic backup | similar idle, higher backup-window CPU | encrypted snapshots use CPU only during backup |
| n8n retention reduced | slightly lower disk churn | less execution data retained |

Practical estimate:

- Disabling Mattermost + Postgres by default may save roughly 1-4 W at idle on older laptops.
- Disabling Portainer by default may save less than 1 W.
- Restic may add temporary CPU load during the scheduled backup.

Measure real watts with a wall power meter:

1. Start base stack and let it idle for 20 minutes.
2. Record a 10-minute average.
3. Enable optional profiles:
   ```sh
   podman-compose -f docker-compose.yml --profile mgmt --profile chat up -d
   ```
4. Let it idle for 20 minutes.
5. Record another 10-minute average.

## Remaining Product Work

- Publish a release tarball or container image set.
- Add CI once a public remote exists.
- Decide whether this remains a self-hosted product or grows into a hosted SaaS with a control plane.
- Pin image versions/digests for production releases.
- Add an upgrade command or documented release upgrade flow.
