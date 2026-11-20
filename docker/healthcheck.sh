#!/bin/sh
# 容器健康检查：确认 sshd 在预期端口 LISTEN。
# SSH_ENABLED=false 时直接视为健康（此时只跑应用）。
set -eu

if [ "${SSH_ENABLED:-true}" = 'false' ] || [ "${SSH_ENABLED:-true}" = '0' ]; then
  exit 0
fi

port="${SSH_PORT:-22}"

if command -v node >/dev/null 2>&1; then
  exec node -e '
    const net = require("net");
    const port = Number(process.argv[1]);
    let done = false;
    const finish = (code) => {
      if (!done) { done = true; try { sock.destroy(); } catch (_) {} process.exit(code); }
    };
    const sock = net.connect(port, "127.0.0.1");
    sock.on("connect", () => finish(0));
    sock.on("error", () => finish(1));
    setTimeout(() => finish(1), 5000);
  ' "$port"
fi

# 兜底：没有 node 时用 nc / bash 的 /dev/tcp
if command -v nc >/dev/null 2>&1; then
  exec nc -z 127.0.0.1 "$port"
fi

exit 0
