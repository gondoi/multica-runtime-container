## Running in Kubernetes

Usage walkthrough for the example manifests in
[`examples/k8s/`](../examples/k8s/). They implement the same Secret-projection
contract as the local Compose setup — see the [root README](../README.md) for
the full boot contract and GitHub auth tier precedence.

### What's here

| Manifest | Role |
| --- | --- |
| [`namespace.yaml`](../examples/k8s/namespace.yaml) | `multica-runtime` namespace (deploy-time name — replace it) |
| [`serviceaccount.yaml`](../examples/k8s/serviceaccount.yaml) | ServiceAccount for the pod — IRSA annotation point for AWS creds |
| [`secret.example.yaml`](../examples/k8s/secret.example.yaml) | Placeholder Secrets: Multica home, Cursor key, git auth (Claude Code + Codex + AWS optional) |
| [`pvc.yaml`](../examples/k8s/pvc.yaml) | `multica-runtime-workspaces` PVC — the only durable volume |
| [`deployment.yaml`](../examples/k8s/deployment.yaml) | Single-replica Deployment wiring the Secrets + PVC together |

There is **no** Multica-home PVC — identity (`config.json`, `daemon.id`) is
Secret-projected only. There is **no** Ingress — the runtime has nothing to
serve inbound.

### Apply

These are illustrative placeholders, not production manifests — production
should use GitOps + SOPS (or your cluster's secret manager) instead of
`secret.example.yaml`'s plaintext `stringData`.

```bash
kubectl apply -f examples/k8s/namespace.yaml
kubectl apply -f examples/k8s/serviceaccount.yaml
kubectl apply -f examples/k8s/secret.example.yaml   # replace placeholder values first
kubectl apply -f examples/k8s/pvc.yaml
kubectl apply -f examples/k8s/deployment.yaml
```

Replace the image tag in `deployment.yaml` (`ghcr.io/gondoi/multica-runtime:vX.Y.Z`)
with a published release tag — see the CI publish table in the README for the
tag shapes (`vX.Y.Z` or `X.Y.Z`), e.g. `v0.1.0`.

Name the deployment by its scope so Multica's runtime list is readable —
uncomment `MULTICA_MACHINE_NAME` in `deployment.yaml` (or set it in your GitOps
overlay); the row shows `Cursor (fuel-general)` / `Claude (fuel-general)` instead of
`Cursor (multica-runtime-6cc749d9f7-dr2gh)`. Full custom names (no provider
prefix) are a one-time `multica runtime rename <id> <name> --machine` and are
kept per runtime, so they survive pod recreates. Details:
[Machine name](../README.md#machine-name-multica_machine_name).

### Verify

```bash
kubectl -n multica-runtime get pods
kubectl -n multica-runtime logs deploy/multica-runtime -f
```

The Deployment wires `startupProbe` / `livenessProbe` / `readinessProbe` to
the same `/usr/local/bin/ready.sh` used by the Compose healthcheck — pods go
Ready once the daemon is up past the hard gates (required binaries + secrets).
`ready.sh` gates on the daemon's reported `status` (`running` / `starting`), not
on the `daemon status` exit code — that exit code is `0` even when no daemon is
running, so checking it alone reports Ready forever.
The **first** task run against the pod may cold-clone its repo; that is
expected and is not part of the Ready gate.

### Agent CLI harnesses (Cursor / Claude Code / OpenAI Codex)

`MULTICA_AGENT_CLI` in `deployment.yaml` (default `cursor`) names the harnesses
the pod provisions and hard-gates: `cursor`, `claude`, `codex`, or any comma
combination. The harness used for a specific run is chosen on the Multica agent
definition; this only guarantees the CLI is present and authenticated in the
pod.

Harnesses it does **not** name are masked from the PATH the daemon and its tasks
inherit (all three CLIs ship in the image). A selected harness is never masked,
and the mask is a boot-time PATH rewrite — no image change, so updating the
`MULTICA_AGENT_CLI` env value and restarting the pod is enough. `kubectl exec`
shells start from the image env, so check the mask through the daemon:

```bash
kubectl -n multica-runtime exec deploy/multica-runtime -- bash -c \
  'p=$(pgrep -f "multica daemon" | head -1); d=$(tr "\0" "\n" </proc/$p/environ | sed -n "s/^PATH=//p"); for b in claude codex; do PATH=$d command -v $b || echo "$b masked"; done'
```

The `claude` Secret + volume are shipped **commented out** in `deployment.yaml`
because a mounted-but-absent Secret (or a missing key in its `items` list) fails
the pod mount. To run Claude Code:

1. Add the `claude` Secret to your overlay from the commented block in
   `secret.example.yaml` (`multica-runtime-claude`, one key only:
   `ANTHROPIC_API_KEY` **or** `CLAUDE_CODE_OAUTH_TOKEN` **or**
   `ANTHROPIC_AUTH_TOKEN`).
2. Uncomment the matching `*_FILE` env var, the `claude` `volumeMount`, and the
   `claude` volume in `deployment.yaml`.
3. Set `MULTICA_AGENT_CLI` to `claude` (or `cursor,claude`).

⚠️ Higher-risk, same as the GitHub/AWS tiers: that credential is inherited by
every agent task the pod runs. Prefer the OAuth-token tier over a long-lived org
API key and scope the credential to this runtime. Detail:
[README → Agent CLI harnesses](../README.md#agent-cli-harnesses-multica_agent_cli).

Verify from inside the pod once Ready:

```bash
kubectl -n multica-runtime exec deploy/multica-runtime -- claude --version
kubectl -n multica-runtime logs deploy/multica-runtime | grep 'harness claude'
```

#### OpenAI Codex

Same pattern, with one extra step: codex ignores `OPENAI_API_KEY` in the
environment and reads `$CODEX_HOME/auth.json`, so the pod projects the key into
that file at boot (`codex login --with-api-key`, mode 0600). A mounted
`auth.json` from `codex login` (ChatGPT OAuth or API key) is projected instead
and left untouched.

1. Add the `codex` Secret from the commented block in `secret.example.yaml`
   (`multica-runtime-codex`, one key only: `OPENAI_API_KEY` **or** `auth.json`).
2. Uncomment the matching env var (`OPENAI_API_KEY_FILE` or
   `CODEX_AUTH_JSON_FILE`), the `codex` `volumeMount`, and the `codex` volume in
   `deployment.yaml`.
3. Set `MULTICA_AGENT_CLI` to `codex` (or a combination).
4. Codex runs task commands through `bubblewrap`, which needs unprivileged user
   namespaces. If your runtime's default seccomp/AppArmor profile blocks them,
   uncomment the `seccompProfile` / `appArmorProfile` block in the pod
   `securityContext` — **verify first**, this is not confirmed on every
   CNI/runtime:

   ```bash
   kubectl -n multica-runtime exec deploy/multica-runtime -- \
     codex sandbox -- /bin/echo sandbox-ok    # needs no credential
   ```

   A blocked sandbox shows `bwrap: No permissions to create new namespace` or
   `bwrap: Failed to make / slave` at **task** time, never at boot.

Verify codex from inside the pod:

```bash
kubectl -n multica-runtime exec deploy/multica-runtime -- codex --version
kubectl -n multica-runtime exec deploy/multica-runtime -- codex login status
kubectl -n multica-runtime logs deploy/multica-runtime | grep 'harness codex'
```

### Switching GitHub auth tiers

`secret.example.yaml` defaults to the PAT tier (`GITHUB_TOKEN`). To switch to
the GitHub App tier (recommended for orgs that disallow PATs) or the GitHub
Enterprise Server password tier, you must update **both** files so their keys
match — a mismatch fails the Secret volume mount:

1. In `secret.example.yaml`, comment out `GITHUB_TOKEN` and uncomment the
   `GITHUB_APP_*` (or `GITHUB_HOST`/`GITHUB_USER`/`GITHUB_PASSWORD`) keys.
2. In `deployment.yaml`, update the `git` Secret volume's `items` list to the
   same key set, and uncomment the matching `*_FILE` env vars on the
   container.

See [GitHub auth precedence](../README.md#github-auth-precedence-app--pat--password)
in the README for how the three tiers resolve.

### AWS credentials (IRSA > instance role > aws-sso ConfigMaps > static mount)

The image installs AWS CLI v2 + upstream `aws-sso` but bakes **no** credentials.
Prefer the SDK default chain first; ConfigMap profiles cover homelab without IRSA:

| Tier | Setup | Pod spec change | Static keys |
| --- | --- | --- | --- |
| 1 · IRSA (EKS, preferred) | IAM role whose trust policy federates the cluster's OIDC provider to `system:serviceaccount:multica-runtime:multica-runtime`; EKS then projects `AWS_WEB_IDENTITY_TOKEN_FILE` + `AWS_ROLE_ARN` automatically | uncomment `eks.amazonaws.com/role-arn` in `serviceaccount.yaml` | No |
| 2 · Instance / ECS task role | Node instance profile (EC2) or task role (ECS) — the SDK calls IMDS/container endpoint on its own | none | No |
| 3a · aws-sso ConfigMaps | Curated `~/.aws/config` + aws-sso YAML; SSO cache on workspaces PVC. Needs the [`multica-runtime-aws-sso-unlock`](#aws-sso-securestore-passphrase) Secret for non-TTY `credential_process` | `aws-configmap.yaml` + Deployment mounts (already in examples) | No (passphrase Secret only) |
| 3b · Mounted static config | Secret with `config` / `credentials`, pointed at by `AWS_CONFIG_FILE` / `AWS_SHARED_CREDENTIALS_FILE` | uncomment the AWS env vars, `volumeMounts.aws`, and `volumes.aws` in `deployment.yaml`, plus the optional Secret in `secret.example.yaml` | Yes — avoid when tiers 1–3a exist |

Grant the role only what agent tasks actually need (`sts:GetCallerIdentity`,
plus the specific read actions for the discovery work you intend); every task
running in the pod inherits the identity. Verify from inside a pod:

```bash
kubectl -n multica-runtime exec deploy/multica-runtime -- aws sts get-caller-identity
kubectl -n multica-runtime logs deploy/multica-runtime | grep 'aws auth:'
```

The boot log line names the tier the chain resolved (informational, never a
boot gate, never a credential value).

For ConfigMap / aws-sso profiles, login is **operator-exec only**:

```bash
kubectl -n multica-runtime exec -it deploy/multica-runtime -- \
  env AWS_SSO_OPERATOR_LOGIN=1 aws-sso login --url-action=print
```

#### Login workflow must stay pinned to `device_code`

`aws-configmap.yaml` pins `AuthWorkflow: device_code`. aws-sso >= 2.2.0 defaults
to `pkce`, which opens the authorization URL in a browser and waits for it to
redirect to a temporary listener on `127.0.0.1:<port>` **inside the pod**. The
operator's browser is outside the cluster, so its redirect to `127.0.0.1` goes to
the operator's own machine, never to the pod: login hangs and no session is
cached. `device_code` prints a URL plus a user code that the operator approves in
their own browser, and `aws-sso` polls for the token — no inbound reachability.

Symptom of a missing pin: the printed URL contains
`redirect_uri=http%3A%2F%2F127.0.0.1%3A<port>` and the command never returns.
Valid upstream values are `device_code` and `pkce` (there is no
`authorization_code`). Keep the pin when you bump `AWS_SSO_VERSION`: before 2.4.0
the `device_code` workflow also got no refresh token, so a session died after 8
hours (fixed in 2.4.0).

#### aws-sso SecureStore passphrase

aws-sso's encrypted `file` store prompts for a passphrase on every process that
opens it. Agent tasks run without a TTY, so the profile's `credential_process`
(`aws-sso process`) can only unlock it from `AWS_SSO_FILE_PASSWORD` — otherwise
every agent AWS call fails with `Enter passphrase to unlock "…/secure"` then
``FATAL Must run `aws-sso login` `` even after a successful operator login.

1. Create the `multica-runtime-aws-sso-unlock` Secret (see
   `secret.example.yaml`) with key `AWS_SSO_FILE_PASSWORD`.
2. Uncomment the `AWS_SSO_FILE_PASSWORD_FILE` env var and the
   `aws-sso-unlock` volume + mount in `deployment.yaml`.
3. Roll the pod, then run the operator login with that Secret in place: a fresh
   store is created with this passphrase, no prompt. An existing store created
   from an operator-typed passphrase keeps failing closed — set the Secret to
   that passphrase or delete `<workspaces>/.provider-homes/aws-sso/secure/` on
   the PVC and re-login.

`AWS_SSO_FILE_PASSWORD` unset is not a boot failure: boot only reports it in the
`aws auth:` line. Same risk note as the harness keys — every task inherits the
passphrase and can read it from its own env; it protects the PVC cache at rest
and is not an AWS credential.

### Egress control (not provided yet)

`MULTICA_EGRESS_PROXY` / `MULTICA_EGRESS_PROXY_CA` work identically in a pod —
set them plus a read-only mount of the proxy's `ca.crt` — but **no Kubernetes
manifest for an egress proxy ships here yet.** The two cluster-side decisions
that make or break it (the address iron-proxy answers DNS queries with, and the
`dnsConfig` + NetworkPolicy that force pods through it) depend on the cluster,
not on this image, so they are a separate follow-up. iron-proxy does publish a
Helm chart upstream. See [`docs/egress-control.md`](../egress-control.md).
Do **not** set `MULTICA_EGRESS_PROXY` without wiring `dnsConfig` at the proxy:
TLS would fail closed for every request (by design).

### Tear down

```bash
kubectl delete -f examples/k8s/deployment.yaml
kubectl delete -f examples/k8s/pvc.yaml       # drops the workspaces cache
kubectl delete -f examples/k8s/secret.example.yaml
kubectl delete -f examples/k8s/serviceaccount.yaml
kubectl delete -f examples/k8s/namespace.yaml
```
