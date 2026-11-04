# Render Tailscale Root Shell

Experimental: a Render Web Service (Docker/Debian) that joins your Tailscale network and exposes a root SSH shell to **your tailnet only**. No public SSH port.

> ⚠️ Private experiment. Root + password SSH is **not** a production setup. Not a VPS replacement.

## How it works

```
Termux (Tailscale app ON)
   │  ssh root@100.x.x.x   (tailnet tcp/22)
   ▼
tailscaled (userspace networking, inside container)
   │  Tailscale Serve: tcp/22 → 127.0.0.1:2222
   ▼
OpenSSH (127.0.0.1:2222)  →  root shell
```

Plus `health.py` on `$PORT` returning `online` for Render / UptimeRobot.

## Setup

### 1. Tailscale auth key
Tailscale admin → Settings → Keys → **Generate auth key**:

| Option | Recommended |
|---|---|
| Reusable | ✅ yes (container restarts re-authenticate) |
| Ephemeral | ✅ yes (stale devices auto-remove) |
| Expiry | short (e.g. 7 days) |
| Tags | optional, e.g. `tag:render` (then restrict with ACLs) |

Revoke the key when you're done testing.

### 2. Deploy on Render
1. Push this folder to a **private** GitHub repo.
2. Render → New → Blueprint (uses `render.yaml`) or New → Web Service → Docker.
3. Set environment variables:

| Variable | Value |
|---|---|
| `TS_AUTHKEY` | `tskey-auth-...` |
| `ROOT_PASSWORD` | strong, unique, 12+ chars |
| `ROOT_PASSWORD_CONFIRM` | same as above |
| `TS_HOSTNAME` | optional (default `render-root-shell`) |
| `MONITOR_INTERVAL_SECONDS` | optional (default `3600`) |

### 3. Read the logs
After deploy, look for:

```
====================================
       TAILSCALE CONNECTED
====================================
Hostname: render-root-shell
Tailscale IPv4: 100.x.x.x
...
ssh root@100.x.x.x
```

### 4. Connect from Android
Install the Tailscale app, log into the **same tailnet**, turn it ON. In Termux:

```bash
pkg install openssh
ssh -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null root@100.x.x.x
```

(Host keys are created when the image is built, so they change whenever the image is rebuilt. If you see a "host key changed" warning after a redeploy, run `ssh-keygen -R 100.x.x.x` or use the flags above.)

### Login closes right after the password: `linux_audit_write_entry failed`
Render containers lack `CAP_AUDIT_WRITE`. The Dockerfile builds a tiny `LD_PRELOAD` shim (`noaudit.so`) and `entrypoint.sh` starts sshd with it, so audit is skipped instead of blocking the login. If you still see this error, check the logs for `noaudit shim missing`.

### First attempt says `Software caused connection abort`
Usually a one-off while the tailnet path is being established. Retry once or twice.

## Restrict access with ACLs (recommended)

Tag the key `tag:render` and add something like this to your tailnet policy (merge with your existing rules):

```json
{
  "tagOwners": { "tag:render": ["autogroup:admin"] },
  "grants": [
    { "src": ["autogroup:member"], "dst": ["tag:render"], "ip": ["tcp:22"] }
  ]
}
```

## Startup order

validate env → check password confirmation → set root password → start sshd → start tailscaled → `tailscale up` → get IPv4 → `tailscale serve` → health server → print banner → monitor.

Any critical failure prints a clear `[ERROR]` line and exits non-zero (Render restarts the service). Nothing is silently ignored.

## Monitoring / recovery

Every `MONITOR_INTERVAL_SECONDS` (default 60 min) the monitor checks:

1. sshd is answering on 127.0.0.1:2222 (restarts it if not)
2. `tailscaled` is alive (starts one **only if none exists**, never duplicates)
3. Tailscale `BackendState == Running` (otherwise reconnects)
4. Tailscale Serve forward exists (otherwise reconfigures)

A healthy connection is left alone. Results are logged.

## Health endpoint

`GET /` and `GET /health` → `200 online`. This only proves the web process is up; it does **not** prove SSH or Tailscale works.

Point UptimeRobot at `https://<your-service>.onrender.com/health`.

## Verifying it really works

The banner includes an **Inbound self-test** line:

- `PASSED` → SSH banner was received through the tailnet IP.
- `NOT VERIFIED` → self-dial isn't guaranteed in userspace mode. This is *not* a failure and *not* a success. **The real test is `ssh root@100.x.x.x` from another device on your tailnet.**

Acceptance checklist:

| Test | How to check |
|---|---|
| Missing key / password | Deploy without them → clear `[ERROR]` |
| Password mismatch | Make confirm differ → startup fails |
| Device in tailnet | Tailscale admin → Machines |
| IPv4 in logs | Banner |
| Serve works | `ssh root@100.x.x.x` from Termux |
| Health | `curl -i https://<service>.onrender.com/health` → 200 |
| Recovery | Set `MONITOR_INTERVAL_SECONDS=120`, then in the shell run `tailscale down` and watch the logs |

## Known limitations (Render)

- **Free tier sleeps** after ~15 min without inbound HTTP. UptimeRobot pings keep it awake, but free instance hours are still capped and Render can restart/redeploy at any time.
- **Ephemeral filesystem**: anything you install or save as root disappears on restart/redeploy. Tailscale state is also lost, so each restart re-authenticates with the auth key (hence reusable + ephemeral).
- **No TUN, no systemd**: Tailscale runs in userspace mode. Only inbound TCP forwarded by Serve works (SSH). Outbound tailnet access from inside the shell needs `tailscale nc` or a SOCKS5 proxy.
- If `tailscale serve` asks you to enable Serve for your tailnet, open the URL it prints once, then redeploy.
- Check Render's terms/acceptable-use policy before using this long term.

## Security checklist

- [ ] Secrets only in Render env vars, never in Git
- [ ] Strong, unique `ROOT_PASSWORD`
- [ ] Tailscale ACL limits who can reach tcp/22
- [ ] Auth key short-lived, revoked after testing
- [ ] Repo is private
