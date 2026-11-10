# AWS profile stubs (compose + ConfigMap source)

Literal `~/.aws/config` fragment and `~/.config/aws-sso/config.yaml` for the
home-base. Published copies are **generic placeholders** — put real account
allowlists in a private overlay, not in this tree.

| File | Mounted as |
| --- | --- |
| `config` | `/run/config/aws/config` → linked into PVC-backed `~/.aws/config` |
| `config.yaml` | `/run/config/aws-sso/config.yaml` → linked into PVC-backed `~/.config/aws-sso/config.yaml` |

SSO cache (`cache.json`, etc.) is written under the workspaces volume at
`.provider-homes/aws-sso/` and survives pod recreate.

## Login workflow: `device_code`, not the default `pkce`

`config.yaml` pins `AuthWorkflow: device_code`. This is required by the
operator topology, not a taste preference.

- `aws-sso` **>= 2.2.0 defaults to `pkce`** (OAuth `authorization_code` + PKCE).
  That flow binds a temporary callback listener on `127.0.0.1:<port>` inside the
  pod's network namespace and waits for the browser to redirect to it.
- The operator's browser runs on their own machine, outside the cluster, reached
  through `kubectl exec -it` / `docker compose exec`. Its redirect to
  `127.0.0.1:<port>` resolves to the operator's machine. It never reaches the pod.
  Login then waits forever, and **no session is ever cached** — which also
  blocks the SecureStore fix below, because there is nothing to unlock.
- `device_code` prints a URL plus a user code, the operator approves it in their
  own browser, and `aws-sso` polls for the token. No inbound reachability is
  needed. Upstream documents `pkce` as unsupported on remote/headless hosts for
  exactly this reason (`docs/config.md`, "AuthWorkflow").

Upstream's valid values are `device_code` and `pkce`. There is no
`authorization_code` value — `pkce` is that flow.

Bumping the pinned `AWS_SSO_VERSION` re-opens this: a version bump that changes
an auth default must not be merged without re-checking that `AuthWorkflow` is
still pinned. `test/unit/aws-sso-config.sh` fails if either config stub loses
`AuthWorkflow: device_code`, and the boot seam asserts the linked container copy.

Session lifetime with `device_code`: `aws-sso` only started requesting a
`refresh_token` for this workflow in **2.4.0** (upstream fix for "device_code
never getting a refresh token, so sessions ended after 8 hours").
Before 2.4.0 a device-code session had no refresh token, and the operator had to
log in again every 8 hours. On the version this image pins (2.4.0) the session
refreshes normally.

## SecureStore: why agents need a passphrase env var

`config.yaml` pins `SecureStore: file`. That is aws-sso's encrypted file store at
`~/.config/aws-sso/secure/` (the in-container resolution either way: there is no
OS keyring daemon — no gnome-keyring/kwallet/D-Bus — so the keyring backends
cannot answer).

The file store is passphrase protected and asks for the passphrase on **every
process that opens it**. Operator commands run under `kubectl exec -it` /
`docker compose exec` have a TTY, so the operator types it. An agent task does
not: `credential_process` (`aws-sso process`, wired in `config`) starts with no
TTY, prints `Enter passphrase to unlock "…/secure"` to a terminal that does not
exist, gets no input, and falls through to:

```
FATAL Must run `aws-sso login` before running `aws-sso process`
```

…even though a valid cached session is sitting in that store.

**Fix: export `AWS_SSO_FILE_PASSWORD`.** It is the upstream-documented
non-interactive source for the `file` backend (aws-sso-cli 2.1.0,
`internal/storage/keyring.go` → `fileKeyringPassword`; `docs/config.md`
"SecureStore / JsonStore"). Boot lifts it from a mounted Secret file:

| Path | Purpose |
| --- | --- |
| `/run/secrets/aws-sso/AWS_SSO_FILE_PASSWORD` | Passphrase for the aws-sso file SecureStore (one line) |

Override the path with `AWS_SSO_FILE_PASSWORD_FILE`. Never put the passphrase in
this repo, the image, or a ConfigMap — it belongs in a Secret:

```bash
# Compose
mkdir -p secrets/aws-sso
printf '%s' "$AWS_SSO_FILE_PASSWORD" > secrets/aws-sso/AWS_SSO_FILE_PASSWORD
# then uncomment the ./secrets/aws-sso mount and AWS_SSO_FILE_PASSWORD_FILE in
# docker-compose.yml
```

```yaml
# Kubernetes — see examples/k8s/secret.example.yaml (multica-runtime-aws-sso-unlock)
# and the commented AWS_SSO_FILE_PASSWORD_FILE env var + mount in deployment.yaml
```

### Same passphrase on both sides

The operator login and the agents' `credential_process` open the same store, so
they must use the same passphrase:

- **Empty PVC / first login:** with the Secret mounted, `aws-sso login` never
  prompts — it creates the store with `AWS_SSO_FILE_PASSWORD`. No interactive
  passphrase is needed for a fresh install.
- **Existing store** created from an operator-typed passphrase: set the Secret to
  that same passphrase, or delete `<workspaces>/.provider-homes/aws-sso/secure/`
  and re-run the operator login so the store is recreated with the Secret's
  passphrase. Otherwise agents keep failing closed with the same `FATAL`.
- Wrong passphrase fails closed exactly like a locked store (same `FATAL`); it
  never falls back to a prompt.

Boot reports the state without printing the value — look for
`aws auth: mounted AWS config (…)` in the boot log, which names the tier and
appends `aws-sso profile(s): SecureStore passphrase is exported …` or
`aws-sso profile(s): AWS_SSO_FILE_PASSWORD unset — …`. Unset is a warning, not a
boot gate: a deployment that never uses aws-sso profiles is unaffected.

**Risk to review before merging:** the passphrase lands in the daemon
environment, so every agent task inherits it (same trust boundary as the harness
keys) — an agent can read it from its own env. It protects the token/role cache
at rest on the PVC; it is not an AWS credential and grants nothing on its own.

## Operator login (agents must not)

```bash
# Compose
docker compose exec -e AWS_SSO_OPERATOR_LOGIN=1 runtime \
  aws-sso login --url-action=print

# Kubernetes
kubectl exec -it deploy/multica-runtime -n <ns> -- \
  env AWS_SSO_OPERATOR_LOGIN=1 aws-sso login --url-action=print
```

Open the printed Identity Center URL in a browser. After consent, agents use
existing cache via `credential_process` / `--profile`. `aws-sso login` without
`AWS_SSO_OPERATOR_LOGIN=1` exits non-zero (guard wrapper).

The `-it` matters for more than the guard: it is the TTY that answers the
SecureStore passphrase prompt when `AWS_SSO_FILE_PASSWORD` is not mounted, and it
is where the `device_code` verification URL and user code are printed.

Expected output on a successful device-code login (aws-sso 2.4.0):

```text
	Verify this code in your browser: ABCD-EFGH
Please open the following URL in your browser:

https://device.sso.us-east-1.amazonaws.com/?user_code=ABCD-EFGH

INFO  Waiting for SSO authentication...
INFO  Refreshing AWS SSO role cache, please wait... sso=Default
INFO  Updated cache added=N deleted=0
```

If the printed URL instead looks like
`https://oidc.<region>.amazonaws.com/authorize?...&redirect_uri=http%3A%2F%2F127.0.0.1%3A<port>&...`,
`AuthWorkflow` is not pinned and login will hang — see the workflow section above.
