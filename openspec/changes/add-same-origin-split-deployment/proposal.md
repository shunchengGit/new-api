## Why

The current production artifact always builds and embeds both React frontends into the Go binary, coupling frontend delivery to backend releases even when operators want independent images and scaling. A same-origin Nginx deployment option can separate build and runtime responsibilities without introducing cross-origin authentication complexity or maintaining a long-lived application fork.

## What Changes

- Add an opt-in deployment overlay that builds one selected frontend theme into a static Nginx image and runs the existing backend behind it on a private container network.
- Route the existing management, relay, task, streaming, WebSocket, upload, callback, and legacy API namespaces through the same public origin while preserving frontend SPA fallback behavior.
- Add a backend-only source build option that satisfies the existing `go:embed` contract with placeholder frontend entry files; retain the pinned upstream backend image as the preferred low-maintenance deployment choice.
- Provide deployment configuration for canonical public URLs, secure sessions, proxy headers, upload limits, timeouts, theme alignment, persistent data, and frontend/backend release-version alignment.
- Preserve the existing all-in-one build and deployment path unchanged.
- Document that runtime switching between `default` and `classic` is not supported by a single static frontend deployment and that LinuxDO OAuth remains unsupported in this topology until its callback URI handling is corrected upstream.

## Capabilities

### New Capabilities
- `same-origin-split-deployment`: Build, configure, validate, and operate an independently served frontend and backend behind one Nginx origin.

### Modified Capabilities

None.

## Impact

- Adds deployment-owned Dockerfiles, Nginx configuration, Compose configuration, examples, and validation scripts under an isolated directory.
- Does not change existing API contracts, frontend request code, backend routing, root Dockerfiles, root Compose files, or the default all-in-one release flow.
- Introduces Nginx as the public edge for the optional topology and requires explicit coordination of frontend theme, backend `theme.frontend`, source/image release version, `ServerAddress`, session security, and proxy trust.
- Operators using LinuxDO login, registration, or account binding must remain on a topology where its current callback works or apply a separate upstream OAuth correction before enabling this deployment mode.
