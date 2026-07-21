## Why

The existing same-origin split overlay requires the frontend to run inside its own Nginx container, so operators that already own TLS and ingress in a host-managed Nginx cannot deploy the independently built frontend as a verified static release without duplicating build logic and route ownership. Adding a host-static adapter now preserves the established same-origin security model while making the split frontend usable in both container-edge and host-edge deployments.

## What Changes

- Extend the selected-theme frontend build to export an immutable static artifact for either `default` or `classic`, including release metadata, license files, and integrity checksums.
- Preserve the existing frontend Nginx container as a supported adapter while adding a host-managed Nginx adapter that consumes the same artifact.
- Extract one shared backend/SPA path-ownership contract so container and host adapters cannot maintain divergent route lists.
- Separate immutable frontend build output from release-time index rendering, allowing analytics injection into a new release directory without modifying the source artifact.
- Run the same route, forwarding-header, cache, SSE, WebSocket, callback, and upload contract suite against both adapters.
- Extend deployment verification and CI to validate artifact integrity, selected theme, application version, source revision, and both adapter modes.
- Keep the backend private, keep all browser-visible requests on one origin, and leave the existing all-in-one build and deployment unchanged.
- Do not add cross-origin frontend support, change application authentication or API behavior, make Redis optional, or correct LinuxDO OAuth in this change.

## Capabilities

### New Capabilities
- `host-static-split-deployment`: Build, verify, release, serve, and roll back a selected-theme static frontend artifact through a host-managed Nginx while sharing the existing same-origin split routing contract.

### Modified Capabilities

None.

## Impact

- Affects the additive `deploy/split/` Dockerfiles, scripts, Nginx templates, tests, deployment verifier, Compose-facing frontend adapter, and operator documentation.
- Adds CI validation for both selected frontend themes, artifact integrity, and container/host route contracts.
- Does not change Go application routing, frontend request URLs, database schema, API contracts, session cookies, CORS, OAuth, Passkeys, root Dockerfiles, root Compose files, or the default all-in-one release path.
- Host deployments must supply their own TLS, canonical host, trusted-proxy configuration, static release root, and private backend endpoint around the shared route contract.
