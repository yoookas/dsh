# dsh

![Build](https://github.com/yoookas/dsh-docker/actions/workflows/build-ssh-image.yml/badge.svg)
![Release](https://img.shields.io/github/v/release/yoookas/dsh-docker?include_prereleases&label=release)
![License](https://img.shields.io/github/license/yoookas/dsh-docker)

[`smanx/deepseek-harness`](https://hub.docker.com/r/smanx/deepseek-harness/tags) 的衍生镜像：
在 `devtools-<版本>` 变体上加装 **OpenSSH Server** 和 **gh**，root 密码由环境变量指定。

仓库每小时检查上游是否更新，有新版本就自动构建、冒烟测试，导出 `tar.gz` 发到 Release（tag 与上游一致）。

## 快速开始

```bash
# 1. 下载并加载（arm64 机器换成 -linux-arm64）
curl -LO https://github.com/yoookas/dsh-docker/releases/download/devtools-0.2.2-rc.5/dsh-devtools-0.2.2-rc.5-linux-amd64.tar.gz
docker load -i dsh-devtools-0.2.2-rc.5-linux-amd64.tar.gz

# 2. 启动
docker run -d --name dsh \
  -p 3080:3080 -p 2222:22 \
  -e SSH_ROOT_PASSWORD='换成你的密码' \
  -v dsh-data:/root/.dsh \
  dsh:devtools-0.2.2-rc.5

# 3. 访问
#   Web: http://127.0.0.1:3080/
#   SSH: ssh -p 2222 root@127.0.0.1
```

也提供了 compose 示例：[`examples/docker-compose.yml`](examples/docker-compose.yml)。

### 目录挂载

| 宿主机 | 容器内 | 内容 |
| --- | --- | --- |
| `./dsh-data` | `/root/.dsh` | 会话 / 配置（上游约定） |
| `./ssh` | `/etc/ssh` | 主机密钥 + sshd 配置；挂上后重建容器指纹不变 |
| `./workspaces` | `/workspace` | 工作区，Web UI 里把 `/workspace` 添加为工作区 |

`/etc/ssh` 首次挂载为空时会自动生成 `sshd_config` 和主机密钥，不需要手动准备；之后配置就固定下来了。

## 环境变量

| 变量 | 默认 | 说明 |
| --- | --- | --- |
| `SSH_ROOT_PASSWORD` | – | root 密码，启动时写入 |
| `SSH_ROOT_PASSWORD_FILE` | – | 从文件读密码（Docker secret） |
| `SSH_AUTHORIZED_KEYS` | – | root 的公钥（多行用 `\n`） |
| `SSH_PORT` | `22` | 容器内 sshd 端口 |
| `SSH_PERMIT_ROOT_LOGIN` | `yes` | 可改 `prohibit-password` |
| `SSH_ENABLED` | `true` | `false` 时不启动 sshd |
| `DSH_APP_ENABLED` | `true` | `false` 时只开 SSH，不跑 DSH |
| `GH_TOKEN` | – | 给容器内的 `gh` 用 |

上游变量（`DSH_PORT`、`PROXY_USERNAME` 等）照常生效。

## 工作原理

1. 每小时拉一次上游 tag 列表，在 `devtools-<版本>` 里挑最高版本，取 manifest 摘要当指纹。
2. 指纹与 `state/upstream.json` 一致就跳过；不一致才 `docker pull` 上游镜像并重建（构建失败不写状态，下一小时重试）。
3. 构建：上游镜像 + `openssh-server` + `gh`；入口脚本先起 sshd，再 exec 上游命令。
4. 冒烟：真起容器、真用密码 SSH 登录、断言身份是 root、错误密码被拒。
5. 导出 `tar.gz` + `SHA256SUMS.txt` → 发布 Release（tag 与上游一致，`-rc` 自动标 pre-release）。

## 仓库配置

| 变量 | 默认 | 说明 |
| --- | --- | --- |
| `PLATFORMS` | 本仓库为 `linux/amd64,linux/arm64` | 构建哪些架构 |
| `UPSTREAM_TRACK` | `version` | `version` 跟版本号，`tag` 跟固定 tag |
| `UPSTREAM_TAG_PREFIX` | `devtools` | 版本模式的前缀，`none` 表示纯版本号 |
| `UPSTREAM_TAG` | `devtools-latest` | `UPSTREAM_TRACK=tag` 时用 |

手动重建：Actions → **Build SSH image** → Run workflow → 勾 `force`。

## 镜像体积

镜像约 **530 MB**，其中上游 devtools 变体 514 MB，本镜像只多约 15 MB（`gh` 42 MB + `openssh-server` 5.8 MB，减去清掉的文档/man/apt 缓存）。

Release 里的 `.tar.gz` 是**另一份拷贝**（527 MB，内容已压缩，gzip 几乎压不动）——`docker load` 完就可以删掉；重复导入新版本时，旧的同名镜像会变成 `<none>` 悬空镜像，记得 `docker image prune -f`。

## 注意

- 允许 root 密码登录，只建议内网使用；更稳妥的是 `SSH_AUTHORIZED_KEYS` + `SSH_PASSWORD_AUTHENTICATION=no`。
- 密码走环境变量，`docker inspect` 可见；敏感场景用 `SSH_ROOT_PASSWORD_FILE`。
- 主机密钥在容器首启时生成，不随镜像分发。

## 致谢

- 应用：[deepseek-ai/deepseek-harness](https://github.com/deepseek-ai/deepseek-harness)
- 基础镜像：[smanx/deepseek-harness-docker](https://github.com/smanx/deepseek-harness-docker)

## License

[MIT](LICENSE)
