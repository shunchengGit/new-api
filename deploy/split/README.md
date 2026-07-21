# Split frontend/backend deployment

This deployment separates a selected frontend theme from the backend while keeping every browser-visible request on one public origin. Two edge adapters are supported:

- **Container edge**: the frontend artifact runs in the supplied unprivileged Nginx container.
- **Host-static edge**: an existing host-managed Nginx serves an immutable rendered frontend release and proxies the same shared backend route contract.

Nginx owns the SPA, dashboard, OAuth callback and password-reset pages; it proxies only the documented API and relay namespaces to the private backend. Do not expose the backend directly. Different frontend/API origins and URL subpaths remain unsupported.

The host-static adapter does not install Nginx or own DNS, TLS certificates, global access logs, request IDs, firewall rules, or machine-specific trusted-proxy policy. Optional Redis topology and the separate LinuxDO OAuth correction are outside this change.

## Build inputs and immutable versions

Build source images explicitly from the repository root using the Dockerfiles below. Set `APP_VERSION` to the exact release identifier and `VCS_REF` to the reviewed 40-character commit. Do not start production Compose from local tags:

```sh
APP_VERSION='v1.0.0-rc.21'
VCS_REF="$(git rev-parse HEAD)"

docker buildx build --file deploy/split/Dockerfile.backend \
  --build-arg APP_VERSION="$APP_VERSION" \
  --build-arg VCS_REF="$VCS_REF" \
  --tag registry.example/new-api-backend:"$APP_VERSION" --push .

docker buildx build --file deploy/split/Dockerfile.frontend \
  --target frontend-runtime \
  --build-arg THEME=default \
  --build-arg APP_VERSION="$APP_VERSION" \
  --build-arg VCS_REF="$VCS_REF" \
  --tag registry.example/new-api-frontend-default:"$APP_VERSION" --push .
```

Resolve the pushed frontend/backend images and reviewed PostgreSQL/Redis images to immutable `name@sha256:<64-hex-digest>` references. Copy `.env.example` to `.env` and replace all four image placeholders plus every Secret placeholder. The production Compose file is runtime-only and intentionally has no `build:` blocks or mutable defaults:

```sh
cp deploy/split/.env.example deploy/split/.env
# Edit deploy/split/.env before continuing.
docker compose --env-file deploy/split/.env -f deploy/split/compose.yaml config > /tmp/new-api-split.compose.yaml
deploy/split/scripts/verify-compose-images.sh /tmp/new-api-split.compose.yaml
docker compose --env-file deploy/split/.env -f deploy/split/compose.yaml pull
docker compose --env-file deploy/split/.env -f deploy/split/compose.yaml up -d --no-build
```

Every runtime image must remain digest-pinned. A tag may be used only as a temporary build/push handle before its manifest digest is resolved and recorded in the release tuple.

`Dockerfile.frontend`, `Dockerfile.backend`, the files under `nginx/`, `compose.yaml`, and the scripts under `scripts/` are deployment inputs supplied alongside this guide. Both source builds require one immutable 40-character `VCS_REF`. Public `build-info.json` records schema, version, selected theme, and revision; `artifact-manifest.json` additionally records backend compatibility and the Bun lockfile digest.

## Portable frontend artifacts

The frontend Dockerfile builds the selected theme once and exposes two targets:

```sh
APP_VERSION='v1.0.0-rc.21'
VCS_REF="$(git rev-parse HEAD)"
THEME=default

# Export a portable directory. Use a new empty destination.
docker buildx build \
  --file deploy/split/Dockerfile.frontend \
  --target frontend-artifact \
  --build-arg THEME="$THEME" \
  --build-arg APP_VERSION="$APP_VERSION" \
  --build-arg VCS_REF="$VCS_REF" \
  --output "type=local,dest=frontend-artifact-$THEME" \
  .

deploy/split/scripts/verify-artifact.sh "frontend-artifact-$THEME"

# Build the existing container adapter from the same artifact-producing stage.
docker buildx build \
  --file deploy/split/Dockerfile.frontend \
  --target frontend-runtime \
  --build-arg THEME="$THEME" \
  --build-arg APP_VERSION="$APP_VERSION" \
  --build-arg VCS_REF="$VCS_REF" \
  --load --tag "new-api-frontend-$THEME:$APP_VERSION" \
  .
```

Each exported directory contains `site/`, `licenses/`, `artifact-manifest.json`, and `checksums.sha256`. It contains exactly one theme, includes the repository license/notice files and frontend-emitted license files, and has no wall-clock build metadata. The integrity manifest covers the exact directory and regular-file set; symbolic links, devices, sockets, FIFOs, unexpected files, and unexpected empty directories are rejected. Treat the exported directory as immutable. Record an outer digest separately if it is archived or uploaded. Rebuild artifacts produced before this exact-entry format instead of bypassing verification.

Render environment-specific analytics into a new release directory rather than editing the artifact:

```sh
UMAMI_WEBSITE_ID='' GOOGLE_ANALYTICS_ID='' \
  deploy/split/scripts/render-release.sh \
  /path/to/frontend-artifact-default \
  /path/to/releases/<new-release-id>
```

The destination must be absent or empty. Rendering verifies the exact artifact file set first and never modifies the source artifact. It writes `<release-root>.sha256` beside, not inside, the Web Root; retain and protect that exact-entry sidecar with the release because the host candidate gate rejects modified files, added entries, symbolic links, and missing sidecars.

## Required configuration

Before publishing the frontend URL, configure the backend database values:

- **ServerAddress**: the one public HTTPS origin. It is used in generated links and callback URLs.
- **Theme DB setting**: select `default` or `classic`; the frontend image and backend setting must match exactly.
- **Session variables**: use a long, random, stable `SESSION_SECRET`; for HTTPS set `SESSION_COOKIE_SECURE=true` and `SESSION_COOKIE_TRUSTED_URL` to the exact public HTTPS origin.
- **Passkey settings**: set Origins to the exact public HTTPS origin and the RP ID to the hostname without a port before enabling passkeys.
- **Request size**: keep Nginx `MAX_REQUEST_BODY_MB` at least as large as the backend value.

Set the Compose environment variables required by the template: public host/scheme/port, frontend theme/version, four immutable runtime image digests, database/Redis credentials, request size, session settings, and optional analytics IDs. `SESSION_COOKIE_TRUSTED_URL` validates secure-cookie startup configuration; Nginx Host enforcement remains the inbound host boundary. For a trusted CDN or load balancer, replace `nginx/real-ip.conf.template` with explicit provider CIDRs; never accept arbitrary forwarding headers.

## Host-static adapter

Render the portable artifact into a new immutable release, then render the host adapter into a candidate configuration directory that does not yet exist:

```sh
release_root=/srv/new-api/releases/<new-release-id>
config_root=/etc/nginx/new-api-candidate
challenge="$(openssl rand -hex 32)"

HOST_NGINX_CONFIG_DIR="$config_root" \
PUBLIC_HOST=api.example.com \
EXTERNAL_SCHEME=https \
STATIC_RELEASE_ROOT="$release_root" \
BACKEND_ENDPOINT=http://127.0.0.1:3000 \
CLIENT_MAX_BODY_SIZE=128m \
HOST_REAL_IP_INCLUDE=/etc/nginx/conf.d/trusted-real-ip.conf \
DEPLOYMENT_CHALLENGE="$challenge" \
  deploy/split/scripts/render-host-nginx.sh
```

The renderer emits `host-http-prerequisites.conf`, `host-server.inc`, `route-contract.inc`, and `backend-proxy.inc`. Include `host-http-prerequisites.conf` once in the operator-owned `http {}` context. Include `host-server.inc` inside the operator's existing canonical `server {}` block, where the operator explicitly configures `listen 443 ssl`, certificates, HTTP/2, logs, request IDs, and security headers:

```nginx
http {
    include /etc/nginx/new-api-candidate/host-http-prerequisites.conf;

    server {
        listen 443 ssl;
        server_name api.example.com;
        # Operator-owned TLS, logs, request IDs, and security headers.
        include /etc/nginx/new-api-candidate/host-server.inc;
    }
}
```

The generated adapter never emits a `listen` or certificate directive, so it cannot silently create plaintext port 443. The complete operator-owned candidate main configuration, not an include fragment, is the file passed to `nginx -T`. Do not copy the Docker resolver, container `/tmp` paths, example hostname, or example backend address into a real host deployment.

The backend endpoint must be private: use loopback, a private container network endpoint, a Unix-socket integration supported by an environment-specific wrapper, or another firewall-restricted address. This overlay never creates a public backend listener. If a CDN or load balancer precedes host Nginx, `HOST_REAL_IP_INCLUDE` must trust only its explicit CIDRs. Without such a proxy, use an operator-owned no-op real-IP include; never forward client-supplied `X-Forwarded-*` values unchanged.

Before activation, run the complete candidate gate:

```sh
ARTIFACT_ROOT=/path/to/frontend-artifact-default \
RELEASE_ROOT="$release_root" \
HOST_NGINX_CONFIG=/etc/nginx/nginx.candidate.conf \
HOST_NGINX_BINDING_FILE="$config_root/host-server.inc" \
CANDIDATE_URL=http://127.0.0.1:<candidate-port> \
PUBLIC_HOST=api.example.com \
DEPLOYMENT_CHALLENGE="$challenge" \
EXPECTED_VERSION=v1.0.0-rc.21 \
EXPECTED_THEME=default \
EXPECTED_REVISION="$(git rev-parse HEAD)" \
  deploy/split/scripts/verify-host-release.sh
```

`CANDIDATE_URL` must reach a running candidate Nginx listener that loads `HOST_NGINX_CONFIG` and proxies the candidate private backend; use a loopback staging port/socket or an isolated staging listener before switching public traffic. The verifier requires the complete candidate config to include `HOST_NGINX_BINDING_FILE`, requires that include to contain the one-time 64-hex `DEPLOYMENT_CHALLENGE`, and retrieves the same challenge through the canonical `PUBLIC_HOST`. An unrelated old service or unrelated syntax-checked config therefore cannot satisfy the gate. Generate a new challenge for every candidate and do not reuse it as a Secret.

`BACKEND_ENDPOINT` is intentionally restricted to `localhost` or a loopback/RFC1918 IPv4 literal with an explicit port. Public DNS names and public IP addresses are rejected; environments needing a different private transport must provide a separately reviewed adapter rather than weakening this boundary.

`NGINX_TEST_COMMAND` may name an absolute executable wrapper when the candidate must be checked by a pinned Nginx container. The wrapper receives `HOST_NGINX_CONFIG` as its only argument, must run `nginx -T -c "$1"`, and must preserve the complete expansion on stdout/stderr; a no-op command or filtered output fails because the gate requires Nginx's `# configuration file <HOST_NGINX_BINDING_FILE>:` marker. The gate verifies artifact integrity, the rendered release's external exact-set sidecar, Nginx syntax, frontend metadata, SPA/API ownership, missing-asset behavior, mutable entry caching, and backend version/theme agreement. It does not start Nginx or change the active release pointer.

## Deploy and smoke test

1. Build or pull the pinned images, then start the stack using the commands above.
2. Confirm DNS/TLS terminates at Nginx only; firewall the backend service from public access.
3. Run the deployment verifier from an operator workstation:

   ```sh
   PUBLIC_URL='https://api.example.com' \
   EXPECTED_VERSION='<release-or-commit>' EXPECTED_THEME=default \
   deploy/split/scripts/verify-deployment.sh
   ```

4. Manually verify password login and the Secure/SameSite session cookie; GitHub, Discord, OIDC, and custom OAuth callbacks; Passkey registration/login; an API token request; permitted multipart uploads; `POST /v1/chat/completions` streaming; `/v1/realtime`; signed payment callbacks; and password-reset, payment-return, Midjourney, and video links generated from `ServerAddress`.
5. Inspect browser network traffic: SPA pages must come from Nginx, `/api/*` and relay namespaces from the backend, and missing `/assets/*` or `/static/*` files must be 404 rather than SPA HTML.

Theme changes are an atomic release: render/build the new frontend theme with its new immutable version, set the backend theme DB setting, then roll frontend and backend together. Do not change only the database theme or only the frontend image; `verify-deployment.sh` rejects mismatches.

## LinuxDO OAuth limitation

LinuxDO OAuth has a known callback incompatibility behind TLS-terminating Nginx even though this deployment remains same-origin. The backend currently derives a different HTTP `/api/oauth/linuxdo` exchange URI instead of the browser-facing HTTPS `/oauth/linuxdo` callback. This can break LinuxDO **login, registration, and account binding**. The verifier fails when `/api/status` reports `linuxdo_oauth: true`; it can be bypassed only with this explicit operator acknowledgement:

```sh
ACKNOWLEDGE_LINUXDO_OAUTH_INCOMPATIBILITY=true \
PUBLIC_URL='https://api.example.com' EXPECTED_VERSION='<version>' EXPECTED_THEME=default \
deploy/split/scripts/verify-deployment.sh
```

This acknowledgement does not make the flow work. Disable LinuxDO OAuth, retain a deployment where its callback has been verified, or apply the separate upstream callback correction before cutover.

## Supported boundary

Unsupported configurations are: direct public access to the backend, frontend and backend on different origins, hosting below a URL subpath, and trusting client-provided forwarding headers. Nginx must reject unknown `Host` values and overwrite `X-Forwarded-For`; downstream applications must treat proxy headers as trusted only from this Nginx network.

## Upgrade and rollback

Before an upgrade:

1. Read release migration notes and back up the database and persistent volumes.
2. Pin the target backend digest/source commit and build the matching themed frontend.
3. Run static and black-box validation below before production.
4. Deploy both images atomically for the container adapter, or render and verify a new immutable release for the host adapter.
5. Run the public verifier and manual smoke checklist before declaring the release ready.

Record one release tuple for every cutover. Use `release-tuple.example.json` as the field contract and store the completed record outside the public Web Root:

```text
frontend artifact SHA-256
frontend version, theme, and source revision
immutable rendered release ID
backend image digest
backend reported version and configured theme
reference to the previous compatible tuple
```

For the host adapter, never upload over the active Web Root. Render into a new `releases/<release-id>` directory, verify the candidate configuration and public route, then atomically switch an operator-owned `current` pointer to that directory. Reload Nginx only after `nginx -t` succeeds. Retain at least the prior release and tuple.

Rollback switches `current` back to the retained prior frontend release and restores the prior compatible backend image and `theme.frontend` value when either changed. The unchanged frontend-container and all-in-one deployments remain fallback paths. This capability introduces no database migration; when the application version also changes, follow that release's database rollback rules and never assume an older binary supports a newer schema.

## Exact validation commands

Run these from the repository root:

```sh
find deploy/split/scripts deploy/split/tests -type f -name '*.sh' -print0 | xargs -0 sh -n
deploy/split/scripts/check-route-ownership.sh "$(pwd)"
deploy/split/tests/check-route-ownership-fixture.sh
deploy/split/tests/compose-images-fixture.sh
deploy/split/tests/release-rendering-fixture.sh
deploy/split/tests/verify-deployment-contract.sh
deploy/split/tests/verify-host-release-contract.sh
REQUIRE_RUNTIME=true deploy/split/tests/route-contract.sh
docker buildx build --file Dockerfile --load --tag new-api-all-in-one:host-static-check .
name=new-api-all-in-one-smoke
trap 'docker rm -f "$name" >/dev/null 2>&1 || true' EXIT HUP INT TERM
docker run -d --name "$name" -p 127.0.0.1::3000 new-api-all-in-one:host-static-check
port=$(docker port "$name" 3000/tcp | python3 -c 'import sys; print(sys.stdin.read().strip().rsplit(":", 1)[1])')
for attempt in $(seq 1 60); do
  if curl --fail --silent --max-time 2 "http://127.0.0.1:$port/api/status" \
    | grep -Eq '"success"[[:space:]]*:[[:space:]]*true'; then break; fi
  [ "$attempt" -lt 60 ] || { docker logs "$name"; exit 1; }
  sleep 0.1
done
curl --fail --silent --max-time 5 "http://127.0.0.1:$port/dashboard" | grep -Eqi '<!doctype html>|<div id="root"'
PUBLIC_URL='https://api.example.com' EXPECTED_VERSION='<version>' EXPECTED_THEME=default \
  EXPECTED_REVISION='<40-character-source-revision>' \
  deploy/split/scripts/verify-deployment.sh
```

`route-contract.sh` uses Docker, both actual rendered Nginx adapters, one static fixture, one marker backend, and one assertion set. It proves both adapters preserve identical route, cache, forwarding-header, SSE, WebSocket, callback, and upload behavior. Local runs without Docker print `SKIP`, which is not a passing validation; CI and release gates set `REQUIRE_RUNTIME=true`, making missing runtime prerequisites fail. The temporary all-in-one tag above is only a compatibility build/runtime check and is never a valid production Compose image reference.

The repository workflow `.github/workflows/split-deployment-check.yml` performs static checks, both theme artifact/runtime builds and runtime smoke tests, the backend-only build, all-in-one build/runtime smoke, Go tests, release fixtures, immutable Compose image checks, and both adapter route contracts. It verifies buildability and disposable runtime contracts only; it does not publish, sign, push, or deploy artifacts or images.

## Validation evidence

The implementation was validated with the exact commands in the preceding section. The recorded outcomes were:

- `check-route-ownership.sh` and its prefix-negative fixture: PASS.
- `compose-images-fixture.sh`: PASS for four digest references and rejection of tags/malformed digests.
- `release-rendering-fixture.sh`: PASS, including symlink/FIFO/extra-entry and release-sidecar negatives.
- `verify-deployment-contract.sh`: PASS.
- Host renderer validation: PASS for atomic new-directory publication, existing-candidate preservation, private backend enforcement, and no staging/lock residue.
- `verify-host-release-contract.sh`: PASS, including wrong challenge, commented binding plus no-op syntax command with a healthy candidate, and modified release negatives.
- `REQUIRE_RUNTIME=true route-contract.sh`: container PASS and host PASS for routing, SSE, WebSocket, uploads, cache, Host, and forwarding headers.
- `frontend-artifact` export/verification and read-only `frontend-runtime` smoke: PASS for `default` and `classic`.
- Cached backend-only image build, immutable revision-label/invalid-revision checks, and `go test ./...` in the pinned Go builder: PASS; both themed frontend jobs use isolated Buildx cache scopes.
- The unchanged default all-in-one Dockerfile build and container runtime smoke: PASS for `/api/status` and the embedded `/dashboard` SPA; the existing frontend-container adapter also passed its runtime contract.
- `openspec validate add-host-static-split-deployment --strict`, Compose rendering, Workflow YAML parsing, and `git diff --check`: PASS.

These fixture results do not replace the manual authentication, payment-callback, real model/SSE billing, CDN, or production TLS checks required before a real cutover.
