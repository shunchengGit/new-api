## 1. Deployment Overlay Structure

- [x] 1.1 Create the isolated `deploy/split/` directory structure without modifying existing application, root Docker, Compose, Make, or release files
- [x] 1.2 Add a production-oriented `.env.example` with immutable image/version inputs, selected theme, public host/scheme, backend limits, session settings, database/Redis settings, analytics settings, and LinuxDO acknowledgement
- [x] 1.3 Add operator documentation covering prerequisites, root build context, supported topology, configuration ownership, and the unchanged all-in-one alternative

## 2. Independent Container Builds

- [x] 2.1 Implement `Dockerfile.backend` using placeholder embed entry files and the existing backend linker version, runtime packages, licenses, workdir, entrypoint, and multi-architecture arguments
- [x] 2.2 Implement `Dockerfile.frontend` using the Bun workspace lockfile, validated `default|classic` theme selection, exact source version injection, and a pinned unprivileged Nginx runtime
- [x] 2.3 Generate frontend `build-info.json` with selected theme and source version and fail the build for unsupported or missing build arguments
- [x] 2.4 Verify the backend image builds without Bun/frontend compilation and both theme-specific frontend images build from the same source revision
- [x] 2.5 Add documented commands for using either the source-built backend or an operator-supplied backend image pinned by immutable tag or digest

## 3. Nginx Edge and Route Ownership

- [x] 3.1 Implement the Nginx template with public-host rejection, static root, no-cache SPA entry fallback, and strict missing-file behavior for `/assets/`
- [x] 3.2 Add shared backend proxy settings that preserve method/path/query/body/signature/authorization headers, normalize Host and forwarding headers, disable buffering/caching/error interception, and configure upload and long-lived connection limits
- [x] 3.3 Proxy exact roots and descendants for `/api`, `/v1`, `/v1beta`, `/pg`, `/mj`, `/suno`, `/kling`, and `/jimeng`
- [x] 3.4 Proxy only the exact legacy `/dashboard/billing/subscription` and `/dashboard/billing/usage` APIs while leaving all other `/dashboard` routes to the SPA
- [x] 3.5 Add constrained mode-prefixed Midjourney routing for the registered `image`, `submit`, `task`, and `insight-face` action roots without reserving generic `/<segment>/mj` SPA paths
- [x] 3.6 Preserve WebSocket upgrade and subprotocol behavior for `/v1/realtime` and streaming behavior for both relay and management SSE endpoints
- [x] 3.7 Add optional trusted-CDN/load-balancer real-IP configuration that trusts only explicit CIDRs and otherwise overwrites untrusted forwarding headers

## 4. Frontend Runtime Entry and Caching

- [x] 4.1 Implement a frontend entrypoint renderer that copies the immutable index template to writable runtime storage
- [x] 4.2 Render Umami and Google Analytics placeholders from the existing environment variable names with safe escaping and no external script when unset
- [x] 4.3 Configure immutable caching only for fingerprinted `/assets/` files and revalidation/no-cache behavior for `index.html`, build metadata, and root public assets
- [x] 4.4 Run the frontend container with a read-only root filesystem and only the minimum writable runtime paths required by Nginx and index rendering

## 5. Compose Topology and Operational Invariants

- [x] 5.1 Add `compose.yaml` with Nginx as the only published service, backend/database/Redis on private networks, persistent backend data/log storage, health checks, and shutdown grace compatible with long streams
- [x] 5.2 Support coordinated selection of one frontend theme and either the source-built backend or a pinned supplied backend image without using `latest`
- [x] 5.3 Document and validate the database-backed `ServerAddress`, `theme.frontend`, stable `SESSION_SECRET`, secure-cookie variables, body-size alignment, and explicit Passkey Origin/RP ID prerequisites
- [x] 5.4 Document the atomic theme switch and rollback procedure so frontend image selection and backend `theme.frontend` cannot be changed independently
- [x] 5.5 Document that direct backend port publishing, untrusted forwarding-header passthrough, different browser origins, and subpath mounting are unsupported

## 6. Contract and Security Validation

- [x] 6.1 Add an Nginx route-contract test harness with marker backend and static fixtures that validates fixed API prefixes, exact dashboard exceptions, constrained Midjourney mode routes, SPA callbacks, missing assets, and path/query preservation
- [x] 6.2 Add tests proving forged forwarding headers are overwritten, unknown hosts are rejected, and the backend has no public Compose port
- [x] 6.3 Add streaming tests for immediate SSE delivery under `/v1` and `/api`, WebSocket upgrade/subprotocol forwarding, and long timeout behavior
- [x] 6.4 Add request/response tests for permitted large multipart uploads, signed callback body/header preservation, and absence of shared caching for authorization-dependent media
- [x] 6.5 Add static tests for cache headers, runtime analytics injection when configured, and no analytics request when configuration is absent
- [x] 6.6 Add an upstream route classifier or review script that fails when Gin registers a root backend route outside the approved fixed prefixes and explicit exceptions

## 7. Deployment Preflight and Upgrade Workflow

- [x] 7.1 Implement `verify-deployment.sh` to check public frontend health, `/api/status`, SPA/API routing separation, frontend/backend version agreement, and frontend/backend theme agreement
- [x] 7.2 Detect enabled LinuxDO OAuth and block readiness or require explicit acknowledgement with a message covering affected login, registration, and account-binding functions
- [x] 7.3 Add manual smoke-test guidance for login/session cookies, GitHub/Discord/OIDC/custom OAuth, Passkeys, uploads, SSE, realtime WebSocket, payment callbacks, and generated public URLs
- [x] 7.4 Add an upstream upgrade checklist comparing backend runtime image details, rerunning route classification and Nginx contract tests, rebuilding both theme images, and verifying matching immutable versions
- [x] 7.5 Validate rollback to the unchanged all-in-one deployment without a database schema change and record the required prior theme-setting restoration

## 8. Final Verification

- [x] 8.1 Run Dockerfile lint/build checks and build the backend plus both frontend theme images on supported architectures or equivalent Buildx validation
- [x] 8.2 Run `nginx -t`, the complete route/security/protocol contract suite, and deployment preflight against disposable marker services
- [x] 8.3 Confirm repository diff contains only the OpenSpec artifacts and additive `deploy/split/` implementation files, with existing product and deployment files unchanged
