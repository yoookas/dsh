# deepseek-harness-ssh

A derived image of [`smanx/deepseek-harness`](https://hub.docker.com/r/smanx/deepseek-harness/tags) with **OpenSSH Server** added,
plus an hourly watcher that rebuilds and publishes it to **GitHub Releases** whenever upstream ships a new `devtools-<version>` tag.

- 🔍 **Hourly upstream check** — compares the upstream manifest digest; exits in seconds when nothing changed.
- 🐳 **Offline image tarballs** — no registry pushes; artifacts are `*.tar.gz` release assets, load with `docker load`.
- 🏷️ **Tags mirror upstream** — upstream `devtools-0.2.2-rc.5` ⇒ release `devtools-0.2.2-rc.5`.
- 🔐 **Password never baked in** — root password comes from `SSH_ROOT_PASSWORD` at container start.
- 🧰 **Ships `gh`** — GitHub CLI is installed on top of the upstream `devtools` variant.
- ✅ **Smoke tested** — every build actually starts a container, logs in over SSH, and verifies wrong passwords are rejected.

## Quick start

```bash
# -rc builds are published as pre-releases, so pin the exact tag:
curl -LO https://github.com/yoookas/dsh-docker/releases/download/devtools-0.2.2-rc.5/deepseek-harness-ssh-devtools-0.2.2-rc.5-linux-arm64.tar.gz   # or -linux-amd64.tar.gz
docker load -i deepseek-harness-ssh-devtools-0.2.2-rc.5-linux-<arch>.tar.gz

docker run -d --name dsh-ssh \
  -p 3080:3080 -p 2222:22 \
  -e SSH_ROOT_PASSWORD='change-me' \
  -v dsh-data:/root/.dsh \
  deepseek-harness-ssh:devtools-0.2.2-rc.5

# Web : http://127.0.0.1:3080/
# SSH : ssh -p 2222 root@127.0.0.1
```

A Compose example lives in [`examples/docker-compose.yml`](examples/docker-compose.yml).

## How it works

1. `scripts/upstream-fingerprint.sh` asks the Docker Hub API for the highest `devtools-<version>` tag
   (falling back to `docker buildx imagetools inspect`).
2. The fingerprint is compared with `state/upstream.json`; unchanged ⇒ skip.
   Failed builds do **not** update state, so they retry on the next run.
3. `docker/Dockerfile` installs `openssh-server` on top of the upstream image and adds the entrypoint wrapper.
4. `scripts/smoke-test.sh` starts the image, logs in with the env password, asserts `root`,
   asserts a wrong password is rejected, and asserts the container is still alive.
5. `scripts/publish-release.sh` creates/updates the GitHub Release and uploads the assets.

## Environment variables

| Variable | Default | Description |
| --- | --- | --- |
| `SSH_ROOT_PASSWORD` | – | root password, applied at container start |
| `SSH_ROOT_PASSWORD_FILE` | – | read password from a file (Docker secret) |
| `SSH_AUTHORIZED_KEYS` | – | authorized keys for root |
| `SSH_AUTHORIZED_KEYS_FILE` | – | read keys from a file |
| `SSH_PORT` | `22` | sshd port inside the container |
| `SSH_LISTEN_ADDRESS` | `0.0.0.0` | sshd listen address |
| `SSH_PERMIT_ROOT_LOGIN` | `yes` | sshd `PermitRootLogin` |
| `SSH_PASSWORD_AUTHENTICATION` | `auto` | `auto` = enabled iff a password is set |
| `SSH_ENABLED` | `true` | `false` = no sshd at all (upstream behaviour) |
| `DSH_APP_ENABLED` | `true` | `false` = SSH only, no DSH process |
| `SSH_HOST_KEY_B64` | – | base64 ed25519 host key for a stable fingerprint |
| `SSH_AUTO_CD` | – | set to disable `cd /app` after login |
| `GH_TOKEN` | – | optional token for the bundled `gh` CLI |

Upstream variables such as `DSH_PORT`, `PROXY_PORT`, `PROXY_USERNAME`, `PROXY_PASSWORD` keep working.

## Bundled tools

On top of the upstream `devtools` variant this image adds `openssh-server` and `gh` (GitHub CLI).
The `devtools` variant already provides git, curl, wget, vim, htop, tmux, jq, python3, build-essential, pnpm and uv.

```bash
docker run -d -p 2222:22 -p 3080:3080 \
  -e SSH_ROOT_PASSWORD=pass -e GH_TOKEN=github_pat_xxx \
  -v dsh-data:/root/.dsh deepseek-harness-ssh:devtools-0.2.2-rc.5
```

## Repository configuration

| Kind | Name | Default | Description |
| --- | --- | --- | --- |
| Variable | `UPSTREAM_TRACK` | `version` | `version` = newest `devtools-<semver>` tag, `tag` = a fixed tag |
| Variable | `UPSTREAM_TAG_PREFIX` | `devtools` | prefix for version mode; `none` = plain `0.2.2-rc.5` tags |
| Variable | `UPSTREAM_TAG` | `devtools-latest` | tag to track when `UPSTREAM_TRACK=tag` |
| Variable | `PLATFORMS` | `linux/amd64` | e.g. `linux/amd64,linux/arm64` (QEMU, slower) |
| Secret | `DOCKERHUB_USERNAME` / `DOCKERHUB_TOKEN` | – | optional Docker Hub login to avoid pull limits |

Manual run: **Actions → Build SSH image → Run workflow** (`force` = rebuild even if unchanged).

## Local build

```bash
make prepare   # capture upstream ENTRYPOINT/CMD
make build     # deepseek-harness-ssh:local
make run       # SSH 2222 / Web 3080, password "devpass"
make smoke     # real SSH login test
make lint      # shellcheck + syntax + hadolint
```

## Security notes

- The image allows **root SSH login**; keep it on a private network.
- `SSH_ROOT_PASSWORD` is visible via `docker inspect`; prefer keys or `SSH_ROOT_PASSWORD_FILE`.
- Host keys are generated on first start and are not shipped in the image; pin them with `SSH_HOST_KEY_B64`.

## Credits

- Application: [deepseek-ai/deepseek-harness](https://github.com/deepseek-ai/deepseek-harness)
- Upstream image build: [smanx/deepseek-harness-docker](https://github.com/smanx/deepseek-harness-docker)

## License

[MIT](LICENSE)
