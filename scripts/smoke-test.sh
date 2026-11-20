#!/usr/bin/env bash
# 构建后冒烟测试：
#   1. 镜像内 sshd 配置语法合法；
#   2. 用 SSH_ROOT_PASSWORD 注入的密码能登录，且登录用户是 root；
#   3. 错误密码必须被拒绝；
#   4. 应用进程仍在运行（容器不会因为起 sshd 而退出）。
#
# 用法：bash scripts/smoke-test.sh <image:tag>
set -euo pipefail

IMAGE="${1:?用法: smoke-test.sh <image:tag>}"
PASSWORD="${SMOKE_PASSWORD:-Smoke-Test-Pass-123}"
PORT=""   # 由下方决定（随机分配或 SMOKE_PORT）
CONTAINER="dsh-ssh-smoke-$$"

log()  { printf '[smoke] %s\n' "$*"; }
fail() { printf '[smoke][失败] %s\n' "$*" >&2; docker logs "$CONTAINER" 2>&1 | tail -n 40 >&2 || true; exit 1; }

cleanup() { docker rm -f "$CONTAINER" >/dev/null 2>&1 || true; }
trap cleanup EXIT

log "镜像：$IMAGE"

log '1/5 校验 sshd 配置'
# 镜像里不保留主机密钥（每个容器首启才生成），所以先造一把再 -t
docker run --rm --entrypoint sh "$IMAGE" -c 'ssh-keygen -A >/dev/null 2>&1 && sshd -t' \
  || fail 'sshd -t 校验失败'

log '2/5 校验镜像内置工具（gh / git / dsh / node）'
docker run --rm --entrypoint sh "$IMAGE" -c '
  set -e
  for bin in gh git node dsh ssh sshd ssh-keygen chpasswd; do
    command -v "$bin" >/dev/null 2>&1 || { echo "缺少命令：$bin"; exit 1; }
  done
  echo "gh      $(gh --version 2>/dev/null | head -n 1)"
  echo "git     $(git --version)"
  echo "node    $(node -v)"
  echo "dsh     $(dsh --version 2>/dev/null | head -n 1 || echo ok)"
' || fail '镜像内置工具检查失败'

log '3/5 启动容器'
if [ -n "${SMOKE_PORT:-}" ]; then
  docker run -d --name "$CONTAINER" \
    -e SSH_ROOT_PASSWORD="$PASSWORD" \
    -p "127.0.0.1:${SMOKE_PORT}:22" \
    "$IMAGE" >/dev/null || fail '容器启动失败'
  PORT="$SMOKE_PORT"
else
  # 不指定端口时让 Docker 随机分配，避免与 runner 上的服务冲突
  docker run -d --name "$CONTAINER" \
    -e SSH_ROOT_PASSWORD="$PASSWORD" \
    -p "127.0.0.1::22" \
    "$IMAGE" >/dev/null || fail '容器启动失败'
  PORT="$(docker port "$CONTAINER" 22/tcp | head -n 1 | sed 's/.*://')"
  [ -n "$PORT" ] || fail '无法获取容器映射的 SSH 端口'
fi
log "容器 SSH 端口：${PORT}"

log '等待 SSH 端口就绪 ...'
ready=0
for _ in $(seq 1 120); do
  if (exec 3<>"/dev/tcp/127.0.0.1/${PORT}") 2>/dev/null; then
    exec 3>&- 2>/dev/null || true
    ready=1
    break
  fi
  if [ "$(docker inspect -f '{{.State.Running}}' "$CONTAINER" 2>/dev/null)" != 'true' ]; then
    fail '容器已退出'
  fi
  sleep 1
done
[ "$ready" = '1' ] || fail "120 秒内 SSH 端口 ${PORT} 未就绪"

if ! command -v sshpass >/dev/null 2>&1; then
  log '未安装 sshpass，跳过登录断言（CI 中会安装）'
  exit 0
fi

SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
          -o ConnectTimeout=10 -o PreferredAuthentications=password
          -o PubkeyAuthentication=no -p "$PORT")

log '4/5 用环境变量里的密码登录'
set +e
OUTPUT="$(sshpass -p "$PASSWORD" ssh "${SSH_OPTS[@]}" root@127.0.0.1 'id -un; echo SMOKE_OK' 2>&1)"
RC=$?
set -e
printf '%s\n' "$OUTPUT"
[ "$RC" -eq 0 ] || fail "密码登录失败（ssh 退出码 $RC）"
grep -qx 'root' <<<"$OUTPUT" || fail '登录用户不是 root'
grep -q 'SMOKE_OK' <<<"$OUTPUT" || fail '远端命令未执行'

log '5/5 错误密码必须被拒绝'
set +e
sshpass -p 'definitely-wrong-password' ssh "${SSH_OPTS[@]}" root@127.0.0.1 'true' >/dev/null 2>&1
RC=$?
set -e
[ "$RC" -ne 0 ] || fail '错误密码竟然登录成功了'
log "错误密码按预期被拒绝（ssh 退出码 $RC）"

[ "$(docker inspect -f '{{.State.Running}}' "$CONTAINER")" = 'true' ] || fail '容器已退出'

log '全部通过 ✅'
