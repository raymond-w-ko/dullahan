# Command Blocks Design

## Thesis

Best next addition: **first-class command blocks**.

Turn each shell command into a durable object:

- prompt start
- input start/end
- output span
- command end
- cwd
- exit code
- row-id anchors
- timestamps

One primitive. Many features:

- sticky command headers
- jump between commands
- copy/select output
- failure surfacing
- block search/filter
- rerun in same cwd
- bookmarks/share later
- agent-context attachment later

## Why Now

Dullahan already has most of the hard substrate:

- OSC 133 semantic prompt events parsed in `server/src/stream_handler.zig`
- OSC 7 working directory captured in `server/src/stream_handler.zig`
- shell integration events broadcast in `server/src/event_loop.zig`
- shell integration messages received in `client/src/terminal/connection.ts`
- stable row IDs already shipped in snapshot/delta protocol

Today that semantic signal stops at the transport layer. Product upside unrealized.

## Core Idea

Make the **server** the source of truth for command boundaries.

Reason:

- server owns authoritative terminal state
- server sees OSC 133/7 in order
- server already owns stable row IDs
- clients can reconnect/resync without losing semantic structure
- multiple clients can share one consistent model

## Proposed Model

```ts
interface CommandBlock {
  id: string;
  paneId: number;
  windowId: number;

  status: "prompt" | "running" | "done";
  exitCode?: number;

  cwd?: string;
  startedAtMs: number;
  endedAtMs?: number;

  promptStartRowId?: bigint;
  inputStartRowId?: bigint;
  outputStartRowId?: bigint;
  outputEndRowId?: bigint;
  commandEndRowId?: bigint;

  title?: string;
  commandPreview?: string;
}
```

Server keeps:

- current open block per pane
- recent completed blocks per pane
- row-id to block lookup helpers

## Event Mapping

Map shell integration to block lifecycle:

- `prompt_start`: open new pending block; capture prompt row anchor
- `prompt_end`: mark input region start/end
- `output_start`: mark output start row
- `command_end`: close block; capture exit code and end anchor
- `OSC 7`: update pane cwd; attach latest cwd to current/open block

If a new `prompt_start` arrives with no `command_end`, close prior block as interrupted/unknown.

## Row Anchoring

Anchor blocks to stable row IDs, not viewport offsets.

Why:

- viewport moves
- scrollback prunes
- clients reconnect
- delta sync already speaks row IDs

This gives durable command boundaries even as the viewport changes.

## Protocol Addition

Add server -> client block messages:

```ts
interface CommandBlocksSnapshotMessage {
  type: "command_blocks_snapshot";
  paneId: number;
  blocks: CommandBlock[];
  activeBlockId?: string;
}

interface CommandBlockUpdateMessage {
  type: "command_block_update";
  paneId: number;
  block: CommandBlock;
}
```

Initial version can skip client -> server messages entirely.

Later additions:

- `jump_to_block`
- `copy_block_output`
- `rerun_block`
- `bookmark_block`

## UI Shape

Phase 1 UI:

- subtle sticky header above terminal viewport
- show cwd, command preview, running/done state, exit code
- click to jump previous/next command
- quick copy-output action

Phase 2 UI:

- command rail / minimap per pane
- block list filter: failed, running, cwd, text
- block selection and export

Phase 3 UI:

- attach block to note/share artifact
- use block as explicit context unit for agents/tools

## Rollout Plan

### Phase 0 - Shell Integration Coverage

Auto-install or document shell integration for:

- zsh
- bash
- fish

Without reliable OSC 133, feature quality is capped.

### Phase 1 - Server Model

- add `CommandBlock` state in server
- update from OSC 133 + OSC 7
- keep bounded per-pane history
- include block state in full snapshot path

### Phase 2 - Wire Protocol

- add block snapshot/update messages
- ensure reconnect/resync restores block state
- ensure multi-client consistency

### Phase 3 - Minimal UI

- sticky current-command header
- prev/next command navigation
- failed-command highlighting
- copy output action

### Phase 4 - Search / Workflow

- block picker
- block text search
- rerun in same cwd
- bookmarks

## Implementation Notes

Good first storage point: per-pane block tracker on server side.

Needs care around:

- alternate screen transitions
- scrollback pruning
- shells with partial/no OSC 133 support
- nested prompts / shell redraws
- commands that never emit `output_start`
- reconnect/resync semantics

Useful fallback:

- if OSC 133 missing, feature disabled for that pane
- never infer aggressively from raw terminal text in v1

## Why This Beats Other Additions

Compared with search, session restore, or AI helpers:

- lower ambiguity
- builds on existing primitives already in tree
- unlocks several user-facing features at once
- differentiates Dullahan from “terminal in browser” implementations

This is the highest-leverage semantic layer available in the current architecture.
