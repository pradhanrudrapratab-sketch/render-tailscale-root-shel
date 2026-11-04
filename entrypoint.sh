#!/usr/bin/env bash
# render-tailscale-root-shell :: entrypoint
# Order: validate env -> root password -> sshd -> tailscaled -> auth -> IPv4
#        -> tailscale serve -> health server -> banner -> monitor
set -Eeuo pipefail

# ----------------------------------------------------------------------------
# Config
# ----------------------------------------------------------------------------
SSH_ADDR="127.0.0.1"
SSH_PORT="2222"
SSHD_CONFIG="/etc/ssh/sshd_config_render"

TS_SOCKET="/var/run/tailscale/tailscaled.sock"
TS_STATE="/var/lib/tailscale/tailscaled.state"
TS_HOSTNAME="${TS_HOSTNAME:-render-root-shell}"

MONITOR_INTERVAL="${MONITOR_INTERVAL_SECONDS:-3600}"   # 60 min default
export PORT="${PORT:-10000}"

TS_IP=""
SELFTEST="not verified - test from another tailnet device"

# ----------------------------------------------------------------------------
# Logging helpers (never log secrets)
# ----------------------------------------------------------------------------
log()  { local lvl="$1"; shift; printf '[%s] [%-5s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$lvl" "$*"; }
info() { log INFO "$@"; }
warn() { log WARN "$@"; }
err()  { log ERROR "$@" >&2; }
die()  { err "$@"; exit 1; }

trap 'err "Unexpected failure (line $LINENO, exit $?)"' ERR
trap 'info "Shutdown signal received, stopping..."; kill $(jobs -p) 2>/dev/null || true; exit 0' TERM INT

redact() {  # hide the auth key if it ever shows up in tool output
  local s="$1"
  printf '%s' "${s//"${TS_AUTHKEY:-__none__}"/[REDACTED]}"
}

tsctl() { tailscale --socket="$TS_SOCKET" "$@"; }

port_open() { timeout 2 bash -c "exec 3<>/dev/tcp/$1/$2" >/dev/null 2>&1; }

# ----------------------------------------------------------------------------
# 1+2. Validate environment + password confirmation
# ----------------------------------------------------------------------------
validate_env() {
  local missing=0 v
  for v in TS_AUTHKEY ROOT_PASSWORD ROOT_PASSWORD_CONFIRM; do
    if [ -z "${!v:-}" ]; then
      err "Missing required environment variable: $v"
      missing=1
    fi
  done
  [ "$missing" -eq 0 ] || die "Set the missing variable(s) in Render -> Environment and redeploy."

  case "$TS_AUTHKEY" in
    tskey-*) ;;
    *) die "TS_AUTHKEY does not look like a Tailscale key (expected it to start with 'tskey-')." ;;
  esac

  [ "$ROOT_PASSWORD" = "$ROOT_PASSWORD_CONFIRM" ] \
    || die "ROOT_PASSWORD and ROOT_PASSWORD_CONFIRM do not match."

  [ "${#ROOT_PASSWORD}" -ge 12 ] \
    || die "ROOT_PASSWORD is too short. Use a strong, unique password (12+ characters)."

  case "$ROOT_PASSWORD" in
    *$'\n'*) die "ROOT_PASSWORD must not contain newlines." ;;
  esac

  [[ "$TS_HOSTNAME" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$ ]] \
    || die "TS_HOSTNAME '$TS_HOSTNAME' is invalid (letters, digits, hyphens only)."

  info "Environment OK (TS_AUTHKEY: set/masked, ROOT_PASSWORD: set/masked, hostname: $TS_HOSTNAME)"
}

# ----------------------------------------------------------------------------
# 3. Root password
# ----------------------------------------------------------------------------
configure_root_password() {
  printf 'root:%s\n' "$ROOT_PASSWORD" | chpasswd \
    || die "Failed to set the root password (chpasswd error)."
  # Keep the secrets out of the environment of every child process from here on.
  unset ROOT_PASSWORD ROOT_PASSWORD_CONFIRM
  info "Root password configured"
}

# ----------------------------------------------------------------------------
# 4. OpenSSH (listens on 127.0.0.1:2222 only; Tailscale Serve forwards to it)
# ----------------------------------------------------------------------------
start_sshd() {
  mkdir -p /run/sshd
  ssh-keygen -A >/dev/null 2>&1 || die "ssh-keygen -A failed"

  cat > "$SSHD_CONFIG" <<EOF
Port ${SSH_PORT}
ListenAddress ${SSH_ADDR}
HostKey /etc/ssh/ssh_host_ed25519_key
HostKey /etc/ssh/ssh_host_rsa_key
PermitRootLogin yes
PasswordAuthentication yes
PubkeyAuthentication yes
KbdInteractiveAuthentication no
PermitEmptyPasswords no
UsePAM no
MaxAuthTries 3
LoginGraceTime 30
ClientAliveInterval 60
ClientAliveCountMax 5
PrintMotd no
LogLevel INFO
AcceptEnv LANG LC_*
Subsystem sftp /usr/lib/openssh/sftp-server
EOF

  /usr/sbin/sshd -t -f "$SSHD_CONFIG" || die "sshd config test failed"

  # Preload the no-audit shim (see Dockerfile) so logins aren't blocked by missing CAP_AUDIT_WRITE.
  if [ -f /usr/local/lib/noaudit.so ]; then
    LD_PRELOAD=/usr/local/lib/noaudit.so /usr/sbin/sshd -D -e -f "$SSHD_CONFIG" &
  else
    warn "noaudit shim missing; logins may fail with 'linux_audit_write_entry failed'"
    /usr/sbin/sshd -D -e -f "$SSHD_CONFIG" &
  fi
  SSHD_PID=$!

  local i
  for i in $(seq 1 20); do
    if port_open "$SSH_ADDR" "$SSH_PORT"; then
      info "sshd listening on ${SSH_ADDR}:${SSH_PORT} (pid ${SSHD_PID})"
      return 0
    fi
    kill -0 "$SSHD_PID" 2>/dev/null || die "sshd exited during startup"
    sleep 0.5
  done
  die "sshd did not open ${SSH_ADDR}:${SSH_PORT} within 10s"
}

# ----------------------------------------------------------------------------
# 5. Tailscale daemon (userspace networking, no TUN, no systemd)
# ----------------------------------------------------------------------------
start_tailscaled() {
  if pgrep -x tailscaled >/dev/null 2>&1; then
    info "tailscaled already running, not starting a second one"
    return 0
  fi

  mkdir -p /var/lib/tailscale /var/run/tailscale
  rm -f "$TS_SOCKET"

  tailscaled \
    --tun=userspace-networking \
    --state="$TS_STATE" \
    --socket="$TS_SOCKET" &
  local pid=$!

  local i
  for i in $(seq 1 30); do
    [ -S "$TS_SOCKET" ] && break
    kill -0 "$pid" 2>/dev/null || die "tailscaled exited during startup"
    sleep 1
  done
  [ -S "$TS_SOCKET" ] || die "tailscaled socket did not appear within 30s"
  info "tailscaled started (pid ${pid}, userspace networking)"
}

# 6. Authenticate
ts_up() {
  local out
  info "Authenticating with Tailscale (hostname: ${TS_HOSTNAME})..."
  if ! out=$(timeout 90 tailscale --socket="$TS_SOCKET" up \
        --auth-key="$TS_AUTHKEY" \
        --hostname="$TS_HOSTNAME" \
        --accept-dns=false \
        --reset 2>&1); then
    err "tailscale up failed:"
    redact "$out" | sed 's/^/    /' >&2
    err "Hints: key expired/revoked? one-time key already used? use a reusable + ephemeral key."
    return 1
  fi
  return 0
}

# 7. IPv4
wait_for_ip() {
  local ip="" i
  for i in $(seq 1 30); do
    ip=$(tsctl ip -4 2>/dev/null | head -n1 || true)
    if [[ "$ip" =~ ^100\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
      printf '%s' "$ip"
      return 0
    fi
    sleep 1
  done
  return 1
}

ts_backend_state() {
  tsctl status --json 2>/dev/null \
    | python3 -c 'import sys,json; print(json.load(sys.stdin).get("BackendState",""))' 2>/dev/null || true
}

ts_self_hostname() {
  tsctl status --json 2>/dev/null \
    | python3 -c 'import sys,json; print((json.load(sys.stdin).get("Self") or {}).get("HostName",""))' 2>/dev/null || true
}

# ----------------------------------------------------------------------------
# 8. Tailscale Serve: tailnet tcp/22 -> 127.0.0.1:2222
# ----------------------------------------------------------------------------
serve_ok() {
  tsctl serve status 2>/dev/null | grep -Eq ":${SSH_PORT}([^0-9]|$)"
}

configure_serve() {
  if serve_ok; then
    info "Tailscale Serve already configured"
    return 0
  fi

  info "Configuring Tailscale Serve: tailnet tcp/22 -> ${SSH_ADDR}:${SSH_PORT}"
  local out
  if ! out=$(timeout 30 tailscale --socket="$TS_SOCKET" serve --bg --tcp=22 "tcp://${SSH_ADDR}:${SSH_PORT}" 2>&1); then
    warn "Current 'serve' syntax failed: ${out}"
    warn "Trying legacy syntax (Tailscale < 1.52)..."
    if ! out=$(timeout 30 tailscale --socket="$TS_SOCKET" serve tcp:22 "tcp://${SSH_ADDR}:${SSH_PORT}" 2>&1); then
      err "tailscale serve failed with both syntaxes: ${out}"
      err "If the output mentions enabling Serve, open that URL once and redeploy."
      return 1
    fi
  fi

  serve_ok || { err "serve command returned OK but 'tailscale serve status' does not show the forward"; return 1; }
  info "Tailscale Serve active"
}

# Best-effort inbound check. Self-dial in userspace mode is not guaranteed to work,
# so a miss means "unverified", never "failed" and never "success".
self_test() {
  local banner
  banner=$( { sleep 3; } | timeout 10 tailscale --socket="$TS_SOCKET" nc "$TS_IP" 22 2>/dev/null \
            | head -n1 | tr -d '\r' ) || true
  if [[ "$banner" == SSH-* ]]; then
    SELFTEST="PASSED - SSH banner received through tailnet IP"
    info "Self-test: ${SELFTEST} (${banner})"
  else
    SELFTEST="NOT VERIFIED - confirm with: ssh root@${TS_IP} from another tailnet device"
    warn "Self-test inconclusive (self-dial may be unsupported in userspace mode). Verify from your phone."
  fi
}

# ----------------------------------------------------------------------------
# 9-10. Health server + banner
# ----------------------------------------------------------------------------
start_health() {
  python3 /health.py &
  HEALTH_PID=$!
  sleep 1
  kill -0 "$HEALTH_PID" 2>/dev/null || die "health server failed to start on port ${PORT}"
  info "Health server listening on :${PORT} (GET / and /health)"
}

print_banner() {
  local name
  name="$(ts_self_hostname)"; name="${name:-$TS_HOSTNAME}"
  cat <<EOF

====================================
       TAILSCALE CONNECTED
====================================

Hostname: ${name}
Tailscale IPv4: ${TS_IP}

SSH Server: Running
Root Account: Configured
Tailscale Serve: tailnet tcp/22 -> ${SSH_ADDR}:${SSH_PORT}
Inbound self-test: ${SELFTEST}

Connect using:

ssh root@${TS_IP}

====================================

EOF
}

# ----------------------------------------------------------------------------
# 11. Monitor (every MONITOR_INTERVAL seconds)
# ----------------------------------------------------------------------------
monitor_once() {
  local state recovered=0
  info "monitor: checking sshd / tailscaled / serve"

  if ! port_open "$SSH_ADDR" "$SSH_PORT"; then
    warn "monitor: sshd not responding, restarting it"
    pkill -x sshd 2>/dev/null || true
    start_sshd
    recovered=1
  fi

  if ! pgrep -x tailscaled >/dev/null 2>&1; then
    warn "monitor: tailscaled is not running, starting it"
    start_tailscaled
    recovered=1
  fi

  state="$(ts_backend_state)"
  if [ "$state" != "Running" ]; then
    warn "monitor: Tailscale state is '${state:-unknown}', attempting reconnect"
    ts_up || { err "monitor: reconnect FAILED"; return 1; }
    recovered=1
  fi

  if ! serve_ok; then
    warn "monitor: Tailscale Serve missing, reconfiguring"
    configure_serve || { err "monitor: serve reconfiguration FAILED"; return 1; }
    recovered=1
  fi

  if [ "$recovered" -eq 1 ]; then
    info "monitor: RECOVERED (ip: $(tsctl ip -4 2>/dev/null | head -n1))"
  else
    info "monitor: healthy, nothing to do"
  fi
}

monitor_loop() {
  while true; do
    sleep "$MONITOR_INTERVAL"
    ( monitor_once ) || warn "monitor: cycle ended with errors, will retry next interval"
  done
}

# ----------------------------------------------------------------------------
# Main
# ----------------------------------------------------------------------------
main() {
  info "render-tailscale-root-shell starting"

  validate_env
  configure_root_password
  start_sshd
  start_tailscaled
  ts_up || die "Tailscale authentication failed - see errors above."

  TS_IP="$(wait_for_ip)" || die "Authenticated, but no Tailscale IPv4 was assigned within 30s."
  info "Tailscale IPv4: ${TS_IP}"

  configure_serve || die "Could not set up Tailscale Serve - SSH would NOT be reachable. See errors above."

  start_health
  self_test
  print_banner

  monitor_loop &
  MONITOR_PID=$!

  local code=0
  wait -n "$HEALTH_PID" "$MONITOR_PID" || code=$?
  die "A core process exited unexpectedly (code ${code}); exiting so Render restarts the service."
}

main "$@"
