## Context

The production Go binary currently embeds both `web/default/dist` and `web/classic/dist` and serves one of them from Gin. The frontend clients already use root-relative API URLs, so they can be served by a separate static server without changing request code as long as browser-visible frontend and API paths remain on one origin.

The deployment must remain easy to rebase onto later upstream releases. Existing application files, root Dockerfiles, root Compose files, and release workflows are therefore treated as upstream-owned. The split topology will be an additive overlay under `deploy/split/`. The Go compiler still requires both embedded directories; an API-only image can satisfy that compile-time contract with minimal placeholder `index.html` files while keeping the backend port private and unreachable from clients.

The public path space is shared by browser-history SPA routes and APIs. Most backend traffic has stable prefixes, but two exceptions require care: only two exact legacy endpoints belong under root `/dashboard/billing`, while `/:mode/mj` creates mode-prefixed Midjourney routes outside a fixed root namespace. Streaming responses, WebSockets, large multipart requests, payment callbacks, secure sessions, client IP controls, passkeys, and backend-generated absolute URLs must retain their existing semantics through Nginx.

## Goals / Non-Goals

**Goals:**

- Provide independently built frontend and backend images behind one public Nginx origin.
- Keep all current application source and all-in-one deployment behavior unchanged.
- Build exactly one selected frontend theme per image while allowing both theme variants to be published from one Dockerfile.
- Preserve API, callback, SSE, WebSocket, upload, SPA fallback, and static caching behavior.
- Make release version, selected theme, canonical public URL, session security, and known incompatibilities observable and verifiable before cutover.
- Keep the backend accessible only from the deployment network so clients cannot bypass Nginx or inject trusted forwarding context.

**Non-Goals:**

- Removing `go:embed` declarations or web routing from the Go application.
- Supporting different frontend and API browser origins.
- Preserving runtime theme switching without redeploying the selected frontend image.
- Redesigning authentication, OAuth, CORS, passkeys, payments, or application routing.
- Correcting LinuxDO OAuth in this change; the deployment will report it as incompatible until a separate upstream correction unifies its callback URI.
- Replacing the existing all-in-one images, Compose file, or release process.

## Decisions

### 1. Isolate all changes in a deployment-owned overlay

Add only files under `deploy/split/`, with an expected structure similar to:

```text
deploy/split/
  Dockerfile.backend
  Dockerfile.frontend
  compose.yaml
  .env.example
  nginx/default.conf.template
  scripts/render-index.sh
  scripts/verify-deployment.sh
  tests/route-contract.sh
  README.md
```

The overlay uses the repository root as its Docker build context but does not edit upstream-owned files. Keeping the integration at the deployment boundary minimizes merge conflicts and makes removal or rollback equivalent to selecting a different Compose file.

Alternative considered: add build tags and an API-only router mode to Go. That would produce a purer backend binary but would modify startup and routing code across every upstream merge. The placeholder embed compromise is preferred for this change.

### 2. Build separate immutable backend and theme-specific frontend artifacts

`Dockerfile.backend` follows the existing backend-only development build pattern: copy Go source, create minimal `web/default/dist/index.html` and `web/classic/dist/index.html`, and compile the binary with the repository version linker value. It does not install Bun or build either frontend. The runtime image retains the existing working directory, entrypoint, certificates, timezone data, licenses, port, and architecture arguments.

`Dockerfile.frontend` accepts validated `THEME=default|classic` and `APP_VERSION` build arguments, installs the Bun workspace from the root lockfile, builds only the selected workspace, and copies its `dist` into an unprivileged Nginx image. It emits a small `build-info.json` containing the selected theme and source version. CI may publish separate `web-default:<version>` and `web-classic:<version>` image tags from this Dockerfile.

Compose supports the source-built backend and an operator-supplied pinned upstream image. A pinned upstream image remains the lowest-maintenance option when an unmodified official backend is sufficient, although it still contains unused embedded frontend bytes. The API-only Dockerfile is the option that provides true independent source builds for patched or locally built releases.

Both images must originate from the same immutable release tag or commit. Floating `latest` tags are not part of the production example.

### 3. Keep Nginx as the sole public service

Only Nginx publishes a host port. The backend uses the internal Compose network and an unexported container port. Database and Redis ports are also internal by default. Nginx resolves the backend service through container DNS and the chosen pinned Nginx version must support re-resolution so backend container replacement does not require an edge restart.

The deployment forwards the external Host and a deployment-controlled public scheme, not client-supplied forwarding headers. It overwrites `X-Forwarded-For` and `X-Real-IP` from the normalized Nginx client address. If a CDN or load balancer precedes Nginx, only its documented CIDRs may be trusted through a separate real-IP include; arbitrary inbound `X-Forwarded-*` values are never appended. Unknown Host values are rejected at the edge.

This network isolation is mandatory because the current application does not configure Gin trusted proxy CIDRs, while `ClientIP()` affects rate limits, token IP restrictions, Turnstile, audits, and payment logs.

Alternative considered: publish both Nginx and backend ports for troubleshooting. This would allow bypassing host, scheme, request-size, and forwarding-header controls, so troubleshooting access must instead use container exec, an SSH tunnel, or a temporary bound loopback port.

### 4. Define an explicit shared path-ownership contract

Nginx proxies these fixed backend namespaces, including their exact root and descendants where applicable:

- `/api`
- `/v1`
- `/v1beta`
- `/pg`
- `/mj`
- `/suno`
- `/kling`
- `/jimeng`

It proxies only the exact root legacy endpoints `/dashboard/billing/subscription` and `/dashboard/billing/usage`, including their optional trailing-slash form. It must not proxy all of `/dashboard`, which belongs to the default SPA.

Mode-prefixed Midjourney matching is constrained to currently registered action roots:

```text
/<one-segment>/mj/(image|submit|task|insight-face)/...
```

This preserves real `/:mode/mj` APIs without routing a generic SPA URL such as `/dashboard/mj` to the placeholder backend. Because this exception cannot be represented as a stable fixed prefix, route-contract tests make changes to its registered action roots explicit during upstream upgrades.

`/assets/` and `/static/` are always static and return 404 when missing. All other paths use `try_files` with an `index.html` fallback. OAuth browser callbacks such as `/oauth/github` and password-reset pages remain SPA routes; their subsequent `/api/...` calls are proxied.

Alternative considered: send every request to the backend first and use a 404 fallback. The backend's NoRoute handler serves embedded SPA HTML rather than a reliable 404, so Nginx cannot infer path ownership this way.

### 5. Apply streaming-safe proxy behavior to every backend location

A shared Nginx include/configuration applies the same proxy settings to all backend namespaces:

- HTTP/1.1 and WebSocket `Upgrade`, `Connection`, and `Sec-WebSocket-Protocol` forwarding.
- Response buffering, request buffering, proxy caching, and error interception disabled.
- Long read/send timeouts suitable for relay streams and asynchronous provider operations.
- A configurable `client_max_body_size` that must be at least the backend `MAX_REQUEST_BODY_MB` value.
- Original method, path, query string, request body, callback signature headers, authorization headers, and response status preserved.

Applying the settings broadly covers provider-selected SSE under `/v1`, Ollama pull SSE under `/api`, realtime WebSockets, multipart requests, video byte responses, and future streaming endpoints under an already reserved prefix. No shared proxy cache is introduced, including for responses that carry public cache headers but are authorization-dependent.

### 6. Separate immutable static caching from mutable entry assets

Hashed `/assets/` and `/static/` files receive long-lived immutable caching. `index.html`, `build-info.json`, and root-level public assets such as `logo.png`, `favicon.ico`, and `robots.txt` are revalidated or served with no-cache semantics. SPA fallback resolves to the no-cache rendered index so a deployment cannot leave browsers pinned to an obsolete chunk graph.

The frontend image retains a pristine index template. `render-index.sh` writes a runtime copy into a writable temporary location and replaces the existing Umami and Google Analytics placeholders using the same environment variable names as the all-in-one service. Nginx serves that rendered copy while the rest of the image may remain read-only. Empty analytics configuration leaves only the existing attribution comments and makes no external request.

Alternative considered: rely on the Go startup injection. Nginx never requests the backend index in this topology, so those injected bytes are unreachable.

### 7. Treat public URL and session settings as deployment prerequisites

The database-backed `ServerAddress` setting must equal the exact external HTTPS origin without a trailing slash. It is not assumed to be an environment variable. OAuth token exchanges, password reset links, payment returns and callback defaults, Midjourney links, and task video URLs depend on it.

Production backend environment requires a stable `SESSION_SECRET`, `SESSION_COOKIE_SECURE=true`, and `SESSION_COOKIE_TRUSTED_URL` containing the external HTTPS origin. The latter is accurately documented as a startup validation prerequisite for secure cookies, not an inbound Host allowlist. Nginx provides actual Host enforcement.

Passkey deployments configure explicit Origins equal to the external HTTPS origin and an RP ID equal to the hostname without a port. Nginx forwards the public Host and configured external scheme. Same-origin operation requires no CORS changes.

### 8. Make the frontend theme a deployment invariant

A static frontend image serves one theme. The database setting `theme.frontend` must match `build-info.json`; changing the admin setting alone is unsupported. The verification script compares `/api/status` with frontend build metadata and fails on mismatch because backend-generated payment, log, and profile redirects also depend on the theme.

Switching themes means deploying the other frontend image and updating `theme.frontend` as one coordinated operation. Rollback performs both steps together.

Alternative considered: package both themes and select at request time in Nginx. Open-source Nginx has no access to the database-backed setting without adding a new application contract, and merging both roots creates asset-name collisions.

### 9. Validate the topology as a release contract

`verify-deployment.sh` checks:

- frontend and backend health through the public origin;
- frontend theme versus `/api/status` theme;
- frontend build version versus backend version;
- HTTPS canonical `ServerAddress` and secure deployment prerequisites called out for manual/API verification;
- LinuxDO enablement, producing a blocking warning unless explicitly acknowledged;
- representative SPA and API responses are not confused.

`tests/route-contract.sh` starts the actual Nginx configuration against a marker backend and static fixture. It proves fixed prefixes, exact legacy dashboard routes, mode-prefixed Midjourney actions, SPA routes, missing assets, query preservation, and WebSocket/streaming configuration ownership. Upgrade instructions require running this test and reviewing new Gin root namespaces before changing the pinned upstream version.

### 10. Keep LinuxDO OAuth outside this deployment contract

The current LinuxDO exchange derives an HTTP `/api/oauth/linuxdo` redirect URI from direct backend TLS state, while the browser-facing callback convention is `/oauth/linuxdo`. TLS termination at Nginx leaves backend TLS state empty, and the callback shape also interacts poorly with the Strict session cookie used for OAuth state.

This overlay cannot correct that behavior with headers alone. Verification reports enabled LinuxDO login, registration, or binding as incompatible unless the operator explicitly acknowledges that a separate upstream patch has been applied. Other authentication and OAuth providers retain the same-origin SPA callback flow.

## Risks / Trade-offs

- **[The backend binary still contains placeholder HTML]** → The backend port remains private; producing a binary with no web embedding is deferred to a separate application-level change.
- **[A new upstream root API namespace can fall through to SPA HTML]** → Broad fixed namespaces cover normal endpoint additions; route-contract tests and the upgrade checklist require explicit review of newly registered root groups.
- **[Mode-prefixed Midjourney adds a new action root]** → The action-root contract test fails until the Nginx matcher is deliberately updated.
- **[Theme setting and deployed frontend drift]** → Preflight compares public status with `build-info.json` and blocks cutover on mismatch.
- **[Frontend and backend versions drift]** → Images use immutable versions and preflight compares their metadata before release.
- **[Forwarded client IP is spoofed or lost]** → Backend has no public port, Nginx rejects unknown hosts and overwrites forwarding headers; trusted upstream proxy CIDRs require explicit configuration.
- **[Nginx rejects a request the backend would accept]** → Request-size and timeout values are configurable and documented to remain at least as permissive as backend limits.
- **[SSE, WebSocket, or authenticated media is buffered or cached]** → Shared backend settings disable buffering and caching and route tests exercise protocol-specific paths.
- **[Analytics behavior differs from all-in-one startup injection]** → The frontend entrypoint renders the same placeholders using the same environment variable names.
- **[LinuxDO users lose an authentication path]** → Preflight reports the enabled feature as incompatible; operators must disable it, retain the old topology, or apply a separate upstream correction before cutover.
- **[Overlay Dockerfiles duplicate upstream runtime details]** → Prefer a pinned official backend when possible and include an upgrade checklist comparing base images, packages, entrypoint, licenses, version flags, and shutdown behavior.

## Migration Plan

1. Choose an immutable upstream release or commit and build matching backend plus `default` and/or `classic` frontend images.
2. Run route-contract tests and compare overlay backend runtime details with the selected upstream Dockerfile.
3. Back up the database and persistent `/data` volume; retain the previous all-in-one image and Compose definition.
4. Set the database-backed `ServerAddress` and `theme.frontend` values for the target public origin and selected frontend.
5. Configure stable session secrets, secure cookie settings, database/Redis credentials, body-size limits, analytics, passkey origin/RP ID, and external TLS.
6. Start the backend on the private network, then Nginx; run deployment verification and authentication, upload, SSE, WebSocket, payment callback, and SPA smoke tests.
7. Move public traffic to Nginx only after verification passes.
8. Roll back by restoring traffic to the unchanged all-in-one service and, if necessary, restoring the prior `theme.frontend` value. No database schema migration is introduced by this change.

## Open Questions

- Whether production will terminate TLS in this Nginx container or at a separately managed trusted load balancer; the reference configuration must make the selected public scheme explicit in either case.
- Whether published deployment artifacts should default to the source-built API-only image or require operators to supply a pinned official backend digest.
- Whether LinuxDO compatibility should become a separate application change immediately after this deployment overlay.
- Whether a future upstream change should add explicit Gin trusted-proxy CIDR configuration, reducing reliance on network isolation and edge header normalization.
