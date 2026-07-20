# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

@AGENTS.md

`AGENTS.md` is authoritative for project-wide conventions. `web/default/AGENTS.md` adds rules for the default frontend.

## Commands

### Backend

```bash
# Build both frontend themes, then run the API
make all

# Run after web/default/dist and web/classic/dist already exist
make start-api
go run main.go

# Run all Go tests
go test ./...

# Run a package or one test
go test ./router
go test ./router -run '^TestChannelStatusRoutesUseOperatePermission$'
```

`main.go` embeds both frontend `dist` directories, so a clean checkout requires `make build-all-web` before `go run`, `go build`, or `go test ./...` (which compiles the root package). Focused tests for other packages do not require that step. The repository has no configured Go lint command.

### Frontend

Dependencies are managed by the Bun workspace rooted at `web/`:

```bash
cd web && bun install --frozen-lockfile

# Default theme
cd web/default
bun run dev
bun run typecheck
bun run lint
bun run format:check
bun run build:check
bun run i18n:sync

# Classic theme
cd web/classic
bun run dev
bun run lint
bun run eslint
bun run build
bun run i18n:sync
```

The root `web/package.json` has no scripts. Run scripts inside the selected theme. Neither theme defines a test script; classic also has no typecheck script.

For the containerized development backend and a separate default frontend:

```bash
make dev-api
make dev-web
make dev-api-rebuild  # after backend dependency or image changes
```

### Production build

```bash
make build-all-web
go build -ldflags "-s -w -X 'github.com/QuantumNous/new-api/common.Version=$(cat VERSION)'" -o new-api

docker compose up -d
docker compose -f docker-compose.dev.yml up -d --build
```

## Architecture

The application is a single Go/Gin gateway with two independently developed React frontends. The production build compiles `web/default` and `web/classic`, embeds both `dist` trees into the Go binary, and selects the served theme at runtime. Development commonly runs the frontend dev server separately and proxies API paths to port 3000.

Backend requests follow `router -> controller -> service -> model`. Startup in `main.go` initializes settings, primary and optional log databases, Redis and in-memory caches, OAuth, scheduled tasks, middleware, and route groups. `router/main.go` registers management APIs, dashboard endpoints, relay APIs, video/task APIs, then static frontend handling.

Relay traffic has a longer cross-layer pipeline: protocol validation and normalization, relay metadata and token estimation, pricing and quota pre-consumption, cached channel selection, provider-specific request conversion and transport, streamed or non-streamed response conversion, then settlement/refund and retry handling. Standard provider adapters implement `relay/channel.Adaptor` and are dispatched by `relay.GetAdaptor`; asynchronous task providers implement `TaskAdaptor` and are dispatched separately.

The primary database supports SQLite, MySQL, and PostgreSQL; the log database may be separate. Schema migrations and some background synchronization are master-node responsibilities, while channel selection relies on refreshed cache state. Database and billing changes must follow the compatibility and quota-safety rules imported from `AGENTS.md`.