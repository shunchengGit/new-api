## Context

The completed `add-same-origin-split-deployment` overlay builds a selected frontend theme into an unprivileged Nginx image and places the existing Go backend on a private Compose network. It deliberately keeps application code unchanged, retains placeholder `go:embed` inputs in the backend-only build, and relies on one browser origin so root-relative API requests, strict session cookies, OAuth callbacks, Passkeys, and generated URLs keep their existing semantics.

That overlay currently has one frontend runtime: its Nginx container. The selected frontend distribution, analytics rendering, Docker-specific Nginx resolver, complete Nginx process configuration, and shared path-ownership rules are coupled in `Dockerfile.frontend`, `render-index.sh`, and `nginx.conf.template`. Operators that already terminate TLS and own ingress in host Nginx therefore cannot consume a formally defined static artifact without copying build output and maintaining a second route list outside the repository.

This change adds a host-static adapter while preserving the container adapter and all-in-one deployment. It remains an additive deployment-layer change under `deploy/split/`; it does not redesign the Go web router or authentication behavior.

## Goals / Non-Goals

**Goals:**

- Export one immutable, independently verifiable static artifact for a selected `default` or `classic` theme.
- Build the existing frontend Nginx runtime from the same artifact-producing stage.
- Let a host-managed Nginx serve a rendered release while proxying the backend privately on the same public origin.
- Maintain one shared path-ownership and proxy contract across container and host adapters.
- Keep source artifact, rendered release, active release pointer, and deployment tuple distinct and verifiable.
- Exercise both adapters with the same route, security-header, cache, SSE, WebSocket, callback, and upload assertions.
- Preserve licenses, attribution materials, immutable version identity, and later-upstream upgrade reviewability.

**Non-Goals:**

- Supporting browser-visible frontend and API requests on different origins or below a URL subpath.
- Removing Go `embed` declarations, `SetWebRouter`, or placeholder frontend files from the backend-only build.
- Replacing host TLS, DNS, certificate, request-ID, access-log, or trusted-proxy policy.
- Changing frontend API base URLs, CORS, session cookies, OAuth, Passkeys, payment behavior, or database schema.
- Making Redis optional or correcting LinuxDO OAuth callback handling.
- Publishing artifacts to a registry or release service as part of the first implementation; CI will prove buildability and integrity, while publication remains a later release-policy decision.

## Decisions

### 1. Extend the existing frontend Dockerfile with an artifact stage

`deploy/split/Dockerfile.frontend` will retain a single Bun builder and add a normalized artifact-producing stage before the existing Nginx runtime stage. The build accepts validated `THEME=default|classic`, `APP_VERSION`, and `VCS_REF`; `VCS_REF` is an exact immutable source revision rather than a branch name. The artifact stage contains the selected static distribution, public `build-info.json`, an operator manifest, checksum data, and license materials. The Nginx runtime copies its pristine static source from this stage.

BuildKit output can export the artifact target to a local directory or archive, while a normal image build selects the runtime target. Both paths therefore use the same dependency installation and frontend compilation.

Alternative considered: add a separate shell-only frontend build script and leave the Dockerfile unchanged. That would duplicate Bun installation, platform, and output-normalization assumptions between local artifact builds and container images. One multi-stage Dockerfile keeps the build environment and selected-theme behavior aligned.

Alternative considered: package both themes in one artifact. Static Nginx cannot safely select the database-backed theme at request time, asset names may collide, and the completed split design already treats theme switching as an atomic release operation. Each artifact therefore contains exactly one theme.

### 2. Use two metadata surfaces with stable, reproducible fields

The public site includes `build-info.json` with a schema number, application version, selected theme, and exact source revision. Deployment verification can fetch it through the canonical public origin.

The artifact root also includes an operator-facing manifest describing the artifact schema, application identity, theme, version, revision, compatible backend version, and frontend lockfile checksum. It does not include wall-clock build time, builder hostname, or mutable tag names. Integrity data records deterministic checksums for artifact files. The outer archive digest remains a release-system concern because embedding an archive's own digest inside itself is recursive.

Alternative considered: add the Git revision to `/api/status` and require an exact frontend/backend commit comparison. This would change the application API and prevents use of an otherwise compatible pinned backend image that reports the same application release. The deployment tuple records the backend image digest separately; public compatibility remains version and theme based.

### 3. Preserve and verify license material inside the portable artifact

The artifact includes root `LICENSE`, `NOTICE`, and `THIRD-PARTY-LICENSES.md`, plus license files emitted by the selected frontend build. The container runtime also retains these files in a stable license directory. Integrity generation covers them alongside the static distribution.

This makes the artifact self-describing when it is exported outside an image and avoids relying on repository access at deployment time. Public attribution behavior remains unchanged and is not removed or rewritten.

### 4. Separate pristine artifact verification from release rendering

The exported artifact is immutable input. A release renderer first validates metadata and all checksums, rejects a non-empty destination, copies the selected site into a new release directory, and then renders the entry page for supported analytics configuration. It never writes into the artifact and never edits the active release.

The existing frontend container entrypoint will invoke the same release-rendering behavior into its writable runtime directory before rendering its container Nginx configuration. A host deployment invokes it into a release directory managed by the operator. Unsupported or unsafe analytics values fail before activation.

Alternative considered: bake analytics into the artifact. That would require rebuilding otherwise identical artifacts for environment-specific analytics and would not preserve the existing runtime configuration behavior. Separating artifact and release keeps the source build immutable while making environment rendering explicit.

Alternative considered: have Nginx substitute analytics into responses. Response substitution complicates CSP, caching, streaming filters, and byte integrity. Rendering one release entry file is simpler and auditable.

### 5. Extract shared route locations from runtime-specific Nginx shells

Backend namespaces, exact legacy routes, constrained mode-prefixed Midjourney routes, static resource rules, SPA fallback, cache policy, and the shared proxy include become one route-ownership template or generated include under `deploy/split/nginx/`.

Two thin shells consume it:

- The container shell owns unprivileged listen settings, Docker DNS re-resolution, container temporary paths, and the runtime static root.
- The host adapter owns no listener, certificates, or concrete domains. It emits one `http`-level WebSocket prerequisite include and one `server`-level application include accepting a canonical host, external scheme, release root, private backend upstream, body-size limit, and a trusted-real-IP include supplied by the operator.

The host adapter is intended to be included inside an existing operator-owned host Nginx `http` context and TLS `server` block. It does not install Nginx, emit `listen` directives, replace the global `http` block, create certificates, or write machine-specific logging configuration. This prevents a generated host adapter from accidentally serving plaintext on a port that the operator intended for TLS.

Alternative considered: document how to copy the current locations manually into host Nginx. That creates two independently maintained route lists and makes later upstream root-route changes unsafe. A shared generated/include contract is mandatory.

Alternative considered: proxy all requests to the backend and fall back on 404. The backend NoRoute behavior serves embedded SPA HTML, including placeholder HTML in the backend-only image, so it cannot provide a reliable ownership signal.

### 6. Keep the host backend endpoint operator-supplied and private

The generic host adapter accepts only `localhost` or a loopback/RFC1918 IPv4 literal with an explicit port. It rejects public DNS names and public IP addresses and prohibits defining a public backend listener. Unknown Host values are rejected, and forwarding headers are derived at the trusted edge rather than appended from client input.

The adapter passes a configured external scheme because TLS may terminate in host Nginx or at a separately trusted load balancer. Trusted CDN/load-balancer addresses remain an explicit operator-supplied real-IP policy; the template never trusts arbitrary forwarding headers.

Alternative considered: accept any HTTP(S) hostname and rely on documentation to require privacy. That cannot enforce the private-backend invariant and allows accidental public bypass paths. This adapter therefore supports the common loopback/RFC1918 cases; Unix sockets or private DNS require a separately reviewed adapter.

### 7. Reuse one test vector set for both adapters

The existing marker backend, static fixture, and assertions are retained. The route-contract harness renders each adapter into an isolated temporary configuration and runs the same assertions for fixed namespaces, exact route exceptions, SPA routes, missing assets, cache headers, raw body and signature preservation, normalized forwarding headers, unknown Host rejection, immediate SSE delivery, WebSocket upgrade/subprotocol behavior, and allowed uploads.

Adapter-specific setup is limited to rendering and starting the Nginx shell. Assertions are not copied into two scripts. CI treats a missing Docker/Nginx capability as failure or explicitly unverified, never as a passing contract.

`check-route-ownership.sh` remains the conservative application-route review gate. Dynamic root registrations require an explicit allowlist or a failing review outcome; changes to approved root exceptions must be reflected in the shared route contract and tests.

### 8. Preserve separate compatibility and integrity checks

Public deployment verification continues to compare frontend version and theme with `/api/status` and confirm SPA/API separation. It additionally validates the build-info schema and source-revision format, missing-asset behavior, and mutable-entry cache behavior. Host pre-cutover verification binds the syntax-checked complete Nginx config, its generated server include, and the running candidate listener with a fresh 64-hex deployment challenge; the gate rejects a healthy old service or unrelated configuration.

Artifact verification is a local precondition and checks the operator manifest plus per-file checksums. It is not inferred from a public HTTP response. The deployment record keeps the complete release tuple:

```text
frontend artifact digest
frontend version, theme, and source revision
rendered release identifier
backend image digest
backend reported version and configured theme
previous compatible tuple
```

LinuxDO incompatibility handling remains as currently documented. This change neither repairs nor weakens it.

### 9. Use immutable release directories and an atomic pointer

A host deployment extracts/renders each release into a new immutable directory and activates it by atomically switching a host-managed pointer, such as a symlink, after Nginx syntax and public preflight checks pass. The repository provides the release contract and examples but does not prescribe an absolute filesystem path.

Rollback switches the pointer to a retained prior frontend release and restores the compatible prior backend image/theme tuple when those changed. This capability introduces no database migration.

Alternative considered: copy new files over the active web root. Partial uploads can mix old HTML with new chunks, overwrite rollback material, and make integrity validation meaningless. In-place release updates are unsupported.

### 10. Keep the change additive and deployment-owned

Implementation remains under `deploy/split/` plus the minimal CI workflow needed to validate the overlay and its OpenSpec artifacts. Existing root Dockerfiles, root Compose files, application source, frontend request code, and all-in-one release flow remain unchanged.

The completed container split remains supported. Its runtime configuration will be refactored to consume the shared artifact and route foundations without changing its public behavior.

## Risks / Trade-offs

- **[Shared Nginx snippets are difficult to parameterize safely]** → Render into a temporary directory, validate constrained inputs, run `nginx -t`, and test the actual rendered configurations for both adapters.
- **[Refactoring the existing container template changes working behavior]** → Run the current full route contract against the container adapter before and after extraction, using identical assertions.
- **[Artifact reproducibility is affected by frontend tooling]** → Pin the Bun builder image and lockfile, omit timestamps and host data from manifests, normalize generated metadata, and compare per-file checksums rather than promising byte-identical outer tar archives across tools.
- **[A host operator exposes the backend accidentally]** → Keep public-listener creation outside the adapter, document private reachability as mandatory, inspect supplied deployment configuration, and include direct-access review in preflight; the repository cannot enforce an external firewall by itself.
- **[Artifact checksum files are themselves incomplete or recursive]** → Define exactly which roots are covered, exclude the checksum file from its own entries, and rely on the separately recorded outer artifact digest to authenticate the full package.
- **[Runtime analytics rendering invalidates artifact checksums]** → Verify the pristine artifact first, render into a distinct release, and record the source artifact digest with the release identifier rather than claiming rendered files equal source checksums.
- **[Host Nginx versions differ from the pinned container image]** → Document a minimum supported Nginx feature set, require `nginx -t`, and run host-adapter fixtures against the pinned CI version; production remains subject to operator version verification.
- **[A new upstream root route is served as SPA]** → Strengthen route ownership review, fail dynamic unclassified root registrations, and require both adapter contracts during upgrades.
- **[Frontend and backend use different commits with the same release string]** → Record exact frontend revision and backend image digest in the release tuple; version/theme remain the application compatibility gate unless a future application contract exposes backend revision.
- **[Additional CI builds increase runtime]** → Share build stages and caches, build both themes deliberately, and keep protocol tests fixture-based rather than invoking paid upstream model requests.

## Migration Plan

1. Build and test the enhanced frontend Dockerfile for `default` and `classic`, exporting each artifact and building the existing frontend Nginx runtime from the same stages.
2. Verify manifests, licenses, and per-file checksums; retain the previous frontend container image and all-in-one image as rollback inputs.
3. Extract the shared route contract and run the complete existing contract suite against the refactored container adapter until behavior is unchanged.
4. Render the host adapter with disposable fixture values, run `nginx -t`, and execute the same contract suite against the same marker backend and frontend fixture.
5. In staging, render a new host static release from a verified artifact, configure the host-owned TLS/Host/real-IP shell, and point it at a private backend built from the compatible release.
6. Confirm `ServerAddress`, selected backend theme, secure session settings, and Passkey settings remain aligned with the one public origin; run public preflight and the documented manual authentication/protocol smoke tests.
7. Activate the static release pointer atomically only after validation. Retain the prior release directory, frontend container image, backend image digest, prior theme setting, and prior ingress configuration.
8. Roll back by restoring the prior pointer and compatible backend/theme tuple, or by returning traffic to the unchanged frontend-container/all-in-one deployment. No database schema rollback is required by this change.

## Open Questions

- Whether the first implementation exports a directory only or also supplies a canonical tar format; directory export is sufficient for BuildKit and avoids prematurely standardizing archive tooling.
- Whether host Nginx support should target a minimum upstream Nginx version matching the pinned container runtime or a more conservative distribution version; required directives must be tested before the minimum is documented.
- Whether artifact publication, SBOM generation, provenance, and signing should be added to the existing release workflows now or proposed separately after local/CI artifact contracts are stable.
- Whether the existing completed split change should be archived before this delta is archived so the host-static capability can reference a main `same-origin-split-deployment` specification rather than only its predecessor change artifacts.
