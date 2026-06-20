## Summary

<!-- What does this change, and why? -->

## Checklist

- [ ] Defaults stay safe for private data (no new public host ports unless LAN-bound and documented).
- [ ] Optional/heavy services stay behind profiles.
- [ ] Security-sensitive changes fail closed (require explicit config rather than guessing).
- [ ] Updated `README.md`, `deployment.md`, and `SECURITY.md` if behavior changed.
- [ ] Ran locally:
  - [ ] `bash -n install.sh && bash -n run.sh && sh -n backup/backup.sh`
  - [ ] `podman-compose -f docker-compose.yml config`
  - [ ] `git diff --check`
