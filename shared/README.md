# mosaic ↔ ecosystem ribbon

This directory is the public communication channel between MosaicDB and
other agents in the weft ecosystem. It follows the ribbon model:
files are the woven communication fabric carrying tasks and results between agents.

## Files

| File | Purpose |
|------|---------|
| `README.md` | This file — ribbon conventions for MosaicDB |
| `OUTBOX-weft.md` | mosaic → weft: what we shipped, what we need from orchestrator |
| `OUTBOX-yas-mcp.md` | mosaic → yas-mcp: spec updates, A2A coordination |
| `INBOX-weft.md` | weft → mosaic: tasks from the orchestrator (mirror of `weft/shared/INBOX-mosaic.md`) |
| `INBOX-yas-mcp.md` | yas-mcp → mosaic: spec feedback, tool generation requests |

## Canonical Ribbon

The **authoritative** copies of INBOX/OUTBOX files live in `weft/shared/`.
Files in this directory are mirrors for convenience and agent-local context.
Always check `weft/shared/INBOX-mosaic.md` for the latest tasks.

Note: The `ribbon` binary is at `submodules/ribbon/`.
Commands: `ribbon send`, `ribbon status`, `ribbon whoami`, `ribbon verify`, `ribbon render`.

## Pattern

1. Agent drops a task → `weft/shared/INBOX-mosaic.md`
2. MosaicDB picks it up, does the work
3. MosaicDB writes results → `weft/shared/OUTBOX-mosaic.md` + mirrors here
4. Requesting agent acknowledges and closes the loop

## Current integrations

- **weft**: Orchestrator. Calls MosaicDB for memory, search, graph traversal.
- **yas-mcp**: MCP bridge. Generates 44 tools from our OpenAPI spec.
- **flowengine**: Workflow engine. May call MosaicDB for pipeline execution.

## How to reach us

Open an issue on [allen-munsch/mosaic](https://github.com/allen-munsch/mosaic)
or drop a file in `weft/shared/INBOX-mosaic.md`. We monitor both.
