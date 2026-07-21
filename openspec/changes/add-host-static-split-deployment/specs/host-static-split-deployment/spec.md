## ADDED Requirements

### Requirement: Selected-theme static frontend artifact
The split frontend build SHALL export an immutable static artifact containing exactly one selected `default` or `classic` theme, and the same build definition SHALL remain usable for the existing frontend Nginx runtime image.

#### Scenario: Export default theme artifact
- **WHEN** an operator builds the artifact target with `THEME=default`, an application version, and an immutable source revision
- **THEN** the exported artifact SHALL contain the default static distribution and metadata identifying the default theme, application version, and source revision

#### Scenario: Export classic theme artifact
- **WHEN** an operator builds the artifact target with `THEME=classic`, an application version, and an immutable source revision
- **THEN** the exported artifact SHALL contain the classic static distribution and metadata identifying the classic theme, application version, and source revision

#### Scenario: Build existing frontend runtime image
- **WHEN** an operator builds the frontend runtime target from the same theme, version, and revision inputs
- **THEN** the runtime image SHALL serve static files derived from the same artifact-producing build stage rather than rebuilding the frontend through an independent path

#### Scenario: Reject missing or invalid identity input
- **WHEN** the artifact build receives an unsupported theme, missing version, or invalid source revision
- **THEN** the build SHALL fail without producing a release artifact

### Requirement: Artifact identity, licensing, and integrity
Each static frontend artifact SHALL carry machine-readable identity, required project license materials, and deterministic integrity data sufficient to verify the artifact before release rendering.

#### Scenario: Inspect artifact identity
- **WHEN** an operator reads the artifact manifest and public build metadata
- **THEN** both SHALL identify a supported schema, the selected theme, the application version, and the exact source revision without relying on mutable image tags

#### Scenario: Inspect license materials
- **WHEN** an operator inspects an exported artifact
- **THEN** it SHALL include the repository `LICENSE`, `NOTICE`, and `THIRD-PARTY-LICENSES.md` files together with frontend-emitted license files

#### Scenario: Verify pristine artifact
- **WHEN** artifact integrity verification runs before release rendering
- **THEN** every listed file SHALL match the artifact checksum manifest and an unexpected, missing, or modified file SHALL fail verification

#### Scenario: Rebuild equivalent artifact
- **WHEN** equivalent source, lockfile, theme, version, revision, and build-tool inputs are built again
- **THEN** identity and per-file integrity metadata SHALL remain reproducible without depending on a wall-clock build timestamp

### Requirement: Immutable artifact and rendered release separation
The deployment SHALL render a new frontend release from a verified artifact without mutating the artifact or a currently active release.

#### Scenario: Render release without analytics
- **WHEN** a verified artifact is rendered with analytics configuration absent
- **THEN** the new release SHALL contain the static site and SHALL make no analytics script request

#### Scenario: Render release with supported analytics
- **WHEN** a verified artifact is rendered with valid supported analytics settings
- **THEN** only the new release entry page SHALL contain the configured scripts while the source artifact remains byte-for-byte unchanged

#### Scenario: Reject invalid analytics input
- **WHEN** release rendering receives malformed or unsafe analytics values
- **THEN** rendering SHALL fail before the release is eligible for activation

#### Scenario: Render into existing destination
- **WHEN** the requested release destination already contains files
- **THEN** rendering SHALL fail instead of overwriting an existing or active release

### Requirement: Shared route-ownership contract
The container-edge and host-edge adapters SHALL consume one shared definition of backend namespaces, SPA routes, static-file behavior, proxy semantics, and cache policy.

#### Scenario: Backend namespace changes
- **WHEN** an approved backend namespace or root-route exception is changed
- **THEN** the operator SHALL update one shared route contract that is exercised by both adapters

#### Scenario: SPA route is requested
- **WHEN** either adapter receives a browser route that is not backend-owned
- **THEN** it SHALL serve the selected frontend SPA using the shared fallback behavior

#### Scenario: Missing fingerprinted asset is requested
- **WHEN** either adapter receives a request for a nonexistent file under `/assets/` or `/static/`
- **THEN** it SHALL return not found and SHALL NOT return the SPA entry page

#### Scenario: Streaming or upgraded backend route is requested
- **WHEN** either adapter proxies SSE, WebSocket, long-running, upload, media, or signed-callback traffic under a backend-owned route
- **THEN** it SHALL apply the same buffering, caching, request-body, timeout, header, path, query, and response-status contract

### Requirement: Host-managed Nginx adapter
The overlay SHALL provide a host-managed Nginx adapter that serves a rendered static release and proxies backend-owned routes to an operator-supplied private backend while leaving TLS and machine-specific ingress configuration under operator control.

#### Scenario: Integrate adapter into host Nginx
- **WHEN** an operator supplies a canonical host, static release root, private backend endpoint, external scheme, body-size limit, and trusted-proxy policy
- **THEN** the host adapter SHALL produce syntax-valid HTTP-level and server-level include files around the shared route contract without requiring Docker DNS, container filesystem paths, or generated listener and TLS directives

#### Scenario: Serve browser and API traffic from one origin
- **WHEN** a browser loads the host-served frontend and issues root-relative API requests
- **THEN** all browser-visible requests SHALL remain on the same scheme, host, and port while backend requests are forwarded internally

#### Scenario: Backend is private
- **WHEN** the host adapter is rendered
- **THEN** it SHALL accept only `localhost` or a loopback/RFC1918 IPv4 literal with an explicit port and SHALL reject public DNS names, public IP addresses, and configurations that define a public backend listener

#### Scenario: Unknown host is supplied
- **WHEN** a request reaches the host adapter with a Host value outside its configured canonical host
- **THEN** the adapter SHALL reject the request rather than forwarding attacker-controlled host context

#### Scenario: TLS is host-owned
- **WHEN** an operator integrates the adapter into an existing host Nginx installation
- **THEN** the overlay SHALL NOT emit a listener or replace or invent certificate paths, DNS names, access-log destinations, or machine-specific TLS policy

### Requirement: Dual-adapter contract validation
Executable validation SHALL apply the same behavioral assertions to the existing frontend-container adapter and the new host-static adapter.

#### Scenario: Container adapter contract runs
- **WHEN** the route-contract suite selects the container adapter
- **THEN** it SHALL validate the rendered container Nginx configuration against the shared marker backend and static fixture

#### Scenario: Host adapter contract runs
- **WHEN** the route-contract suite selects the host adapter
- **THEN** it SHALL validate the rendered host Nginx configuration against the same marker backend, static fixture, and assertion set

#### Scenario: Adapter behavior drifts
- **WHEN** either adapter changes API/SPA ownership, forwarding headers, cache behavior, SSE delivery, WebSocket upgrade, callback preservation, upload handling, or unknown-Host behavior
- **THEN** the shared contract suite SHALL fail until the divergence is explicitly reconciled

#### Scenario: Required test dependency is unavailable in CI
- **WHEN** CI cannot execute the Nginx or Docker-backed contract suite
- **THEN** the job SHALL fail or remain explicitly unverified and SHALL NOT report a passing deployment contract

### Requirement: Release verification and atomic activation
The host-static deployment SHALL verify artifact integrity and frontend/backend compatibility before activation, switch releases atomically, and retain a reversible prior release.

#### Scenario: Verify release candidate
- **WHEN** pre-cutover verification runs for a rendered host release
- **THEN** it SHALL verify artifact checksums, release exact-entry provenance, selected theme, application version, source-revision format, and backend status through the running candidate listener, and SHALL bind that listener to the syntax-checked complete configuration and generated server include with a fresh deployment challenge

#### Scenario: Unrelated healthy service is supplied
- **WHEN** the syntax-checked configuration, generated binding include, and candidate listener do not expose the same deployment challenge
- **THEN** verification SHALL fail even if the supplied URL returns otherwise valid frontend and backend health responses

#### Scenario: Frontend and backend disagree
- **WHEN** the frontend theme or application version differs from `/api/status`
- **THEN** verification SHALL fail before activation

#### Scenario: Activate verified release
- **WHEN** a rendered release and private backend pass required validation
- **THEN** the operator SHALL be able to atomically direct the host static root to that immutable release without modifying its files in place

#### Scenario: Roll back host-static release
- **WHEN** verification or production behavior requires rollback
- **THEN** the operator SHALL be able to atomically restore the retained prior frontend release and compatible backend release tuple without a database schema rollback introduced by this capability

### Requirement: Immutable runtime image references
The container-edge deployment SHALL require immutable `name@sha256:<64-hex-digest>` references for frontend, backend, PostgreSQL, and Redis runtime images and SHALL reject mutable tags before startup.

#### Scenario: All runtime images are pinned
- **WHEN** an operator renders the production Compose configuration with four digest-qualified image references
- **THEN** image verification SHALL pass and Compose MAY pull and start those exact manifests

#### Scenario: A mutable or malformed image is supplied
- **WHEN** any required runtime service uses a tag, omits its digest, or uses a malformed digest
- **THEN** image verification SHALL fail before the stack is started

### Requirement: Additive compatibility boundary
The host-static adapter SHALL extend the existing same-origin split overlay without changing application routing, browser API URLs, authentication semantics, or the default all-in-one deployment.

#### Scenario: Existing frontend container is used
- **WHEN** an operator continues to select the existing frontend Nginx container deployment
- **THEN** it SHALL remain supported and SHALL consume the shared artifact and route-contract foundations

#### Scenario: Existing all-in-one deployment is used
- **WHEN** an operator does not select either split adapter
- **THEN** the frontend-embedded backend build and deployment SHALL continue without depending on the host-static capability

#### Scenario: Cross-origin topology is requested
- **WHEN** an operator attempts to place browser-visible frontend and API requests on different origins
- **THEN** the capability SHALL identify that topology as unsupported and SHALL NOT weaken CORS, session-cookie, OAuth, or Passkey behavior to accommodate it

#### Scenario: Unrelated split changes are considered
- **WHEN** optional Redis support or LinuxDO OAuth correction is required
- **THEN** those changes SHALL remain separate from this capability and SHALL NOT be introduced as hidden prerequisites
