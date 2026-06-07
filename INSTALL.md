# Install & setup

`mnemon-sync` runs on **two or more machines** that share one Syncthing folder.
Do this once per machine.

> A few steps modify `~/.claude/settings.json`, spawn a short headless Claude
> session, and may need to install a package. Everything is reversible
> (`mnemon-sync uninstall-hooks`) and backed up first.

## 0. Prerequisites (each machine)

- **mnemon** installed and used at least once (so `~/.mnemon/data/` exists).
- **sqlite3** CLI — macOS: preinstalled; Debian/Ubuntu: `sudo apt install -y sqlite3`.
- **python3** — for `install-hooks` only (preinstalled on most systems).
- **Syncthing** installed, with the machines already paired.
- **Claude Code** (for the lifecycle hooks).

## 1. Put the script in the synced folder

The script lives inside the folder you will share, so it distributes itself:

```bash
mkdir -p ~/.mnemon/sync/bin
cp mnemon-sync mnemon-sync.test.sh ~/.mnemon/sync/bin/
chmod +x ~/.mnemon/sync/bin/mnemon-sync ~/.mnemon/sync/bin/mnemon-sync.test.sh
```

Only the first machine needs to copy it in; once Syncthing shares the folder the
script appears on the others (Syncthing preserves the executable bit).

## 2. Share ONLY `~/.mnemon/sync/` in Syncthing

In each machine's Syncthing web UI (usually <http://127.0.0.1:8384>):

- On the first machine: **Add Folder**, path `~/.mnemon/sync`, give it an ID like
  `mnemon-sync`, and share it with your other device(s).
- On the other machine(s): accept the offered `mnemon-sync` folder and point it at
  `~/.mnemon/sync`.

> Share **only** `~/.mnemon/sync`. Never share `~/.mnemon/data` (the live
> databases) — `mnemon-sync` deliberately keeps them out of the synced folder, so
> there is nothing to corrupt. (Syncthing's `.stignore` is per-device and not
> synced, so a dedicated allowlisted folder is safer than a denylist over all of
> `~/.mnemon`.)

## 3. Back up first (each machine)

```bash
TS=$(date +%Y%m%d-%H%M%S); BK="$HOME/.mnemon/backups/$TS"
mkdir -p "$BK/mnemon" "$BK/claude"
cp -a "$HOME/.mnemon/data" "$BK/mnemon/data"
[ -f "$HOME/.mnemon/active" ] && cp -a "$HOME/.mnemon/active" "$BK/mnemon/active"
[ -f "$HOME/.claude/settings.json" ] && cp -a "$HOME/.claude/settings.json" "$BK/claude/settings.json"
echo "backup at: $BK"
```

## 4. Sanity-test the script (no real changes)

Runs an isolated two-device convergence / idempotency / safety test in a temp dir.
Expect `ALL TESTS PASSED`.

```bash
~/.mnemon/sync/bin/mnemon-sync.test.sh
# if you have no local store yet:
# MNEMON_SEED=/path/to/a/mnemon.db ~/.mnemon/sync/bin/mnemon-sync.test.sh
```

## 5. First sync round

```bash
~/.mnemon/sync/bin/mnemon-sync import   # pull peers into your live stores (LWW)
~/.mnemon/sync/bin/mnemon-sync export   # publish your state
~/.mnemon/sync/bin/mnemon-sync status   # review counts + snapshots
```

## 6. Install the lifecycle hooks

```bash
~/.mnemon/sync/bin/mnemon-sync install-hooks
```

This adds (idempotently, preserving existing hooks and settings, after backing up
`settings.json`):

- `SessionStart` → `import` (prepended, before mnemon's own hook)
- `Stop` and `SubagentStop` → `export`

Hooks load at session start, so they take effect on your **next** Claude session.
They are global (`~/.claude/settings.json`), so sync runs across all projects.

## 7. Verify the hooks actually fire (recommended)

Hooks are silent, so verify with a fresh headless session that checks both the
debug log and a real side effect (`export` re-snapshotting a store):

```bash
HOST=$(hostname -s)
SNAP="$HOME/.mnemon/sync/default/$HOST.db"
# portable mtime: Linux `stat -c %Y`, macOS `stat -f %m`
mtime() { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null || echo 0; }
before=$(mtime "$SNAP")
touch "$HOME/.mnemon/data/default/mnemon.db"     # force the mtime-guarded export to act
LOG=$(mktemp)
claude -p "Reply with exactly: OK" --debug-file "$LOG" < /dev/null > /dev/null 2>&1
after=$(mtime "$SNAP")

grep -E "Hook (SessionStart|Stop|SubagentStop).*success" "$LOG" | head
[ "$after" -gt "$before" ] && echo "PASS: export hook re-snapshotted (mtime $before -> $after)" \
                           || echo "CHECK: snapshot mtime did not advance"
rm -f "$LOG"   # the debug log can contain session context
```

You should see a `Hook SessionStart ... success` and a `Hook Stop (Stop) success`
line, plus `PASS`. (Claude logs hook *events*, not the command strings, so the
events plus the snapshot side effect are the proof. `Hook output ... plain text`
debug lines are normal — the hooks are silent, so their output is empty.)

## Revert

```bash
~/.mnemon/sync/bin/mnemon-sync uninstall-hooks   # removes only mnemon-sync's hook entries
```
