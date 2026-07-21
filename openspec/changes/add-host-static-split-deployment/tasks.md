## 1. Artifact Contract and Build Stages

- [x] 1.1 Define the static artifact directory layout and constrained `THEME`, `APP_VERSION`, and exact `VCS_REF` inputs under `deploy/split/`
- [x] 1.2 Refactor `deploy/split/Dockerfile.frontend` so one selected-theme Bun build feeds both an exportable artifact target and the existing unprivileged Nginx runtime target
- [x] 1.3 Generate reproducible public build metadata and an operator artifact manifest containing schema, application version, theme, source revision, compatible backend version, and lockfile identity without wall-clock fields
- [x] 1.4 Package `LICENSE`, `NOTICE`, `THIRD-PARTY-LICENSES.md`, and selected-theme emitted license files into both the portable artifact and frontend runtime image
- [x] 1.5 Generate and verify deterministic per-file checksums for the defined artifact roots, rejecting missing, changed, or unexpected files
- [x] 1.6 Build and inspect `default` and `classic` artifacts plus runtime images, and confirm invalid theme/version/revision inputs fail without usable output

## 2. Immutable Release Rendering

- [x] 2.1 Extract frontend release rendering from the current combined entrypoint so artifact verification, site copying, analytics rendering, and Nginx configuration rendering have explicit boundaries
- [x] 2.2 Implement rendering from a verified artifact into a new empty release directory without mutating the artifact or overwriting an existing destination
- [x] 2.3 Preserve safe Umami and Google Analytics validation/injection and prove absent configuration emits no analytics request
- [x] 2.4 Update the frontend container entrypoint to render its runtime release through the shared renderer while retaining a read-only root filesystem and minimal writable paths
- [x] 2.5 Add deterministic fixture tests for valid rendering, invalid analytics values, checksum failure, non-empty destinations, and unchanged source artifact bytes

## 3. Shared Nginx Route Contract

- [x] 3.1 Extract backend namespaces, exact dashboard exceptions, constrained mode-prefixed Midjourney routes, static-file rules, SPA fallback, and cache policy into one shared route-ownership template/include
- [x] 3.2 Refactor the container Nginx shell to consume the shared route contract while retaining Docker DNS re-resolution, unprivileged listen behavior, runtime paths, Host enforcement, and normalized forwarding headers
- [x] 3.3 Keep streaming-safe shared proxy settings for methods, paths, queries, bodies, signature and authorization headers, SSE, WebSocket subprotocols, uploads, media, timeouts, and response statuses
- [x] 3.4 Strengthen `check-route-ownership.sh` so unclassified dynamic root registrations fail unless explicitly allowed and root-route exceptions remain synchronized with contract tests
- [x] 3.5 Run the existing container route-contract assertions after the extraction and confirm no public behavior regresses

## 4. Host-Managed Nginx Adapter

- [x] 4.1 Add host Nginx HTTP/server include templates that accept a canonical host, external scheme, rendered release root, private backend endpoint, body-size limit, and operator-supplied trusted-real-IP policy without emitting listener or TLS directives
- [x] 4.2 Keep Docker resolver, container filesystem paths, concrete domains, certificate paths, machine logs, and deployment-specific backend addresses out of the host adapter
- [x] 4.3 Validate and safely render all host adapter inputs into a temporary configuration without trusting client-supplied forwarding headers
- [x] 4.4 Add a disposable host-adapter fixture that passes `nginx -t`, serves the rendered static release, rejects unknown Hosts, and proxies only through the supplied private backend
- [x] 4.5 Document integration into an existing host Nginx `http`/`server` configuration without creating a public backend listener or replacing host-owned TLS and ingress policy

## 5. Dual-Adapter Behavioral Validation

- [x] 5.1 Refactor `route-contract.sh` so container and host adapters share one marker backend, static fixture, and assertion set rather than duplicated tests
- [x] 5.2 Execute fixed API namespaces, exact legacy billing routes, constrained Midjourney routes, SPA callbacks, missing assets, path/query/body/signature preservation, cache headers, and unknown-Host assertions against both adapters
- [x] 5.3 Execute forged forwarding-header rejection, immediate `/api` and `/v1` SSE delivery, WebSocket upgrade/subprotocol forwarding, and allowed upload assertions against both adapters
- [x] 5.4 Add negative tests proving an adapter route-list drift or unsafe proxy/cache setting fails the common contract
- [x] 5.5 Ensure missing Docker/Nginx prerequisites cannot produce a passing CI contract result and document local `SKIP` output as unverified rather than successful

## 6. Preflight, Activation, and Rollback

- [x] 6.1 Extend deployment preflight to validate public build-info schema and revision format, SPA/API separation, missing-asset 404 behavior, mutable-entry cache policy, and frontend/backend version/theme agreement
- [x] 6.2 Add a host release verification command that validates the pristine artifact, rendered release provenance, Nginx syntax, and canonical public-origin responses before activation
- [x] 6.3 Define and document the release tuple containing frontend artifact digest, frontend identity, rendered release identifier, backend image digest, backend version/theme, and prior compatible tuple
- [x] 6.4 Document atomic activation through a host-managed release pointer and rollback to the retained prior frontend plus compatible backend/theme tuple without in-place file replacement
- [x] 6.5 Update the split deployment README to distinguish container-edge and host-static adapters, retain the same-origin/private-backend boundary, and keep LinuxDO OAuth and optional Redis explicitly outside this change

## 7. Continuous Integration and Final Verification

- [x] 7.1 Add CI shell/static validation for all new renderers, manifests, checksum rules, Nginx templates, and route-ownership checks
- [x] 7.2 Add CI builds for backend-only, `default` artifact/runtime, and `classic` artifact/runtime targets using pinned build inputs and available caches
- [x] 7.3 Run both adapter route-contract modes and release-rendering fixtures in CI with failures or explicit non-passing status when required runtime dependencies are unavailable
- [x] 7.4 Run the repository-required frontend checks for both selected themes and relevant Go tests without changing application behavior
- [x] 7.5 Perform a disposable end-to-end host-static deployment verification, record exact commands and outcomes, and confirm the existing frontend-container and all-in-one paths remain available
- [x] 7.6 Review the final diff for deployment-only scope, preserved protected branding/attribution, no secrets or environment-specific domains, and no hidden Redis, LinuxDO, CORS, cookie, OAuth, Passkey, database, or API changes
