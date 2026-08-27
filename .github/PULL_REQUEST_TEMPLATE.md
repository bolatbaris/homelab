## Summary

<!-- What does this change, and why? -->

## Checklist

- [ ] Defaults stay safe for private data (no new public host ports unless LAN-bound and documented).
- [ ] Optional/heavy services stay behind profiles.
- [ ] Security-sensitive changes fail closed (require explicit config rather than guessing).
- [ ] Updated `README.md`, `deployment.md`, and `SECURITY.md` if behavior changed.
- [ ] Ran locally:
  - [ ] `bash -n install.sh && bash -n restore.sh && bash -n run.sh && sh -n backup/backup.sh && sh -n backup/pg-dump.sh && sh -n db/initdb/10-appdb-seed.sh`
  - [ ] `podman-compose -f docker-compose.yml config`
  - [ ] `podman-compose -f docker-compose.yml --profile dns --profile mgmt --profile chat config`
  - [ ] `git diff --check`
