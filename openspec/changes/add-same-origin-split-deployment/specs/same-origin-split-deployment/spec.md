## ADDED Requirements

### Requirement: Additive deployment overlay
The repository SHALL provide an opt-in same-origin split deployment entirely through deployment-owned files and SHALL leave the existing application source, root build files, root Compose files, and all-in-one deployment behavior unchanged.

#### Scenario: Existing deployment remains available
- **WHEN** an operator does not select the split deployment configuration
- **THEN** the existing frontend-embedded backend build and deployment SHALL continue to operate without depending on the new overlay

#### Scenario: Upstream changes are merged
- **WHEN** a later upstream release is incorporated into the repository
- **THEN** split-deployment maintenance SHALL be isolated to the deployment overlay and its documented compatibility checks

### Requirement: Independent frontend and backend artifacts
The deployment SHALL support independently built backend and frontend container images derived from the same immutable source version. The frontend build SHALL include exactly one selected `default` or `classic` theme, and the backend-only source build SHALL compile without building either frontend.

#### Scenario: Build default frontend independently
- **WHEN** the frontend image is built with the `default` theme and a source version
- **THEN** the resulting image SHALL contain the default theme static distribution and build metadata identifying that theme and source version

#### Scenario: Build classic frontend independently
- **WHEN** the frontend image is built with the `classic` theme and a source version
- **THEN** the resulting image SHALL contain the classic theme static distribution and build metadata identifying that theme and source version

#### Scenario: Reject unsupported theme
- **WHEN** the frontend build receives a theme other than `default` or `classic`
- **THEN** the build SHALL fail instead of producing an ambiguous image

#### Scenario: Build backend without frontend toolchain
- **WHEN** the backend-only source image is built
- **THEN** it SHALL satisfy the existing Go embed inputs with placeholder entry files and SHALL NOT install frontend dependencies or build frontend bundles

### Requirement: Single public origin and private backend
Nginx SHALL be the only publicly reachable HTTP service in the split deployment. Browser-visible frontend and backend requests SHALL use the same scheme, host, and port, while the backend SHALL be reachable only on the internal deployment network.

#### Scenario: Browser requests API from frontend
- **WHEN** a browser loads the deployed frontend and sends a root-relative API request
- **THEN** the request SHALL remain on the public frontend origin and Nginx SHALL forward it internally to the backend

#### Scenario: Client attempts direct backend access
- **WHEN** a client connects through the deployment's published host ports
- **THEN** no direct backend listener SHALL be exposed for bypassing Nginx

#### Scenario: Unknown host is supplied
- **WHEN** a request uses a Host value outside the configured public hosts
- **THEN** Nginx SHALL reject the request rather than forwarding attacker-controlled host context

### Requirement: Backend and SPA path ownership
Nginx SHALL forward all existing backend namespaces without forwarding frontend SPA routes to the placeholder backend. It SHALL use broad ownership for stable backend prefixes and exact or constrained matching for root-level exceptions.

#### Scenario: Fixed backend namespace request
- **WHEN** a request targets `/api`, `/v1`, `/v1beta`, `/pg`, `/mj`, `/suno`, `/kling`, or `/jimeng`, at the namespace root or below it
- **THEN** Nginx SHALL forward the original method, path, query string, headers, and body to the backend

#### Scenario: Legacy dashboard billing request
- **WHEN** a request targets `/dashboard/billing/subscription` or `/dashboard/billing/usage`, with or without the supported trailing slash
- **THEN** Nginx SHALL forward it to the backend

#### Scenario: Dashboard SPA request
- **WHEN** a request targets `/dashboard`, `/dashboard/overview`, or another non-legacy dashboard browser route
- **THEN** Nginx SHALL serve the selected frontend SPA rather than forwarding all of `/dashboard` to the backend

#### Scenario: Mode-prefixed Midjourney API request
- **WHEN** a request matches `/<one-segment>/mj/` followed by a registered Midjourney action root such as `image`, `submit`, `task`, or `insight-face`
- **THEN** Nginx SHALL forward it to the backend

#### Scenario: Non-action mode-prefixed browser route
- **WHEN** a request targets a path such as `/dashboard/mj` without a registered Midjourney action root
- **THEN** Nginx SHALL leave it eligible for static or SPA handling

#### Scenario: OAuth callback route
- **WHEN** a browser returns to `/oauth/<provider>`
- **THEN** Nginx SHALL serve the frontend callback route, whose subsequent `/api/oauth/<provider>` request SHALL be forwarded to the backend

### Requirement: Streaming and upgrade-safe proxying
All backend-owned locations SHALL use proxy behavior compatible with streaming responses, WebSockets, long-running requests, multipart uploads, binary responses, and signed callbacks.

#### Scenario: SSE response
- **WHEN** a backend endpoint emits an SSE response under any owned backend namespace
- **THEN** Nginx SHALL deliver chunks without response buffering, proxy caching, gzip transformation, or error interception

#### Scenario: Realtime WebSocket
- **WHEN** a client upgrades `/v1/realtime` to WebSocket
- **THEN** Nginx SHALL preserve the upgrade, connection, authorization, and subprotocol headers and SHALL keep the connection open for the configured duration

#### Scenario: Large multipart request
- **WHEN** a client uploads a request within the backend's configured body-size limit
- **THEN** Nginx SHALL accept and forward it without imposing a smaller body limit or requiring complete request buffering

#### Scenario: Signed payment callback
- **WHEN** a payment provider sends a callback under `/api`
- **THEN** Nginx SHALL preserve the raw body, signature headers, query parameters, and backend response status

#### Scenario: Authorization-dependent media response
- **WHEN** the backend returns media with public cache headers after authenticating the request
- **THEN** the split deployment SHALL NOT place that response in a shared Nginx cache

### Requirement: Forwarded request trust boundary
The deployment SHALL derive forwarded host, scheme, and client IP values at a trusted edge and SHALL prevent arbitrary client-supplied forwarding headers from controlling backend security decisions.

#### Scenario: Direct Internet request reaches Nginx
- **WHEN** Nginx receives a request without a configured trusted proxy in front of it
- **THEN** it SHALL overwrite forwarded client IP headers using the normalized connection address and SHALL forward the configured external scheme and validated public Host

#### Scenario: Trusted load balancer precedes Nginx
- **WHEN** an operator enables an upstream real-IP configuration
- **THEN** only explicitly configured load-balancer or CDN CIDRs SHALL be trusted before Nginx normalizes and forwards the client address

#### Scenario: Client forges forwarding headers
- **WHEN** an untrusted client supplies `X-Forwarded-For`, `X-Forwarded-Proto`, or related headers
- **THEN** those values SHALL NOT override the deployment-derived forwarding context received by the backend

### Requirement: Static entry rendering and cache policy
The frontend service SHALL render its entry page from the selected immutable build and SHALL apply cache policies that permit immediate deployment upgrades while retaining efficient caching for fingerprinted assets.

#### Scenario: Fingerprinted asset is requested
- **WHEN** a client requests an existing fingerprinted file under `/assets/` or `/static/`
- **THEN** Nginx SHALL serve it with long-lived immutable caching

#### Scenario: Missing fingerprinted asset is requested
- **WHEN** a client requests a nonexistent path under `/assets/` or `/static/`
- **THEN** Nginx SHALL return not found and SHALL NOT return the SPA entry page

#### Scenario: Entry or build metadata is requested
- **WHEN** a client requests `index.html` or frontend build metadata
- **THEN** Nginx SHALL require revalidation or use no-cache semantics

#### Scenario: Root public asset is requested
- **WHEN** a client requests a root-level public file such as `logo.png`, `favicon.ico`, or `robots.txt`
- **THEN** Nginx SHALL avoid an immutable cache policy that could keep the file stale across releases

#### Scenario: Analytics is configured
- **WHEN** supported Umami or Google Analytics environment values are supplied to the frontend container
- **THEN** the served index SHALL contain the corresponding analytics scripts without modifying the immutable source bundle

#### Scenario: Analytics is not configured
- **WHEN** analytics environment values are absent
- **THEN** the served index SHALL make no analytics script request

### Requirement: Canonical URL and secure-session prerequisites
The split deployment SHALL document and validate the configuration needed for backend-generated public URLs, secure browser sessions, passkeys, and same-origin operation.

#### Scenario: Production origin is configured
- **WHEN** an operator deploys the topology to production
- **THEN** the database-backed `ServerAddress` SHALL equal the exact external HTTPS origin without a trailing slash

#### Scenario: Secure session is configured
- **WHEN** the deployment serves HTTPS
- **THEN** the backend SHALL use a stable non-default `SESSION_SECRET`, `SESSION_COOKIE_SECURE=true`, and `SESSION_COOKIE_TRUSTED_URL` containing the public HTTPS origin

#### Scenario: Passkeys are enabled
- **WHEN** an operator enables passkey authentication
- **THEN** Passkey Origins SHALL contain the exact external HTTPS origin and the RP ID SHALL be the external hostname without a port

#### Scenario: Same-origin operation is used
- **WHEN** frontend and backend paths are served through the configured Nginx origin
- **THEN** the deployment SHALL require no new cross-origin CORS or cookie behavior

### Requirement: Theme and release consistency
The split deployment SHALL treat the selected frontend theme and source version as invariants shared with the backend and SHALL detect drift before cutover.

#### Scenario: Frontend and backend agree
- **WHEN** deployment verification reads frontend build metadata and `/api/status`
- **THEN** the selected theme and release version SHALL match

#### Scenario: Theme differs
- **WHEN** the deployed frontend theme differs from the backend `theme.frontend` setting
- **THEN** verification SHALL fail and explain that theme switching requires a coordinated frontend deployment and backend setting update

#### Scenario: Version differs
- **WHEN** frontend and backend source versions differ
- **THEN** verification SHALL fail rather than allowing an unreviewed mixed release

#### Scenario: Operator switches themes
- **WHEN** an operator changes from `classic` to `default` or the reverse
- **THEN** the frontend image and backend theme setting SHALL be changed as one deployment operation

### Requirement: Known LinuxDO incompatibility
The deployment SHALL identify current LinuxDO OAuth callback handling as incompatible with TLS-terminating Nginx unless a separate correction has been applied.

#### Scenario: LinuxDO is disabled
- **WHEN** deployment verification finds LinuxDO login disabled
- **THEN** verification SHALL continue without a LinuxDO compatibility failure

#### Scenario: LinuxDO is enabled without correction
- **WHEN** deployment verification finds LinuxDO login enabled on an uncorrected backend
- **THEN** it SHALL report that LinuxDO login, registration, and account binding may fail and SHALL require explicit operator acknowledgement or block cutover

#### Scenario: Other OAuth callback is used
- **WHEN** GitHub, Discord, OIDC, or a custom provider returns to its frontend callback route
- **THEN** the same-origin Nginx topology SHALL preserve the existing frontend-to-backend callback flow

### Requirement: Upgrade and deployment verification
The overlay SHALL include executable validation for Nginx syntax, path ownership, image metadata, public health, and representative protocol behavior, plus an upgrade checklist for later upstream releases.

#### Scenario: Route contract is tested
- **WHEN** the route-contract test runs against the actual Nginx configuration and marker backend
- **THEN** it SHALL prove backend and SPA path ownership, missing asset behavior, and original path and query preservation

#### Scenario: New upstream root route appears
- **WHEN** an upstream upgrade registers a backend route outside the approved proxy ownership rules
- **THEN** the compatibility review or route classifier SHALL fail until an explicit Nginx ownership decision is recorded

#### Scenario: Pre-cutover verification runs
- **WHEN** the split stack is started for a release
- **THEN** verification SHALL check public frontend availability, `/api/status`, theme and version agreement, representative SPA/API routing, and known incompatibilities before reporting readiness

#### Scenario: Deployment is rolled back
- **WHEN** verification or production behavior requires rollback
- **THEN** operators SHALL be able to restore the unchanged all-in-one service and its coordinated prior theme setting without a database schema rollback
