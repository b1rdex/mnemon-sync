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

**Hard constraint — zero changes to mnemon.** Everything here is external: the
system `sqlite3` CLI, shell, `python3`, Syncthing, and Claude Code hook config. It
works with a stock, upstream mnemon install — nothing to patch or rebuild.

## 2. Key decisions

| Decision | Choice | Rationale |
|---|---|---|
| What to sync | Per-device binary `.db` snapshot (not the live DB, not JSONL) | SQLite does the merge via `ATTACH`; embeddings ride along in columns for free; least code |
| Conflict model | State-based **LWW** on the `insights` table, keyed by `updated_at`; usage fields (`access_count`, `last_accessed_at`) merge by **max** instead | mnemon's model fits exactly: UUID PKs (no insert collisions), soft-delete tombstones (`gc` never hard-deletes, `forget` only sets `deleted_at`), `updated_at` present on every row. Recall bumps usage *without* touching `updated_at` (mtime/atime split), so those two fields need their own monotone merge — see §4. |
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

Merge SQL (generated per peer snapshot — the column lists are **derived at merge
time** by intersecting `pragma_table_info` of both databases, so devices running
different mnemon versions sync their common columns and table defaults fill the
rest; `id` and `updated_at` are required, otherwise the peer file is skipped):

```sql
PRAGMA busy_timeout=5000;          -- wait, don't fail, if mnemon is mid-write
ATTACH '<peer>.db' AS peer;
BEGIN;

-- 1) insights: LWW by updated_at over the COMMON columns. Two exceptions:
--    access_count and last_accessed_at are merged with max() even here, so a
--    content win never clobbers a higher usage signal from the other device.
INSERT INTO insights (<common columns>)
  SELECT <common columns> FROM peer.insights WHERE true
  ON CONFLICT(id) DO UPDATE SET
    <col>=excluded.<col> ...,
    access_count     = max(coalesce(insights.access_count,0), coalesce(excluded.access_count,0)),
    last_accessed_at = nullif(max(coalesce(insights.last_accessed_at,''), coalesce(excluded.last_accessed_at,'')), '')
  WHERE excluded.updated_at > insights.updated_at;

-- 1b) usage fields for rows the upsert skipped (peer not content-newer):
--     recall bumps access_count/last_accessed_at WITHOUT touching updated_at,
--     so they need their own monotone merge. Correlated subqueries keep this
--     portable to older sqlite3 builds (no UPDATE..FROM).
UPDATE insights SET
  access_count     = max(coalesce(access_count,0), coalesce((SELECT p.access_count FROM peer.insights p WHERE p.id = insights.id), 0)),
  last_accessed_at = nullif(max(coalesce(last_accessed_at,''), coalesce((SELECT p.last_accessed_at FROM peer.insights p WHERE p.id = insights.id), '')), '')
WHERE id IN (SELECT id FROM peer.insights);

-- 2) edges: union over the common edge columns. Endpoints exist after step 1.
INSERT OR IGNORE INTO edges (<common columns>) SELECT <common columns> FROM peer.edges;

-- 3) tidy: drop edges touching soft-deleted insights (mirrors mnemon's own
--    forget(), which removes a deleted node's edges).
DELETE FROM edges WHERE source_id IN (SELECT id FROM insights WHERE deleted_at IS NOT NULL)
                     OR target_id IN (SELECT id FROM insights WHERE deleted_at IS NOT NULL);

COMMIT;
DETACH peer;
```

Ordering correctness: insights are merged before edges so every edge endpoint
exists locally. `WHERE true` is the SQLite idiom that lets an upsert follow a
`SELECT`. `updated_at` and `last_accessed_at` are stored as RFC3339 UTC text, so
lexical comparisons (`>`, `max()`) are also chronological — an assumption the
design relies on (it holds as long as mnemon keeps the RFC3339 format).

Why usage fields get special treatment: mnemon deliberately splits "when was the
fact edited" (`updated_at`) from "when was it read" (`last_accessed_at` +
`access_count`) — recall bumps only the latter pair. Under plain row-LWW those
bumps neither propagate (row not "newer") nor survive a content win (all columns
overwritten). Yet they feed retention: `IsImmune` (access ≥ 3), `gc` candidate
selection, and the automatic `AutoPrune` at >1000 insights — so a device that
never saw the bumps could prune a memory that is hot on the other device, and the
tombstone would then sync everywhere. Max-merge makes the usage signal travel.
A `max(updated_at, last_accessed_at)` LWW key was considered and rejected: a
recall of a *stale* copy would then beat a genuine edit (or resurrect a forget).

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
  dropped. New insights and deletes are never lost.
- **Usage counters merge by max, not sum.** Concurrent recall bumps on both
  devices converge to the larger counter (4 and 3 from a common 2 → 4, true total
  5). The "this memory is used" signal is never lost, but counts can undercount;
  a per-device G-counter would fix that and is not worth the complexity here.
  `effective_importance` still follows the LWW winner — it is derived and must be
  able to decay, and mnemon recomputes it locally.
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
