# CLAUDE.md

## Project Snapshot

T3 Code is a minimal web GUI for using code agents like Codex and Claude Code (coming soon).

This repository is a VERY EARLY WIP. Proposing sweeping changes that improve long-term maintainability is encouraged.

## Core Priorities

1. Performance first.
2. Reliability first.
3. Keep behavior predictable under load and during failures (session restarts, reconnects, partial streams).

If a tradeoff is required, choose correctness and robustness over short-term convenience.

## Package Roles

- `apps/server`: Node.js WebSocket server. Wraps Codex app-server (JSON-RPC over stdio), serves the React web app, and manages provider sessions.
- `apps/web`: React/Vite UI. Owns session UX, conversation/event rendering, and client-side state. Connects to the server via WebSocket.
- `packages/contracts`: Shared Zod schemas and TypeScript contracts for provider events, WebSocket protocol, and model/session types.

## Codex App Server (Important)

T3 Code is currently Codex-first. The server starts `codex app-server` (JSON-RPC over stdio) per provider session, then streams structured events to the browser through WebSocket push messages.

How we use it in this codebase:

- Session startup/resume and turn lifecycle are brokered in `apps/server/src/codexAppServerManager.ts`.
- Provider dispatch and thread event logging are coordinated in `apps/server/src/providerManager.ts`.
- WebSocket server routes NativeApi methods in `apps/server/src/wsServer.ts`.
- Web app consumes orchestration domain events via WebSocket push on channel `orchestration.domainEvent` (provider runtime activity is projected into orchestration events server-side).

Docs:

- Codex App Server docs: https://developers.openai.com/codex/sdk/#app-server

## Reference Repos

- Open-source Codex repo: https://github.com/openai/codex
- Codex-Monitor (Tauri, feature-complete, strong reference implementation): https://github.com/Dimillian/CodexMonitor

Use these as implementation references when designing protocol handling, UX flows, and operational safeguards.

## Cursor Cloud specific instructions

### Runtime requirements

- **Bun** `^1.3.9` — package manager and dev runtime (install: `curl -fsSL https://bun.sh/install | bash -s "bun-v1.3.9"`)
- **Node.js** `^24.13.1` — required for `node:sqlite` native bindings used by the server (install via `nvm install 24`)
- **Codex CLI** (`@openai/codex`) — the server spawns `codex app-server` per session. Install globally: `npm install -g @openai/codex`

### Key commands (see README.md for full list)

| Task | Command |
|---|---|
| Install deps | `bun install` |
| Dev (all services) | `T3CODE_NO_BROWSER=1 bun run dev --no-browser` |
| Dev (server only) | `bun run dev:server` |
| Dev (web only) | `bun run dev:web` |
| Lint | `bun run lint` (oxlint) |
| Typecheck | `bun run typecheck` (turbo → tsc across all packages) |
| Test | `bun run test` (turbo → vitest across all packages) |

### Dev server ports & environment

- Vite dev server: `http://localhost:5733`
- WebSocket server: `http://localhost:3773` (also serves the app in production mode)
- Dev state is isolated to `~/.t3/dev` by default (`T3CODE_STATE_DIR`)
- Pass `--no-browser` or set `T3CODE_NO_BROWSER=1` to prevent the server from auto-opening a browser

### Gotchas

- The `contracts` package must be built before `web` or `server` can typecheck or run. `bun run dev` and `bun run typecheck` handle this automatically via turbo dependency graph.
- Sending messages in the UI requires a valid `OPENAI_API_KEY` (or Codex auth). Without it, turns fail with a 401 error — the rest of the UI still works fine.
- **Codex auth**: The Codex CLI stores credentials in `~/.codex/auth.json`, NOT from `OPENAI_API_KEY` env var directly. To authenticate, run `echo "$OPENAI_API_KEY" | codex login --with-api-key`. The `globalPassThroughEnv` in `turbo.json` ensures the env var reaches child processes, but codex reads its own auth store.
- The server uses `node:sqlite` (experimental in Node 24) — you will see `ExperimentalWarning` in test output; this is expected.
- Avoid `bun run build` in dev — the user prefers not to run build commands as they can interfere with the dev environment. Use `bun run typecheck` instead.
- **Turbo strict env mode**: Since `globalEnv` is configured in `turbo.json`, turbo only passes declared env vars to child processes. Add new vars to `globalEnv` (cache-relevant) or `globalPassThroughEnv` (pass-through only) as needed.
