# Contributing

Thanks for improving LocalCloud Stack.

## Development Setup

```sh
cp .env.example .env
podman-compose -f docker-compose.yml -f compose.dev.yml config
```

Do not commit `.env`, `data/`, `mock-usb/`, generated service units, or local runtime databases.

## Pull Request Checklist

- Keep defaults safe for private data.
- Do not add public host ports unless they are LAN-bound and documented.
- Keep optional/heavy services behind profiles.
- Update `README.md`, `deployment.md`, and `SECURITY.md` when behavior changes.
- Run:
  ```sh
  bash -n install.sh
  bash -n run.sh
  sh -n backup/backup.sh
  podman-compose -f docker-compose.yml config
  git diff --check
  ```

## Security Changes

Security-sensitive changes should fail closed. Prefer requiring explicit configuration over guessing.

## License

By contributing, you agree that your contribution is licensed under the MIT license.
