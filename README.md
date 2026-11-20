# deepseek-harness-ssh

![Build](https://github.com/yoookas/dsh-docker/actions/workflows/build-ssh-image.yml/badge.svg)
![Release](https://img.shields.io/github/v/release/yoookas/dsh-docker?include_prereleases&label=release)
![License](https://img.shields.io/github/license/yoookas/dsh-docker)

在 [`smanx/deepseek-harness`](https://hub.docker.com/r/smanx/deepseek-harness/tags) 之上加装 **OpenSSH Server** 的衍生镜像，
并且**每小时自动检查上游 `devtools-<版本>` 标签是否有更新**：一有新版本就拉取该镜像 → 重新构建 → 冒烟测试 → 导出成离线镜像文件 → 发布到 GitHub Release。

> 跟踪的是 `devtools-*` 变体（自带 git / vim / htop / python3 / build-essential / pnpm / uv 等）。
> 这类镜像本来就是拿来「进去干活」的，配上 SSH 才是完整形态。

- 🔍 **自动跟版**：每小时比对上游 `manifest` 摘要，没有更新就秒级跳过，不浪费构建时间。
- 🐳 **离线包发布**：不推镜像仓库，构建产物直接作为 Release 附件（`*.tar.gz`），`docker load` 即可用。
- 🏷️ **tag 与上游对齐**：上游发布 `devtools-0.2.2-rc.5`，本仓库的 Release 也叫 `devtools-0.2.2-rc.5`。
- 🔐 **密码不落镜像**：root 密码由环境变量 `SSH_ROOT_PASSWORD` 在容器启动时写入。
- 🧰 **自带 gh**：在上游 devtools 变体基础上补装 GitHub CLI，SSH 进去就能直接提 PR / 看 issue。
- ✅ **每次构建都做冒烟测试**：真开容器、真用密码 SSH 登录、真验证错误密码被拒。

---

## 与上游镜像的差别

| 能力 | 上游 `smanx/deepseek-harness` | 本镜像 `deepseek-harness-ssh` |
| --- | --- | --- |
| DSH Web（3080） | ✅ | ✅ 完全一致（直接沿用上游入口） |
| OpenSSH Server | ❌ | ✅ 预装并随容器启动 |
| GitHub CLI（gh） | ❌ | ✅ 预装（token 用环境变量传） |
| root 密码 | — | ✅ 环境变量 `SSH_ROOT_PASSWORD` 指定 |
| 公钥登录 | — | ✅ `SSH_AUTHORIZED_KEYS` / Docker secret |
| 镜像分发 | Docker Hub | GitHub Release 附件（离线 tar.gz） |
| 版本 | 上游 `devtools-<版本>` | 跟随上游同 tag，自动构建发布 |

---

## 快速开始

```bash
# 1. 到 Releases 页面下载对应架构的镜像包（Release tag 与上游一致）
#    -rc / -beta 版本会被标记为 pre-release，所以链接里用具体 tag：
curl -LO https://github.com/yoookas/dsh-docker/releases/download/devtools-0.2.2-rc.5/deepseek-harness-ssh-devtools-0.2.2-rc.5-linux-arm64.tar.gz   # 或 -linux-amd64.tar.gz
# 上游发布正式版后，也可以用 .../releases/latest/download/<文件名>

# 2. 加载镜像（docker load 直接支持 .tar.gz）
docker load -i deepseek-harness-ssh-devtools-0.2.2-rc.5-linux-<arch>.tar.gz

# 3. 启动
docker run -d --name dsh-ssh \
  -p 3080:3080 \
  -p 2222:22 \
  -e SSH_ROOT_PASSWORD='换成你自己的密码' \
  -v dsh-data:/root/.dsh \
  deepseek-harness-ssh:devtools-0.2.2-rc.5

# 4. 使用
#    Web : http://127.0.0.1:3080/
#    SSH : ssh -p 2222 root@127.0.0.1
```

或者用现成的 compose 示例：[`examples/docker-compose.yml`](examples/docker-compose.yml)。

---

## 工作原理

```
                    ┌────────────────────────── 每小时（cron 7 * * * *）──────────────────────────┐
                    │                                                                          │
  Docker Hub ───────▶ 1. 取上游最高版本 tag + manifest 摘要 ──▶ 与 state/upstream.json 比对         │
  (smanx/...)       │                                              │                           │
                    │                         未变化 ──────────────┴── 有变化                    │
                    │                            │                        │                    │
                    │                            ▼                        ▼                    │
                    │                      跳过（秒级结束）      2. docker pull 上游镜像         │
                    │                                                     │                    │
                    │                                         3. 构建衍生镜像（装 sshd）        │
                    │                                                     │                    │
                    │                                         4. 冒烟测试（真 SSH 登录）        │
                    │                                                     │                    │
                    │                                         5. 导出 tar.gz + SHA256SUMS     │
                    │                                                     │                    │
                    │                                         6. 发布 GitHub Release          │
                    │                                            （tag = 上游版本号）           │
                    │                                                     │                    │
                    └─────────────────────────────────────────────────────┼────────────────────┘
                                                                           ▼
                                                              回写 state/upstream.json
```

关键点：

1. **检测**：`scripts/upstream-fingerprint.sh` 通过 Docker Hub API 取 tag 列表，在 `devtools-<版本>` 里挑最高版本
   （如 `devtools-0.2.2-rc.5`）；API 不可用时自动退回 `docker buildx imagetools inspect` 读 registry manifest。
2. **去重**：`state/upstream.json` 记录上次成功发布的指纹（版本号 + manifest 摘要）。指纹不变就不构建。
   构建失败**不会**更新状态，所以下一小时会自动重试。
3. **构建**：`docker/Dockerfile` 基于上游镜像 `apt-get install openssh-server`，再叠加启动脚本。
4. **冒烟测试**：`scripts/smoke-test.sh` 启动容器 → 用 `SSH_ROOT_PASSWORD` 登录 → 断言是 root →
   断言错误密码被拒 → 断言容器没有退出。测试不过就不发布。
5. **发布**：`scripts/publish-release.sh` 调 GitHub API 建 Release、传附件（同名旧附件会先删后传，可重复执行）。

---

## 环境变量

| 变量 | 默认值 | 说明 |
| --- | --- | --- |
| `SSH_ROOT_PASSWORD` | 空 | **root 密码**。容器启动时 `chpasswd` 写入，不进入镜像层 |
| `SSH_ROOT_PASSWORD_FILE` | 空 | 从文件读密码，优先级低于上面的变量（适合 Docker secret） |
| `SSH_AUTHORIZED_KEYS` | 空 | 直接写入 root 的 `authorized_keys`，多行用 `\n` 分隔 |
| `SSH_AUTHORIZED_KEYS_FILE` | 空 | 从文件读公钥 |
| `SSH_PORT` | `22` | 容器内 sshd 监听端口 |
| `SSH_LISTEN_ADDRESS` | `0.0.0.0` | sshd 监听地址 |
| `SSH_PERMIT_ROOT_LOGIN` | `yes` | 对应 sshd `PermitRootLogin`，常用 `yes` / `prohibit-password` / `no` |
| `SSH_PASSWORD_AUTHENTICATION` | `auto` | `auto`＝有密码就开、没密码就关；也可显式 `yes` / `no` |
| `SSH_ENABLED` | `true` | `false` 时完全不启动 sshd，只跑 DSH（等价于上游镜像） |
| `DSH_APP_ENABLED` | `true` | `false` 时只开 SSH，不启动 DSH，方便进容器排障 |
| `SSH_HOST_KEY_B64` | 空 | base64 的 ed25519 主机私钥，用于固定主机指纹（不设则首启自动生成） |
| `SSH_AUTO_CD` | 空 | 设为任意值可关闭「登录后自动 `cd /app`」 |
| `GH_TOKEN` | 空 | 可选，供容器内的 `gh` 使用（gh 会自动读取，不会打进镜像） |

上游镜像自身的变量照常可用，例如 `DSH_PORT`、`PROXY_PORT`、`PROXY_USERNAME`、`PROXY_PASSWORD`。

> ⚠️ `SSH_ROOT_PASSWORD` 会出现在 `docker inspect` 的环境变量里。
> 对安全敏感的场景请用 `SSH_AUTHORIZED_KEYS` 只开公钥登录，或改用 `SSH_ROOT_PASSWORD_FILE` + Docker secret。

---

## 镜像内置工具

在上游 `devtools` 变体的基础上，本镜像额外提供：

| 工具 | 说明 |
| --- | --- |
| `openssh-server` | 本镜像的核心增量，随容器启动 |
| `gh` | GitHub CLI，容器内可直接 `gh repo view` / `gh pr create` |

`devtools` 变体本身已自带 git / curl / wget / vim / htop / tmux / jq / python3 / build-essential / pnpm / uv 等。

容器内使用 `gh` 时，把 token 通过环境变量传进去即可（token 不会写入镜像层）：

```bash
docker run -d --name dsh-ssh \
  -p 2222:22 -p 3080:3080 \
  -e SSH_ROOT_PASSWORD='pass' \
  -e GH_TOKEN='github_pat_xxx' \
  -v dsh-data:/root/.dsh \
  deepseek-harness-ssh:devtools-0.2.2-rc.5

# 进容器后
gh auth status
```

`gh` 会读取 `GH_TOKEN` / `GITHUB_TOKEN`；交互式登录状态保存在 `/root/.config/gh`，需要持久化就挂个卷。

## SSH 用法

### 密码登录

```bash
docker run -d --name dsh-ssh -p 2222:22 -p 3080:3080 \
  -e SSH_ROOT_PASSWORD='My-Strong-Passw0rd' \
  -v dsh-data:/root/.dsh \
  deepseek-harness-ssh:devtools-0.2.2-rc.5

ssh -p 2222 root@127.0.0.1
```

容器每次启动都会按环境变量重置 root 密码，改密码 = 改环境变量重启。

### 公钥登录（推荐）

```bash
docker run -d --name dsh-ssh -p 2222:22 -p 3080:3080 \
  -e SSH_AUTHORIZED_KEYS="$(cat ~/.ssh/id_ed25519.pub)" \
  -e SSH_PASSWORD_AUTHENTICATION=no \
  -v dsh-data:/root/.dsh \
  deepseek-harness-ssh:devtools-0.2.2-rc.5
```

### 固定主机指纹

容器重建后主机密钥会变，`ssh` 会报 `REMOTE HOST IDENTIFICATION HAS CHANGED`。两种解决办法：

```bash
# 方案 A：把主机密钥持久化
docker run ... -v ssh-hostkeys:/etc/ssh ...

# 方案 B：用固定的 ed25519 私钥（base64 后传进来）
ssh-keygen -t ed25519 -N '' -f ./host_key
docker run ... -e SSH_HOST_KEY_B64="$(base64 -w0 ./host_key)" ...
```

### 只开 SSH（排障）

```bash
docker run -d --name dsh-debug -p 2222:22 \
  -e SSH_ROOT_PASSWORD='pass' -e DSH_APP_ENABLED=false \
  deepseek-harness-ssh:devtools-0.2.2-rc.5
```

### 不跑应用直接执行命令

入口脚本沿用了 Docker 的约定：给了命令就不跑上游入口。

```bash
docker run --rm -it -e SSH_ROOT_PASSWORD=x deepseek-harness-ssh:devtools-0.2.2-rc.5 bash
```

---

## Release 与 tag 规则

- **Release tag = 上游 tag**，例如上游发布了 `devtools-0.2.2-rc.5`，本仓库就发 `devtools-0.2.2-rc.5`。
- 版本号里带 `-rc` / `-beta` / `-alpha` / `-dev` 的，Release 会自动标记为 **pre-release**。
- 如果跟踪的 tag 不带版本号（例如 `devtools-latest`），Release tag 会追加 8 位摘要后缀
  （`devtools-latest-1a2b3c4d`），保证 tag 不可变、附件不会被反复覆盖。
- 附件命名：`deepseek-harness-ssh-<上游 tag>-linux-<arch>.tar.gz` + `SHA256SUMS.txt`。
- 加载后的本地镜像名：`deepseek-harness-ssh:<tag>`，另有 `deepseek-harness-ssh:<tag>-<arch>` 方便区分架构。

---

## 仓库配置

### Variables（Settings → Secrets and variables → Actions → Variables）

| 名称 | 默认值 | 说明 |
| --- | --- | --- |
| `UPSTREAM_TRACK` | `version` | `version`＝跟 `devtools-<最高版本>`；`tag`＝跟固定 tag |
| `UPSTREAM_TAG_PREFIX` | `devtools` | 版本模式的 tag 前缀；设为 `none` 则跟踪纯版本号 `0.2.2-rc.5` |
| `UPSTREAM_TAG` | `devtools-latest` | `UPSTREAM_TRACK=tag` 时要跟踪的固定 tag |
| `PLATFORMS` | `linux/amd64` | 本仓库当前为 `linux/amd64,linux/arm64`（arm64 走 QEMU，构建更慢） |

### Secrets（可选）

| 名称 | 用途 |
| --- | --- |
| `DOCKERHUB_USERNAME` / `DOCKERHUB_TOKEN` | 登录 Docker Hub 拉取上游镜像，避免匿名拉取限流 |

> 不需要配置 `GITHUB_TOKEN`，工作流用的是内置 token（`permissions: contents: write`）。

### 手动触发

Actions → **Build SSH image** → *Run workflow*：

- 勾选 `force`：忽略指纹比对，强制重建一次（升级 Dockerfile 后想立刻出包时用）。
- 填 `upstream_tag`：临时指定版本号 / tag 构建，例如 `0.2.1`。

---

## 本地构建与测试

```bash
make prepare        # 读取上游 ENTRYPOINT/CMD，生成 docker/upstream-launch.sh
make build          # 构建 deepseek-harness-ssh:local
make run            # 起容器：SSH 2222 / Web 3080，密码 devpass
make smoke          # 冒烟测试（真登录）
make lint           # shellcheck + dash/bash 语法检查 + hadolint
make fingerprint    # 只看上游有没有新版本（不构建）
```

不用 make 也可以：

```bash
docker build -f docker/Dockerfile -t deepseek-harness-ssh:local .
docker run -d -p 2222:22 -p 3080:3080 -e SSH_ROOT_PASSWORD=test deepseek-harness-ssh:local
ssh -p 2222 root@127.0.0.1
```

---

## 目录结构

```
.
├─ .github/
│  ├─ workflows/
│  │  ├─ build-ssh-image.yml   # 每小时检测 + 构建 + 冒烟 + 发布 Release
│  │  ├─ ci.yml                # PR 校验：lint / 构建 / 打包还原 / 冒烟
│  │  └─ keepalive.yml         # 每月心跳，防止 60 天无活动被停用定时任务
│  └─ dependabot.yml
├─ docker/
│  ├─ Dockerfile               # FROM smanx/deepseek-harness + openssh-server
│  ├─ install-openssh.sh       # 构建期安装 sshd（apt/apk/dnf 自适应）
│  ├─ install-gh.sh            # 构建期安装 GitHub CLI（apt 源 / 二进制包回退）
│  ├─ entrypoint.sh            # 启动期：写 sshd 配置 → 起 sshd → exec 上游入口
│  ├─ healthcheck.sh           # 探活 22 端口
│  └─ upstream-launch.sh       # 上游入口桥接（构建期由脚本重新生成）
├─ scripts/
│  ├─ upstream-fingerprint.sh  # 上游版本/摘要检测
│  ├─ gen-launcher.sh          # 生成上游入口桥接脚本
│  ├─ detect-app-version.sh    # 从镜像里读出 DSH 版本号
│  ├─ make-release-notes.sh    # 生成 Release 说明
│  ├─ publish-release.sh       # 建 Release + 传附件（支持 DRY_RUN）
│  ├─ smoke-test.sh            # 冒烟测试
│  └─ create-repo.sh           # 一键建仓库并推送（本机没有 gh 时用）
├─ tests/selftest.sh           # 脚本自测（不联网、不依赖 docker）
├─ state/upstream.json         # 上次发布对应的上游指纹（CI 自动回写）
├─ examples/docker-compose.yml
└─ Makefile
```

---

## 安全须知

1. 本镜像允许 **root 通过 SSH 登录**，只适合放在内网 / 本机；暴露公网请改用公钥登录 + 防火墙 + 端口转发。
2. `SSH_ROOT_PASSWORD` 是环境变量，能读到容器配置的人都能看到，敏感环境建议 `SSH_ROOT_PASSWORD_FILE` + Docker secret。
3. 主机密钥在容器首次启动时生成，不随镜像分发（避免所有部署共用同一指纹）；
   需要稳定指纹时用 `SSH_HOST_KEY_B64` 或挂载 `/etc/ssh`。
4. 镜像内的 DSH 仍然监听 `127.0.0.1:3079`，对外由上游代理监听 `3080`，SSH 登录不改变这套网络模型。

---

## 常见问题

**Q：为什么跟的是 `devtools-*` 变体？**
A：`devtools` 变体预装了 git / vim / htop / python3 / build-essential / pnpm / uv 等工具，配 SSH 才是「能进去干活」的形态；
如果更想要精简版，把仓库变量 `UPSTREAM_TAG_PREFIX` 改成 `devtools-min`（或 `none` 以跟踪 `0.2.2-rc.5` 这类纯版本 tag）即可。

**Q：Releases 里为什么有两个文件？**
A：`linux-amd64` 与 `linux-arm64`。本仓库的 `PLATFORMS` 变量已设为 `linux/amd64,linux/arm64`，
每次发版都同时产出两个架构；只想要 amd64 就把该变量改回 `linux/amd64`，构建会快不少。

**Q：多久检查一次？可以改吗？**
A：默认每小时第 7 分钟（`.github/workflows/build-ssh-image.yml` 里的 `cron: "7 * * * *"`）。
GitHub 的定时任务在高峰期会延迟几分钟；改动 cron 即可调整频率。

**Q：为什么某次没构建？**
A：上游指纹没变就会跳过（看 Actions 里 “无更新，跳过” 的 job 说明）。想强制重建就手动触发并勾 `force`。

**Q：工作流会不会被 GitHub 停掉？**
A：仓库 60 天无活动时 GitHub 会自动停用定时工作流，所以仓库里带了 `keepalive.yml` 每月写一次心跳。

**Q：私有仓库会不会很费 Actions 分钟数？**
A：检测 job 每次约 20–30 秒；只有真有新版本时才跑完整构建（几分钟）。一天 24 次检测 ≈ 10 分钟出头。

**Q：上游改了 ENTRYPOINT 怎么办？**
A：构建时会用 `docker image inspect` 读出真实的 ENTRYPOINT/CMD 重新生成桥接脚本，不硬编码，上游调整入口也能跟上。

**Q：密码里能有冒号吗？**
A：可以（`chpasswd` 按第一个冒号切分）。但**不能有换行**，入口脚本会直接报错退出。

**Q：能只用 SSH、不跑 DSH 吗？**
A：`-e DSH_APP_ENABLED=false`，容器会保持运行但只提供 SSH。

---

## 致谢

- 上游应用：[deepseek-ai/deepseek-harness](https://github.com/deepseek-ai/deepseek-harness)
- 上游镜像构建：[smanx/deepseek-harness-docker](https://github.com/smanx/deepseek-harness-docker)

## License

[MIT](LICENSE)
