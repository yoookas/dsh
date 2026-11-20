#!/usr/bin/env bash
# 生成 GitHub Release 说明（markdown，输出到 stdout）。
#
# 需要的环境变量（均有默认值）：
#   RELEASE_TAG     本次发布 tag（与上游对齐）
#   UPSTREAM_TAG    上游镜像 tag
#   UPSTREAM_REPO   上游镜像仓库
#   UPSTREAM_DIGEST 上游 manifest 摘要
#   APP_VERSION     上游 DSH 版本
#   PLATFORMS       构建平台列表
#   GITHUB_REPOSITORY / IMAGE_NAME / ASSET_DIR
set -euo pipefail

RELEASE_TAG="${RELEASE_TAG:?缺少 RELEASE_TAG}"
UPSTREAM_TAG="${UPSTREAM_TAG:-devtools-latest}"
UPSTREAM_REPO="${UPSTREAM_REPO:-smanx/deepseek-harness}"
UPSTREAM_DIGEST="${UPSTREAM_DIGEST:-unknown}"
APP_VERSION="${APP_VERSION:-unknown}"
PLATFORMS="${PLATFORMS:-linux/amd64}"
IMAGE_NAME="${IMAGE_NAME:-deepseek-harness-ssh}"
ASSET_DIR="${ASSET_DIR:-dist}"
BUILT_AT="$(date -u '+%Y-%m-%d %H:%M:%S UTC')"

assets_table() {
  local f size
  shopt -s nullglob
  for f in "$ASSET_DIR"/*.tar.gz; do
    size="$(du -h "$f" | cut -f1)"
    # shellcheck disable=SC2016  # 这里的反引号是 markdown 语法，不是命令替换
    printf '| `%s` | %s |\n' "$(basename "$f")" "$size"
  done
  shopt -u nullglob
}

cat <<EOF
## ${IMAGE_NAME} \`${RELEASE_TAG}\`

由 CI 自动构建：跟踪 \`${UPSTREAM_REPO}\`，在其发布新版本后拉取该镜像，
加装 **OpenSSH Server** 与 **GitHub CLI（gh）**（root 密码通过环境变量注入），导出为离线镜像文件随本 Release 发布。

| 项 | 值 |
| --- | --- |
| 上游镜像 | \`${UPSTREAM_REPO}\` |
| 上游 tag | \`${UPSTREAM_TAG}\` |
| 上游摘要 | \`${UPSTREAM_DIGEST}\` |
| DSH 版本 | \`${APP_VERSION}\` |
| 构建平台 | \`${PLATFORMS}\` |
| 构建时间 | ${BUILT_AT} |
| 镜像内 tag | \`${IMAGE_NAME}:${RELEASE_TAG}\` |

### 下载

| 文件 | 大小 |
| --- | --- |
$(assets_table)

校验：\`sha256sum -c SHA256SUMS.txt\`

### 使用

\`\`\`bash
# 1. 下载并加载镜像（docker load 直接支持 .tar.gz）
docker load -i ${IMAGE_NAME}-${RELEASE_TAG}-linux-amd64.tar.gz

# 2. 启动（SSH 的 root 密码由 SSH_ROOT_PASSWORD 指定）
docker run -d --name dsh-ssh \\
  -p 3080:3080 \\
  -p 2222:22 \\
  -e SSH_ROOT_PASSWORD='换成你自己的密码' \\
  -v dsh-data:/root/.dsh \\
  ${IMAGE_NAME}:${RELEASE_TAG}

# 3. 登录
ssh -p 2222 root@127.0.0.1
\`\`\`

Web 界面：<http://127.0.0.1:3080/>

### 环境变量（常用）

| 变量 | 默认值 | 说明 |
| --- | --- | --- |
| \`SSH_ROOT_PASSWORD\` | 空 | root 密码，启动时写入，不打进镜像 |
| \`SSH_ROOT_PASSWORD_FILE\` | 空 | 从文件读取密码（配合 Docker secret） |
| \`SSH_AUTHORIZED_KEYS\` | 空 | 直接写入 root 的公钥（多行用 \`\\n\` 分隔） |
| \`SSH_PORT\` | \`22\` | 容器内 sshd 端口 |
| \`SSH_ENABLED\` | \`true\` | 设为 \`false\` 可只跑 DSH 不开 SSH |
| \`DSH_APP_ENABLED\` | \`true\` | 设为 \`false\` 可只开 SSH 不跑 DSH |
| \`GH_TOKEN\` | 空 | 可选，供容器内 \`gh\` 使用 |

完整说明见仓库 README。

> 提示：arm64 版本请下载对应 \`linux-arm64\` 文件；tag 以 \`-rc\` / \`-beta\` 结尾的版本会被标记为 pre-release。
EOF
