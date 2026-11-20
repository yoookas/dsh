#!/usr/bin/env bash
# 构建后冒烟测试：
#   1. 镜像内 sshd 配置语法合法；
#   2. 内置工具齐全（gh / git / dsh / node / sshd / chpasswd）；
#   3. 只开 SSH 的容器（DSH_APP_ENABLED=false）：
#      用 SSH_ROOT_PASSWORD 注入的密码能登录、登录用户是 root、错误密码被拒；
#   4. 默认容器（SSH + DSH）能起来并保持运行（DSH 依赖外部配置，失败只警告不阻断）。
#
# 用法：bash scripts/smoke-test.sh <image:tag>   [SMOKE_PORT=2222 可指定端口]
set -euo pipefail

IMAGE="${1:?用法: smoke-test.sh <image:tag>}"
PASSWORD="${SMOKE_PASSWORD:-Smoke-Test-Pass-123}"
CONTAINER="dsh-ssh-smoke-$$"
PORT=""
FAILED=0

log()  { printf '[smoke] %s\n' "$*"; }
warn() { printf '[smoke][警告] %s\n' "$*" >&2; }

dump_container() {
  [ -n "${CONTAINER:-}" ] || return 0
  echo '----- docker inspect -----' >&2
  docker inspect -f 'status={{.State.Status}} exit={{.State.ExitCode}}' "$CONTAINER" >&2 2>&1 || true
  echo '----- docker logs (tail 80) -----' >&2
  docker logs --tail 80 "$CONTAINER" >&2 2>&1 || true
}

cleanup() {
  if [ "$FAILED" = '1' ]; then
    dump_container
  fi
  docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
}
trap cleanup EXIT

fail() {
  FAILED=1
  printf '[smoke][失败] %s\n' "$*" >&2
  exit 1
}

log "镜像：$IMAGE"

log '1/4 校验 sshd 配置'
# 镜像里不保留主机密钥（每个容器首启才生成），所以先造一把再 -t
docker run --rm --entrypoint sh "$IMAGE" -c 'ssh-keygen -A >/dev/null 2>&1 && sshd -t' \
  || fail 'sshd -t 校验失败'

log '2/4 校验镜像内置工具'
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

start_container() { # $@ = 额外 docker run 参数
  if [ -n "${SMOKE_PORT:-}" ]; then
    docker run -d --name "$CONTAINER" \
      -e SSH_ROOT_PASSWORD="$PASSWORD" \
      -p "127.0.0.1:${SMOKE_PORT}:22" "$@" "$IMAGE" >/dev/null || fail '容器启动失败'
    PORT="$SMOKE_PORT"
  else
    docker run -d --name "$CONTAINER" \
      -e SSH_ROOT_PASSWORD="$PASSWORD" \
      -p "127.0.0.1::22" "$@" "$IMAGE" >/dev/null || fail '容器启动失败'
    PORT="$(docker port "$CONTAINER" 22/tcp | head -n 1 | sed 's/.*://')"
    [ -n "$PORT" ] || fail '无法获取容器映射的 SSH 端口'
  fi
  log "容器 SSH 端口：${PORT}"
}

container_running() {
  [ "$(docker inspect -f '{{.State.Running}}' "$CONTAINER" 2>/dev/null)" = 'true' ]
}

wait_port() { # 最多 90 秒
  local i
  for i in $(seq 1 90); do
    if (exec 3<>"/dev/tcp/127.0.0.1/${PORT}") 2>/dev/null; then
      exec 3>&- 2>/dev/null || true
      return 0
    fi
    if ! container_running; then
      return 1
    fi
    sleep 1
  done
  return 1
}

SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
          -o ConnectTimeout=10 -o PreferredAuthentications=password
          -o PubkeyAuthentication=no -p "$PORT")

try_login() { # 返回 0 表示登录成功
  local i out rc
  for i in $(seq 1 10); do
    set +e
    out="$(sshpass -p "$PASSWORD" ssh "${SSH_OPTS[@]}" root@127.0.0.1 'id -un; echo SMOKE_OK' 2>&1)"
    rc=$?
    set -e
    if [ "$rc" -eq 0 ]; then
      printf '%s\n' "$out"
      return 0
    fi
    printf '[smoke]   第 %d 次登录失败（rc=%d）：%s\n' "$i" "$rc" "$(printf '%s' "$out" | tail -n 2 | tr '\n' ' ')" >&2
    sleep 2
  done
  return 1
}

log '3/4 SSH 容器：密码登录 / root 身份 / 错误密码'
start_container -e DSH_APP_ENABLED=false

log '等待 SSH 端口就绪 ...'
wait_port || fail "SSH 端口 ${PORT} 未在 90 秒内就绪或容器已退出"

if ! command -v sshpass >/dev/null 2>&1; then
  warn '未安装 sshpass，跳过登录断言（CI 中会安装）'
else
  OUTPUT="$(try_login)" || fail '密码登录失败'

  grep -qx 'root' <<<"$OUTPUT" || fail '登录用户不是 root'
  grep -q 'SMOKE_OK' <<<"$OUTPUT" || fail '远端命令未执行'
  log '密码登录成功，身份为 root'

  set +e
  sshpass -p 'definitely-wrong-password' ssh "${SSH_OPTS[@]}" root@127.0.0.1 'true' >/dev/null 2>&1
  RC=$?
  set -e
  [ "$RC" -ne 0 ] || fail '错误密码竟然登录成功了'
  log "错误密码按预期被拒绝（ssh 退出码 $RC）"
fi

container_running || fail 'SSH 容器已退出'

docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
CONTAINER=""

log '4/4 默认容器：SSH + DSH 能同时起来'
start_container
sleep 8
if container_running; then
  log '默认容器运行正常（SSH + DSH）'
else
  warn '默认容器 8 秒内退出（DSH 依赖外部配置，非致命）：'
  docker logs --tail 40 "$CONTAINER" >&2 2>&1 || true
fi
docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
CONTAINER=""

log '全部通过 ✅'
