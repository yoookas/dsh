#!/bin/sh
# deepseek-harness-ssh 容器入口
#
# 职责：
#   1. 按环境变量配置 root 密码 / 公钥 / 端口，写运行时 sshd 配置；
#   2. 启动 sshd（作为容器的第 1 个子进程）；
#   3. 再 exec 上游镜像的默认入口（DSH Web 服务），保证信号、退出码语义不变。
#
# 兼容 Debian（dash）与 Alpine（busybox ash），只用 POSIX sh 语法。
set -eu

LOG_TAG='[ssh-entrypoint]'

log()  { printf '%s %s\n' "$LOG_TAG" "$*" >&2; }
warn() { printf '%s [警告] %s\n' "$LOG_TAG" "$*" >&2; }
die()  { printf '%s [错误] %s\n' "$LOG_TAG" "$*" >&2; exit 1; }

is_true() {
  case "${1:-}" in
    1|[Tt][Rr][Uu][Ee]|[Yy][Ee][Ss]|[Oo][Nn]) return 0 ;;
    *) return 1 ;;
  esac
}

is_false() {
  case "${1:-}" in
    0|[Ff][Aa][Ll][Ss][Ee]|[Nn][Oo]|[Oo][Ff][Ff]) return 0 ;;
    *) return 1 ;;
  esac
}

# ── 读取 root 密码：环境变量 → _FILE → Docker secret ───────────────────
read_root_password() {
  if [ -n "${SSH_ROOT_PASSWORD:-}" ]; then
    printf '%s' "$SSH_ROOT_PASSWORD"
    return 0
  fi
  if [ -n "${ROOT_PASSWORD:-}" ]; then
    warn 'ROOT_PASSWORD 是兼容别名，建议改用 SSH_ROOT_PASSWORD'
    printf '%s' "$ROOT_PASSWORD"
    return 0
  fi
  if [ -n "${SSH_ROOT_PASSWORD_FILE:-}" ]; then
    [ -r "$SSH_ROOT_PASSWORD_FILE" ] \
      || die "SSH_ROOT_PASSWORD_FILE 不可读：$SSH_ROOT_PASSWORD_FILE"
    cat "$SSH_ROOT_PASSWORD_FILE"
    return 0
  fi
  for secret in /run/secrets/ssh_root_password /run/secrets/SSH_ROOT_PASSWORD; do
    if [ -r "$secret" ]; then
      cat "$secret"
      return 0
    fi
  done
  return 1
}

# ── 收集公钥：内联多行 → _FILE → Docker secret ─────────────────────────
read_authorized_keys() {
  keys=''
  if [ -n "${SSH_AUTHORIZED_KEYS:-}" ]; then
    keys="$SSH_AUTHORIZED_KEYS"
  fi
  if [ -n "${SSH_AUTHORIZED_KEYS_FILE:-}" ]; then
    [ -r "$SSH_AUTHORIZED_KEYS_FILE" ] \
      || die "SSH_AUTHORIZED_KEYS_FILE 不可读：$SSH_AUTHORIZED_KEYS_FILE"
    keys="$keys
$(cat "$SSH_AUTHORIZED_KEYS_FILE")"
  fi
  if [ -r /run/secrets/authorized_keys ]; then
    keys="$keys
$(cat /run/secrets/authorized_keys)"
  fi
  printf '%s' "$keys"
}

# ── 等指定端口进入 LISTEN（用 node 做 TCP 探测，镜像里一定有 node）──────
wait_for_port() {
  port="$1"
  command -v node >/dev/null 2>&1 || return 0
  node -e '
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
}

# ── 生成运行期 sshd 配置 ───────────────────────────────────────────────
write_sshd_config() {
  conf=/etc/ssh/sshd_config.d/10-dsh-runtime.conf
  mkdir -p /etc/ssh/sshd_config.d
  rm -f "$conf"

  # sshd 不允许重复定义 Subsystem：主配置已有 sftp 就不要再写
  need_subsystem=1
  if [ -f /etc/ssh/sshd_config ] \
     && grep -qiE '^[[:space:]]*Subsystem[[:space:]]+sftp' /etc/ssh/sshd_config; then
    need_subsystem=0
  fi

  {
    printf '# 由 deepseek-harness-ssh 在容器启动时生成，请勿手工修改\n'
    printf 'Port %s\n' "$ssh_port"
    printf 'ListenAddress %s\n' "$ssh_listen_address"
    printf 'PermitRootLogin %s\n' "$permit_root_login"
    printf 'PasswordAuthentication %s\n' "$password_authentication"
    printf 'KbdInteractiveAuthentication no\n'
    printf 'PubkeyAuthentication yes\n'
    printf 'PermitEmptyPasswords no\n'
    printf 'UsePAM no\n'
    printf 'PrintMotd no\n'
    printf 'PrintLastLog yes\n'
    printf 'X11Forwarding yes\n'
    printf 'AllowAgentForwarding yes\n'
    printf 'AllowTcpForwarding yes\n'
    printf 'GatewayPorts no\n'
    printf 'ClientAliveInterval 60\n'
    printf 'ClientAliveCountMax 3\n'
    printf 'MaxStartups 100:30:200\n'
    if [ "$need_subsystem" = "1" ] && [ -s /etc/dsh-ssh-sftp-server ]; then
      printf 'Subsystem sftp %s\n' "$(cat /etc/dsh-ssh-sftp-server)"
    fi
  } > "$conf"
  chmod 0644 "$conf"
}

start_ssh() {
  ssh_port="${SSH_PORT:-22}"
  ssh_listen_address="${SSH_LISTEN_ADDRESS:-0.0.0.0}"

  case "$ssh_port" in
    ''|*[!0-9]*) die "SSH_PORT 必须是 1-65535 的整数，当前值：$ssh_port" ;;
  esac
  if [ "$ssh_port" -lt 1 ] || [ "$ssh_port" -gt 65535 ]; then
    die "SSH_PORT 超出范围：$ssh_port"
  fi

  command -v sshd >/dev/null 2>&1 || die '镜像内未找到 sshd，请检查构建是否成功'

  mkdir -p /run/sshd
  chmod 0755 /run/sshd 2>/dev/null || true

  # 主配置若缺少 Include，运行期补一次（防止用户挂载了自定义 sshd_config）
  if [ -f /etc/ssh/sshd_config ] \
     && ! grep -qE '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config\.d/' /etc/ssh/sshd_config; then
    printf 'Include /etc/ssh/sshd_config.d/*.conf\n' | cat - /etc/ssh/sshd_config > /tmp/sshd_config.new
    cat /tmp/sshd_config.new > /etc/ssh/sshd_config
    rm -f /tmp/sshd_config.new
  fi

  # ── 主机密钥：内置固定密钥 → 首启生成 ────────────────────────────────
  if [ -n "${SSH_HOST_KEY_B64:-}" ]; then
    if printf '%s' "$SSH_HOST_KEY_B64" | base64 -d > /etc/ssh/ssh_host_ed25519_key 2>/dev/null; then
      chmod 0600 /etc/ssh/ssh_host_ed25519_key
      ssh-keygen -y -f /etc/ssh/ssh_host_ed25519_key > /etc/ssh/ssh_host_ed25519_key.pub 2>/dev/null || true
      chmod 0644 /etc/ssh/ssh_host_ed25519_key.pub 2>/dev/null || true
      log '已使用 SSH_HOST_KEY_B64 提供的主机密钥'
    else
      warn 'SSH_HOST_KEY_B64 解码失败，回退为自动生成主机密钥'
      rm -f /etc/ssh/ssh_host_ed25519_key
    fi
  fi
  if [ ! -f /etc/ssh/ssh_host_ed25519_key ]; then
    log '生成 SSH 主机密钥 ...'
    ssh-keygen -A >/dev/null 2>&1 || die '生成 SSH 主机密钥失败'
  fi

  # ── root 密码 ────────────────────────────────────────────────────────
  root_password=''
  if root_password="$(read_root_password)"; then
    case "$root_password" in
      *'
'*) die 'SSH_ROOT_PASSWORD 不能包含换行符' ;;
    esac
    printf 'root:%s\n' "$root_password" | chpasswd || die '设置 root 密码失败'
    log "已设置 root 密码（长度 ${#root_password}）"
  else
    root_password=''
    warn '未提供 SSH_ROOT_PASSWORD / SSH_ROOT_PASSWORD_FILE，root 密码登录不可用'
  fi

  # ── 公钥 ─────────────────────────────────────────────────────────────
  authorized_keys="$(read_authorized_keys)"
  if [ -n "$(printf '%s' "$authorized_keys" | tr -d '[:space:]')" ]; then
    mkdir -p /root/.ssh
    chmod 0700 /root/.ssh
    printf '%s\n' "$authorized_keys" | sed '/^[[:space:]]*$/d' > /root/.ssh/authorized_keys
    chmod 0600 /root/.ssh/authorized_keys
    chown root:root /root/.ssh /root/.ssh/authorized_keys 2>/dev/null || true
    log "已写入 $(wc -l < /root/.ssh/authorized_keys) 条公钥到 /root/.ssh/authorized_keys"
  fi

  # ── 登录策略 ─────────────────────────────────────────────────────────
  permit_root_login="${SSH_PERMIT_ROOT_LOGIN:-yes}"

  password_authentication="${SSH_PASSWORD_AUTHENTICATION:-${SSH_PASSWORD_AUTH:-auto}}"
  if [ "$password_authentication" = 'auto' ]; then
    if [ -n "$root_password" ]; then
      password_authentication='yes'
    else
      password_authentication='no'
    fi
  fi

  if [ "$permit_root_login" = 'no' ]; then
    warn 'SSH_PERMIT_ROOT_LOGIN=no：root 无法通过 SSH 登录'
  fi

  write_sshd_config

  sshd -t || die 'sshd 配置校验失败，容器终止'

  log "OpenSSH 版本：$(ssh -V 2>&1 | head -n 1 || echo unknown)"
  log "启动 sshd：${ssh_listen_address}:${ssh_port}（PermitRootLogin=${permit_root_login}，PasswordAuthentication=${password_authentication}）"

  # 用 -D 前台方式启动再由 shell 放到后台，sshd 的日志能直接进容器日志，
  # 也便于检测「启动后立刻退出」；daemon 模式会把错误吞进 syslog。
  sshd -D -e &
  sshd_pid=$!
  sleep 1
  if ! kill -0 "$sshd_pid" 2>/dev/null; then
    wait "$sshd_pid" 2>/dev/null || true
    die 'sshd 启动后立即退出（日志见上）'
  fi
  log "sshd 已启动（pid ${sshd_pid}），等待端口就绪 ..."

  if ! wait_for_port "$ssh_port"; then
    kill "$sshd_pid" 2>/dev/null || true
    die "sshd 未能在 ${ssh_port} 端口监听，请检查端口冲突或上方 sshd 日志"
  fi
  log 'sshd 已就绪'
}

# ── 主流程 ─────────────────────────────────────────────────────────────
main() {
  if is_true "${SSH_ENABLED:-true}"; then
    start_ssh
  elif is_false "${SSH_ENABLED:-true}"; then
    log 'SSH_ENABLED=false，跳过 sshd，仅运行应用'
  else
    warn "SSH_ENABLED 取值无法识别（$SSH_ENABLED），按开启处理"
    start_ssh
  fi

  # 用户显式给了命令：直接执行（便于 docker run ... bash 进去排障）
  if [ "$#" -gt 0 ]; then
    log "执行用户命令：$*"
    exec "$@"
  fi

  if is_false "${DSH_APP_ENABLED:-true}"; then
    log 'DSH_APP_ENABLED=false：只跑 SSH，不启动 DSH 应用'
    exec sleep infinity
  fi

  [ -x /usr/local/bin/dsh-upstream-launch.sh ] \
    || die '缺少 /usr/local/bin/dsh-upstream-launch.sh，无法启动上游应用'

  log '启动上游应用 ...'
  exec /usr/local/bin/dsh-upstream-launch.sh
}

main "$@"
