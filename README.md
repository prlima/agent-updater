# agent-updater (github-agent)

Self-hosted webhook agent that runs a deploy script on your server when a GitHub Actions workflow completes. Single static binary, zero runtime dependencies.

## How it works

```
GitHub workflow completes
        ↓
  POST /webhook  (HMAC-SHA256 verified)
        ↓
  sudo -n -u <deploy_user> /path/to/update.sh
        ↓
  Deploy done
```

## Install

One command, on the server, as root:

```bash
curl -fsSL https://raw.githubusercontent.com/prlima/agent-updater/main/install.sh | sudo bash
```

It fetches the latest GitHub release, verifies the SHA256 checksum, installs the binary, creates a dedicated `github-agent` system user, sets up the systemd service, and runs a configuration wizard asking for:

- Listening port and webhook path
- Webhook secret (generated automatically or entered manually)
- One or more projects: GitHub repo, branch, deploy path, OS user, script name

## Manage / upgrade

Running the exact same command again detects the existing install and opens a menu instead of the wizard:

```
  github-agent installer
  repo: github.com/prlima/agent-updater

  Status: active   Version: vx.x.x

  What do you want to do?

   1) View current config
   2) Edit config (opens editor)
   3) View webhook secret
   4) Add project
   5) Restart service
   6) View logs (last 50 lines)
   7) Update binary
   8) Reconfigure everything
   9) Uninstall
   0) Exit
```

`7` re-downloads and verifies the latest release binary without touching config. `8` re-runs the full wizard.

## Configuration

`/etc/github-agent/config.yaml` (mode `0640`):

```yaml
server:
  addr: "127.0.0.1:9000"

webhook:
  path: "/webhook"
  secret: "${GITHUB_WEBHOOK_SECRET}"

repos:
  - name: "myorg/myrepo"
    branch: "main"
    workflow: "deploy.yml"        # leave empty to match any workflow
    deploy_path: "/home/deploy/projects/myapp"
    deploy_user: "deploy"
    deploy_script: "update.sh"    # runs as: sudo -n -u deploy /home/deploy/projects/myapp/update.sh
```

The secret is never stored in the config file — it lives in `/etc/github-agent/env` (mode `0600`) and is injected via `${GITHUB_WEBHOOK_SECRET}`.

## GitHub webhook setup

Repo → Settings → Webhooks → Add webhook:

| Field | Value |
|---|---|
| Payload URL | `https://your-server.com/webhook` |
| Content type | `application/json` |
| Secret | value from install wizard |
| Events | `Workflow runs` only |

## Reverse proxy (nginx)

The agent only binds `127.0.0.1:9000`. Expose it via nginx:

```nginx
location /webhook {
    proxy_pass http://127.0.0.1:9000;
    proxy_set_header Host              $host;
    proxy_set_header X-Real-IP         $remote_addr;
    proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;
}
```

If using Cloudflare, add a WAF rule to bypass security checks for GitHub's IP ranges on the `/webhook` path.

## Logs

Structured JSON. Summary line at the end of each deploy:

```json
{"level":"INFO","msg":"deploy summary","repo":"myorg/myrepo","branch":"main","workflow":"deploy.yml","status":"success","duration":"6.755s"}
{"level":"ERROR","msg":"deploy summary","repo":"myorg/myrepo","status":"failed","duration":"1.2s","err":"script exit: ..."}
```

```bash
# Follow live
sudo tail -f /var/log/github-agent/agent.log

# Via journald
sudo journalctl -u github-agent -f
```

## Test a webhook manually

```bash
SECRET="your-webhook-secret"
PAYLOAD='{"action":"completed","workflow_run":{"name":"deploy.yml","head_branch":"main","conclusion":"success","status":"completed"},"repository":{"full_name":"myorg/myrepo"}}'
SIG="sha256=$(echo -n "$PAYLOAD" | openssl dgst -sha256 -hmac "$SECRET" | awk '{print $2}')"

curl -s -X POST http://127.0.0.1:9000/webhook \
  -H "Content-Type: application/json" \
  -H "X-GitHub-Event: workflow_run" \
  -H "X-Hub-Signature-256: $SIG" \
  -d "$PAYLOAD"
```

## Releases

`.github/workflows/release.yml` builds and publishes automatically — no manual tagging needed:

- **Push to `main`** → bumps the patch version (`vX.Y.Z` → `vX.Y.Z+1`), builds `linux/amd64` + `linux/arm64` (`CGO_ENABLED=0`), generates `checksums.txt`, and publishes a GitHub Release with the binaries attached.
- **Push a tag manually** (`git tag vX.Y.Z && git push --tags`) → skips the auto-bump and releases exactly that version, e.g. for a hotfix on an older line.

`install.sh` always installs from `releases/latest`.

## Local build

```bash
./build.sh native        # current OS/arch -> dist/github-agent
./build.sh linux         # linux/amd64
./build.sh linux-arm64    # linux/arm64
./build.sh all            # every target
```

`dist/` is gitignored — build artifacts are never committed; they come from the release workflow.

## Security model

| Layer | Mechanism |
|---|---|
| Transport | Reverse proxy handles TLS — agent binds `127.0.0.1` only |
| Auth | HMAC-SHA256 (`X-Hub-Signature-256`) verified before any payload processing |
| Timing attack | `crypto/hmac.Equal` constant-time comparison |
| Secret storage | Env var only — never in config file, never logged |
| Privilege | Agent runs as dedicated unprivileged `github-agent` user; `sudo` restricted to exact script path per project |
| Injection | `exec.Command` with explicit arg list — no shell involved |
| Concurrency | Per-repo mutex prevents overlapping deploys |
| Timeouts | 15 min deploy timeout + HTTP read/write timeouts |
| Rate limiting | 5-req burst, 1 req/s recovery |
| Payload size | 10 MiB body limit |
| Filesystem | systemd `ProtectSystem=strict`, `PrivateTmp` |
