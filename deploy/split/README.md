# Split frontend/backend deployment

This deployment places the public Nginx/frontend service in front of a separately built backend service. Nginx owns the SPA, dashboard, OAuth callback and password-reset pages; it proxies only the documented API and relay namespaces to the backend. Do not expose the backend directly.

## Build inputs and immutable versions

Copy `.env.example` to `.env`, replace every placeholder, and run Compose from the repository root so both Dockerfiles use the root build context:

```sh
cp deploy/split/.env.example deploy/split/.env
# Edit deploy/split/.env before continuing.
docker compose --env-file deploy/split/.env -f deploy/split/compose.yaml build backend frontend
docker compose --env-file deploy/split/.env -f deploy/split/compose.yaml up -d
```

For source builds, set `APP_VERSION` to the exact release identifier embedded in the backend and frontend. Record the commit separately:

```sh
git rev-parse HEAD
APP_VERSION='v1.0.0-rc.21' docker compose --env-file deploy/split/.env \
  -f deploy/split/compose.yaml build backend frontend
```

A supplied backend image must be immutable and report the same version expected by the frontend. Never use a mutable image tag:

```sh
BACKEND_IMAGE='registry.example/new-api@sha256:<immutable-digest>' \
APP_VERSION='<release-version>' \
docker compose --env-file deploy/split/.env -f deploy/split/compose.yaml pull backend
docker compose --env-file deploy/split/.env -f deploy/split/compose.yaml up -d --no-build
```

`Dockerfile.frontend`, `Dockerfile.backend`, `nginx/nginx.conf.template`, `compose.yaml`, and `scripts/render-index.sh` are deployment inputs supplied alongside this guide. The frontend renderer must emit `build-info.json` with the immutable `version` and the selected `theme`.

## Required configuration

Before publishing the frontend URL, configure the backend database values:

- **ServerAddress**: the one public HTTPS origin. It is used in generated links and callback URLs.
- **Theme DB setting**: select `default` or `classic`; the frontend image and backend setting must match exactly.
- **Session variables**: use a long, random, stable `SESSION_SECRET`; for HTTPS set `SESSION_COOKIE_SECURE=true` and `SESSION_COOKIE_TRUSTED_URL` to the exact public HTTPS origin.
- **Passkey settings**: set Origins to the exact public HTTPS origin and the RP ID to the hostname without a port before enabling passkeys.
- **Request size**: keep Nginx `MAX_REQUEST_BODY_MB` at least as large as the backend value.

Set the Compose environment variables required by the template: public host/scheme/port, frontend theme/version, immutable backend image or source build inputs, database/Redis credentials, request size, session settings, and optional analytics IDs. `SESSION_COOKIE_TRUSTED_URL` validates secure-cookie startup configuration; Nginx Host enforcement remains the inbound host boundary. For a trusted CDN or load balancer, replace `nginx/real-ip.conf.template` with explicit provider CIDRs; never accept arbitrary forwarding headers.

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
4. Deploy both images atomically, then run the public verifier and smoke checklist.

This split-deployment change introduces no database schema migration. Keep the previous all-in-one image, deployment configuration, and prior `theme.frontend` value. To roll back, stop public traffic to the split edge, restore the prior theme value if it changed, start the unchanged all-in-one service, and verify login plus generated return paths. When also upgrading the application version, separately review that release's migrations; never assume an older binary supports a schema changed by another release.

## Exact validation commands

Run these from the repository root:

```sh
sh -n deploy/split/scripts/verify-deployment.sh \
  deploy/split/scripts/check-route-ownership.sh \
  deploy/split/tests/route-contract.sh
deploy/split/scripts/check-route-ownership.sh "$(pwd)"
deploy/split/tests/route-contract.sh
PUBLIC_URL='https://api.example.com' EXPECTED_VERSION='<version>' EXPECTED_THEME=default \
  deploy/split/scripts/verify-deployment.sh
```

`route-contract.sh` uses Docker, the actual rendered Nginx configuration, a static fixture, and a marker backend. It prints `SKIP` with remediation if Docker or its daemon is unavailable; a skip is not a passing deployment validation.
