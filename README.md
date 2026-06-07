# mnemon-sync

Sync your [mnemon](https://github.com/mnemon-dev/mnemon) memory stores across
multiple machines — with **zero changes to mnemon's code**. Just the `sqlite3`
CLI, [Syncthing](https://syncthing.net/), and Claude Code hooks.

## The problem

A mnemon store is a single SQLite database (`~/.mnemon/data/<store>/mnemon.db`).
If you use Claude Code (or any mnemon-backed agent) on more than one machine, you
want the same memory everywhere. But you **cannot** just file-sync the `.db`:

- WAL/SHM side files make a live database inconsistent mid-copy;
- a file sync can grab a torn, half-written database;
- worst of all, a sync tool can't *merge* a binary file — two machines writing
  produce conflicts and silently lose data.

## The approach

`mnemon-sync` treats the live DB as local-only and syncs a **logical merge**
instead:

1. **Snapshot** — each machine exports a consistent snapshot of every store with
   `sqlite3 VACUUM INTO`, written as `sync/<store>/<host>.db`.
2. **Ship** — one shared folder (`~/.mnemon/sync/`) is synced between machines by
   Syncthing. Each machine only ever writes *its own* `<host>.db`, so there are
   never two writers on one file — Syncthing never makes a conflict file.
3. **Merge** — each machine imports peers' snapshots into its live DB with a
   **last-writer-wins** merge on the `insights` table (keyed by `updated_at`),
   unions the edges, and drops edges of deleted insights.

This is a state-based CRDT that converges: new memories and deletions are never
lost; a concurrent edit of the *same* memory resolves to the latest one.

It works because of how mnemon stores data: UUID primary keys (no insert
collisions), soft-delete tombstones (`forget`/`gc` never hard-delete), and an
`updated_at` on every row.

## How it runs

Memory only changes when an agent runs, so syncing is driven by Claude Code hooks:

- **`SessionStart`** → `import` (pull peers before you start)
- **`Stop` + `SubagentStop`** → `export` (publish after each turn / memory write)

The hooks are silent, non-blocking, and skip work when nothing changed (an mtime
guard), so they add no noticeable overhead and never interrupt a session.

## Requirements

- [mnemon](https://github.com/mnemon-dev/mnemon)
- `sqlite3` CLI — macOS: preinstalled; Debian/Ubuntu: `sudo apt install sqlite3`
- `python3` (only for `install-hooks`)
- [Syncthing](https://syncthing.net/) between your machines
- [Claude Code](https://claude.com/claude-code) (for the lifecycle hooks)

## Quick start

Full walkthrough: **[INSTALL.md](INSTALL.md)**. In short, on each machine:

```bash
git clone https://github.com/b1rdex/mnemon-sync && cd mnemon-sync

# put the script where Syncthing will share it
mkdir -p ~/.mnemon/sync/bin
cp mnemon-sync mnemon-sync.test.sh ~/.mnemon/sync/bin/
chmod +x ~/.mnemon/sync/bin/mnemon-sync

# share ONLY ~/.mnemon/sync between your machines in Syncthing, then:
~/.mnemon/sync/bin/mnemon-sync install-hooks
```

## Commands

| command | what it does |
|---|---|
| `export` | snapshot each live store to `$SYNC_DIR/<store>/<host>.db` |
| `import` | merge peers' snapshots into each live store (LWW) |
| `sync` | `export` then `import` |
| `status` | per-store counts + known snapshots |
| `install-hooks` | add the SessionStart / Stop / SubagentStop hooks to Claude settings |
| `uninstall-hooks` | remove them (only its own entries) |

Environment overrides: `MNEMON_DATA_DIR`, `MNEMON_SYNC_DIR`, `MNEMON_SYNC_HOST`
(device id, defaults to `hostname -s`), `CLAUDE_SETTINGS`.

## Safety & testing

- Live `~/.mnemon/data/` is **never** placed in the synced folder — it can't leak.
- `install-hooks` / `uninstall-hooks` are idempotent and touch only their own hook
  entries; your other Claude settings are preserved (and backed up first).
- `./mnemon-sync.test.sh` runs an isolated two-device convergence / idempotency /
  safety / bootstrap / hook test against the real mnemon schema.

Full rationale and trade-offs: **[DESIGN.md](DESIGN.md)**.

## Limitations (by design)

- Graph **edges are unioned**, not recomputed (recall still works; a few edge
  weights may differ from a fresh build — recomputing would need mnemon's engine).
- Soft-delete **tombstones accumulate** over time.
- A concurrent edit of the *same* insight on two machines resolves by
  last-writer-wins (the older revision of that one insight is dropped).

## License

[MIT](LICENSE)
