# Mnemon Store Sync — Design

**Status:** Implemented and in use.

## 1. Goal & context

Sync [mnemon](https://github.com/mnemon-dev/mnemon) memory stores between two (or
more) machines used **at different times** with the same stores/projects.
Transport is **Syncthing**, which syncs files in near-realtime.

mnemon stores are SQLite DBs at `~/.mnemon/data/<store>/mnemon.db`. A live SQLite
file **cannot** be naively file-synced: WAL/SHM inconsistency, torn mid-write
copies, and — most importantly — Syncthing cannot merge a binary file, so two
machines writing produces `.sync-conflict` files and silent data loss. So we
sync a **per-device snapshot** and merge **logically**.

**Hard constraint — zero mnemon Go code.** This is meant for people who run a fork
of mnemon and want to keep pulling upstream without merge burden. Everything here
is external: the system `sqlite3` CLI, shell, `python3`, Syncthing, and Claude Code
hook config.

## 2. Key decisions

| Decision | Choice | Rationale |
|---|---|---|
| What to sync | Per-device binary `.db` snapshot (not the live DB, not JSONL) | SQLite does the merge via `ATTACH`; embeddings ride along in columns for free; least code |
| Conflict model | State-based **LWW** on the `insights` table, keyed by `updated_at` | mnemon's model fits exactly: UUID PKs (no insert collisions), soft-delete tombstones (`gc` never hard-deletes, `forget` only sets `deleted_at`), `updated_at` present on every row. Simplest converging CRDT. |
| Same-insight concurrent edit | Pure LWW (later `updated_at` wins; older revision dropped) | New insights and deletes are never lost; editing the *same* insight on both machines within a sync window is rare for personal memory |
| Edges & embeddings | Edges = **union** (`INSERT OR IGNORE`); embeddings travel inside the insight row | Edges are a derived index; a union is a harmless superset. No engine re-run needed (that would require Go). There is no `reindex` CLI command. |
| Sync scope | A **dedicated `~/.mnemon/sync/` folder** (allowlist) | Live `data/` stays *outside* the shared folder, so it physically cannot leak. Syncthing's `.stignore` is **per-device and not synced**, so a denylist over the whole `~/.mnemon` is a footgun (a fresh/misconfigured device with no ignore file would sync the live DBs everywhere). |
| Triggers | Claude Code hooks: **import** on `SessionStart`; **export** on `Stop` *and* `SubagentStop`, both mtime-guarded | Memory only changes when an agent runs, and these hooks are already installed by `mnemon setup`. Export is wired to both `Stop` and `SubagentStop` because mnemon writes memory via a **subagent** — see §6. |

## 3. Architecture & folder layout

```
~/.mnemon/data/<store>/mnemon.db        live DB, LOCAL ONLY, never synced
~/.mnemon/active                         which store is default — LOCAL ONLY, never synced
~/.mnemon/sync/                          the ONLY Syncthing-shared folder
   ├── bin/mnemon-sync                   the sync script (synced once stable)
   ├── DESIGN.md                         this document
   └── <store>/<host>.db                 per-device snapshots (single-writer per file)
```

Source of truth = the union of per-device snapshots. The live DB is just the
**materialized merge** and can be rebuilt at any time from the snapshots.

Data flow (per machine):

```
SessionStart ──▶ import: merge every peer snapshot into live DB (LWW)
   (agent works; memory written via subagent)
Stop / SubagentStop ──▶ export: if live DB changed, re-snapshot to sync/<store>/<host>.db
   Syncthing carries <host>.db to the other machine, whose next SessionStart imports it
```

Each device writes **only its own** `<host>.db`, so Syncthing never sees a
two-writer file and never produces a conflict file.

## 4. The `mnemon-sync` script

- **Location:** kept in the synced folder at `~/.mnemon/sync/bin/mnemon-sync` so it
  auto-distributes via Syncthing. The executable bit is preserved across machines
  on permission-supporting filesystems.
- **Device id:** `hostname -s` (override with `MNEMON_SYNC_HOST`).
- **Dependencies:** `sqlite3` (macOS: preinstalled; Debian/Ubuntu: `apt install
  sqlite3`) and `python3` (only for `install-hooks`). File format is compatible
  with mnemon's pure-Go `modernc.org/sqlite` driver.

### Subcommands

**`export`** — for each `~/.mnemon/data/*/mnemon.db`:
- skip if the live DB's mtime is unchanged since the last snapshot (cheap guard,
  makes redundant hook firings free);
- `sqlite3 <live> "VACUUM INTO '<sync>/<store>/<host>.db.tmp'"`, then atomic
  `mv` to `<host>.db` so Syncthing never sees a half-written file.
  `VACUUM INTO` produces a consistent, fully-checkpointed single-file snapshot
  even while mnemon has the DB open.

**`import`** (= merge) — for each `~/.mnemon/sync/<store>/`:
- **bootstrap:** if local `data/<store>/mnemon.db` is missing, initialize it by
  copying the first peer snapshot — so a store created on one machine appears on
  the other automatically;
- for each peer snapshot `*.db` **except** the local `<host>.db`, run the merge
  SQL below against the live DB.

Merge SQL (run once per peer snapshot):

```sql
PRAGMA busy_timeout=5000;          -- wait, don't fail, if mnemon is mid-write
ATTACH '<peer>.db' AS peer;
BEGIN;

-- 1) insights: pure LWW by updated_at. Columns listed EXPLICITLY (not SELECT *)
--    as a guard against schema drift between mnemon versions on the two machines.
INSERT INTO insights (id, content, category, importance, tags, entities, source,
                      access_count, created_at, updated_at, deleted_at,
                      last_accessed_at, embedding, effective_importance)
  SELECT id, content, category, importance, tags, entities, source,
         access_count, created_at, updated_at, deleted_at,
         last_accessed_at, embedding, effective_importance
  FROM peer.insights WHERE true
  ON CONFLICT(id) DO UPDATE SET
    content=excluded.content, category=excluded.category,
    importance=excluded.importance, tags=excluded.tags, entities=excluded.entities,
    source=excluded.source, access_count=excluded.access_count,
    created_at=excluded.created_at, updated_at=excluded.updated_at,
    deleted_at=excluded.deleted_at, last_accessed_at=excluded.last_accessed_at,
    embedding=excluded.embedding, effective_importance=excluded.effective_importance
  WHERE excluded.updated_at > insights.updated_at;

-- 2) edges: union. Endpoints are guaranteed to exist after step 1.
INSERT OR IGNORE INTO edges SELECT * FROM peer.edges;

-- 3) tidy: drop edges touching soft-deleted insights (mirrors mnemon's own
--    forget(), which removes a deleted node's edges).
DELETE FROM edges WHERE source_id IN (SELECT id FROM insights WHERE deleted_at IS NOT NULL)
                     OR target_id IN (SELECT id FROM insights WHERE deleted_at IS NOT NULL);

COMMIT;
DETACH peer;
```

Ordering correctness: insights are merged before edges so every edge endpoint
exists locally. `WHERE true` is the SQLite idiom that lets an upsert follow a
`SELECT`. `updated_at` is stored as RFC3339 UTC text, so a lexical `>` comparison
is also chronological — this is an assumption the design relies on (it holds as
long as mnemon keeps the RFC3339 format).

**`install-hooks`** — a `python3` routine that idempotently edits
`~/.claude/settings.json`:
- prepend to `SessionStart` an entry running `mnemon-sync import` (before mnemon's
  own `SessionStart` hook, so the "Memory active (N insights)" line reflects the merge);
- append to `Stop` and `SubagentStop` an entry running `mnemon-sync export`;
- idempotent: if our command is already present it does nothing; it never edits
  or removes other entries, and backs up `settings.json` first.

**`uninstall-hooks`** — removes only our entries, leaving everything else intact.

## 5. Syncthing setup

Share **only** `~/.mnemon/sync/` between the machines — nothing else. No
`.stignore` is needed because the live data lives outside the shared folder.
One-time per device.

## 6. Why export is on both `Stop` and `SubagentStop`

Per the Claude Code hook docs:
- `Stop` fires at the end of **every turn** (not once per session) and can fire
  many times.
- `SubagentStop` is a distinct event that fires when a subagent finishes.
- Order when the main agent spawns a subagent mid-turn:
  `SubagentStop` → then `Stop`.

mnemon writes memory by delegating to a **Task subagent**. So a memory write lands
when that subagent finishes (`SubagentStop`), and again when the turn closes
(`Stop`). Wiring export to **both** (mtime-guarded) means whatever event comes
right after a write publishes it promptly; redundant firings cost one `stat`.
A naive single-`Stop` export could run *before* a later write — this design
avoids that.

## 7. Accepted trade-offs / limitations

- **Union edges, not recomputed.** Derived edges become the union of both machines'
  edges (a superset). Recall still works (possibly more traversal paths);
  occasionally weights aren't perfectly recomputed. Perfect recompute would need
  mnemon's engine (Go) — out of scope.
- **Concurrent same-insight edit → LWW.** The older revision of that one insight is
  dropped. New insights and deletes are never lost. Soft retention counters
  (`access_count`, `effective_importance`) follow the LWW winner rather than
  merging — acceptable, they are hints.
- **Cross-device duplicates.** If the "same" fact is independently `remember`ed on
  both machines it gets different UUIDs → two rows survive the merge (no loss,
  possible duplication). mnemon's write-time dedup only sees the local DB;
  cross-device duplicates are cleaned later via `gc`/`forget`.
- **Import cadence.** Import runs at `SessionStart`, so peer changes made while a
  session is already open aren't pulled until the next session starts. Fine for
  "different times" usage.

## 8. Rollout phases

1. **Manual core.** Build `export`/`import`; test by hand on a throwaway or the
   `default` store first (not an important store).
2. **Syncthing.** Share `~/.mnemon/sync/`; verify snapshots propagate between
   machines; run `import` manually on each side.
3. **Hooks.** Run `install-hooks`; verify import-on-`SessionStart` and
   export-on-`Stop`/`SubagentStop` with the mtime guard.

## 9. Verification

- **Convergence test:** two temp "device" DBs with divergent writes (a new insight
  on each, a soft-delete on one, an edit to a shared insight). Merge both
  directions; assert the non-deleted insight sets are identical on both, that no
  row count is lost, and that LWW picked the later edit.
- **Idempotency:** running `import` twice changes nothing the second time.
- **Hook idempotency:** `install-hooks` twice yields one set of entries and leaves
  other hooks untouched; `uninstall-hooks` leaves them intact.
- **Safety:** confirm the live `data/` directory never appears inside the
  Syncthing-shared folder.

See `mnemon-sync.test.sh` for the automated version of these checks.
