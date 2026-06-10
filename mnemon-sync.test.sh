#!/usr/bin/env bash
#
# Test harness for mnemon-sync. Simulates two devices (laptop, desktop) sharing
# one snapshot folder, using temp dirs. Seeds from the real backed-up `default`
# DB so we exercise the real schema. Exits non-zero on the first failed assertion.
#
set -eo pipefail

SCRIPT="${1:-$(cd "$(dirname "$0")" >/dev/null 2>&1 && pwd)/mnemon-sync}"
[ -x "$SCRIPT" ] || { echo "FAIL: script not executable: $SCRIPT"; exit 1; }

# Find a real mnemon DB to seed the temp "devices" (for the real schema).
# Priority: $MNEMON_SEED, live default store, any live store.
SEED="${MNEMON_SEED:-}"
if [ -z "$SEED" ]; then
  for cand in \
              "$HOME/.mnemon/data/default/mnemon.db" \
              "$HOME"/.mnemon/data/*/mnemon.db; do
    [ -n "$cand" ] && [ -f "$cand" ] && { SEED="$cand"; break; }
  done
fi
[ -f "$SEED" ] || { echo "FAIL: no seed db found (set MNEMON_SEED=/path/to/mnemon.db)"; exit 1; }
echo "seed db: $SEED"

ROOT="$(mktemp -d)"
trap 'rm -rf "$ROOT"' EXIT
SHARED="$ROOT/shared-sync"
A="$ROOT/devA"
B="$ROOT/devB"
mkdir -p "$SHARED" "$A/data/default" "$B/data/default"
cp "$SEED" "$A/data/default/mnemon.db"
cp "$SEED" "$B/data/default/mnemon.db"

DBA="$A/data/default/mnemon.db"
DBB="$B/data/default/mnemon.db"

runA() { MNEMON_DATA_DIR="$A" MNEMON_SYNC_DIR="$SHARED" MNEMON_SYNC_HOST="laptop"  "$SCRIPT" "$@" >/dev/null 2>&1; }
runB() { MNEMON_DATA_DIR="$B" MNEMON_SYNC_DIR="$SHARED" MNEMON_SYNC_HOST="desktop" "$SCRIPT" "$@" >/dev/null 2>&1; }
qA()   { sqlite3 "$DBA" "$1"; }
qB()   { sqlite3 "$DBB" "$1"; }

fail() { echo "FAIL: $*"; exit 1; }
ok()   { echo "  ok: $*"; }

ins() { # ins <db> <id> <content> <updated_at> [deleted_at]
  local db="$1" id="$2" content="$3" ts="$4" del="${5:-}"
  local delsql="NULL"; [ -n "$del" ] && delsql="'$del'"
  sqlite3 "$db" "INSERT INTO insights (id,content,category,importance,tags,entities,source,access_count,created_at,updated_at,deleted_at,last_accessed_at,embedding,effective_importance)
    VALUES ('$id','$content','fact',3,'[]','[]','test',0,'$ts','$ts',$delsql,NULL,NULL,0.5);"
}

BASE="2026-06-06T19:00:00Z"
T1="2026-06-06T20:00:00Z"
T2="2026-06-06T20:30:00Z"
LATER="2026-06-06T21:00:00Z"

echo "== seed: common prior state E1,E2,E3 on both devices =="
for db in "$DBA" "$DBB"; do
  ins "$db" "E1-common" "orig e1" "$BASE"
  ins "$db" "E2-common" "orig e2" "$BASE"
  ins "$db" "E3-common" "orig e3" "$BASE"
done
BASE_ACTIVE=$(qA "SELECT count(*) FROM insights WHERE deleted_at IS NULL;")
echo "  baseline active insights (each device): $BASE_ACTIVE"

echo "== divergent edits =="
# laptop: new AAA, edit E1, edit E3 at T1
ins "$DBA" "AAA-laptop" "born on laptop" "$T1"
qA "UPDATE insights SET content='EDITED ON LAPTOP', updated_at='$LATER' WHERE id='E1-common';"
qA "UPDATE insights SET content='E3 laptop edit', updated_at='$T1' WHERE id='E3-common';"
# desktop: new BBB, soft-delete E2, edit E3 at T2 (T2 > T1 → desktop should win E3)
ins "$DBB" "BBB-desktop" "born on desktop" "$T1"
qB "UPDATE insights SET deleted_at='$T1', updated_at='$T1' WHERE id='E2-common';"
qB "UPDATE insights SET content='E3 desktop edit', updated_at='$T2' WHERE id='E3-common';"

echo "== exchange snapshots (each exports, each imports the peer) =="
runA export; runB export
runA import; runB import

echo "== assert convergence =="
[ "$(qA "SELECT count(*) FROM insights WHERE id='AAA-laptop';")" = 1 ] || fail "AAA missing on laptop"
[ "$(qB "SELECT count(*) FROM insights WHERE id='AAA-laptop';")" = 1 ] || fail "AAA not propagated to desktop"
ok "new insight AAA on both"
[ "$(qA "SELECT count(*) FROM insights WHERE id='BBB-desktop';")" = 1 ] || fail "BBB not propagated to laptop"
[ "$(qB "SELECT count(*) FROM insights WHERE id='BBB-desktop';")" = 1 ] || fail "BBB missing on desktop"
ok "new insight BBB on both"

[ "$(qA "SELECT content FROM insights WHERE id='E1-common';")" = "EDITED ON LAPTOP" ] || fail "E1 edit lost on laptop"
[ "$(qB "SELECT content FROM insights WHERE id='E1-common';")" = "EDITED ON LAPTOP" ] || fail "E1 edit not propagated to desktop"
ok "edit of E1 (laptop) propagated, not clobbered by peer's stale copy"

[ -n "$(qA "SELECT deleted_at FROM insights WHERE id='E2-common' AND deleted_at IS NOT NULL;")" ] || fail "E2 delete not propagated to laptop"
[ -n "$(qB "SELECT deleted_at FROM insights WHERE id='E2-common' AND deleted_at IS NOT NULL;")" ] || fail "E2 not deleted on desktop"
ok "soft-delete of E2 (desktop) propagated to both"

# LWW: E3 edited on both; desktop's T2 > laptop's T1 → desktop wins on both
[ "$(qA "SELECT content FROM insights WHERE id='E3-common';")" = "E3 desktop edit" ] || fail "E3 LWW wrong on laptop: $(qA "SELECT content FROM insights WHERE id='E3-common';")"
[ "$(qB "SELECT content FROM insights WHERE id='E3-common';")" = "E3 desktop edit" ] || fail "E3 LWW wrong on desktop"
ok "concurrent edit of E3 resolved by LWW (later timestamp wins) on both"

# no insight lost: totals + active equal across devices and match expectation
TA=$(qA "SELECT count(*) FROM insights;"); TB=$(qB "SELECT count(*) FROM insights;")
[ "$TA" = "$TB" ] || fail "total insight counts diverge: laptop=$TA desktop=$TB"
CA=$(qA "SELECT count(*) FROM insights WHERE deleted_at IS NULL;")
CB=$(qB "SELECT count(*) FROM insights WHERE deleted_at IS NULL;")
[ "$CA" = "$CB" ] || fail "active counts diverge: laptop=$CA desktop=$CB"
EXP_ACTIVE=$((BASE_ACTIVE + 2 - 1))   # +AAA +BBB -E2(deleted)
[ "$CA" = "$EXP_ACTIVE" ] || fail "active count $CA != expected $EXP_ACTIVE"
ok "no data loss: totals equal ($TA), active equal ($CA = baseline+2-1)"

echo "== assert idempotency (re-import changes nothing) =="
H1=$(sqlite3 "$DBA" "SELECT count(*), (SELECT count(*) FROM edges) FROM insights;")
runA import
H2=$(sqlite3 "$DBA" "SELECT count(*), (SELECT count(*) FROM edges) FROM insights;")
[ "$H1" = "$H2" ] || fail "import not idempotent: $H1 -> $H2"
ok "second import is a no-op"

echo "== assert safety: live data never written into sync folder =="
[ ! -e "$SHARED/default/mnemon.db" ] || fail "live db name leaked into sync folder"
for f in "$SHARED"/default/*.db; do
  case "$(basename "$f")" in
    laptop.db|desktop.db) : ;;
    *) fail "unexpected file in sync folder: $f" ;;
  esac
done
ok "sync folder contains only per-device snapshots (laptop.db, desktop.db)"

echo "== assert bootstrap: a new store on a peer appears locally =="
mkdir -p "$A/data/work"; cp "$SEED" "$A/data/work/mnemon.db"
ins "$A/data/work/mnemon.db" "W1" "work item" "$T1"
runA export
[ ! -f "$B/data/work/mnemon.db" ] || fail "precondition: desktop already has work store"
runB import
[ -f "$B/data/work/mnemon.db" ] || fail "bootstrap: work store not created on desktop"
[ "$(sqlite3 "$B/data/work/mnemon.db" "SELECT count(*) FROM insights WHERE id='W1';")" = 1 ] || fail "bootstrap: W1 missing on desktop"
ok "new store 'work' bootstrapped onto desktop with its data"

echo "== assert schema drift tolerance: devices on different mnemon versions still merge =="
SHARED2="$ROOT/shared-drift"; D="$ROOT/devD"; E="$ROOT/devE"
mkdir -p "$SHARED2" "$D/data/default" "$E/data/default"
# devD: an OLDER mnemon schema — insights table without effective_importance
sqlite3 "$D/data/default/mnemon.db" "
CREATE TABLE insights (id TEXT PRIMARY KEY, content TEXT NOT NULL, category TEXT DEFAULT 'general', importance INTEGER DEFAULT 3, tags TEXT DEFAULT '[]', entities TEXT DEFAULT '[]', source TEXT DEFAULT 'user', access_count INTEGER DEFAULT 0, created_at TEXT NOT NULL, updated_at TEXT NOT NULL, deleted_at TEXT, last_accessed_at TEXT, embedding BLOB);
CREATE TABLE edges (source_id TEXT NOT NULL, target_id TEXT NOT NULL, edge_type TEXT NOT NULL, weight REAL DEFAULT 1.0, metadata TEXT DEFAULT '{}', created_at TEXT NOT NULL, PRIMARY KEY (source_id, target_id, edge_type));"
# devE: full current schema (from the seed)
cp "$SEED" "$E/data/default/mnemon.db"
ins "$E/data/default/mnemon.db" "EE-full" "from full-schema device" "$T1"
sqlite3 "$D/data/default/mnemon.db" "INSERT INTO insights (id,content,category,importance,tags,entities,source,access_count,created_at,updated_at) VALUES ('DD-old','from old-schema device','fact',3,'[]','[]','test',0,'$T1','$T1');"
runD() { MNEMON_DATA_DIR="$D" MNEMON_SYNC_DIR="$SHARED2" MNEMON_SYNC_HOST="oldbox" "$SCRIPT" "$@" >/dev/null 2>&1; }
runE() { MNEMON_DATA_DIR="$E" MNEMON_SYNC_DIR="$SHARED2" MNEMON_SYNC_HOST="newbox" "$SCRIPT" "$@" >/dev/null 2>&1; }
runD export; runE export
runD import; runE import
[ "$(sqlite3 "$D/data/default/mnemon.db" "SELECT count(*) FROM insights WHERE id='EE-full';")" = 1 ] || fail "drift: EE-full did not reach the old-schema device"
[ "$(sqlite3 "$E/data/default/mnemon.db" "SELECT count(*) FROM insights WHERE id='DD-old';")" = 1 ] || fail "drift: DD-old did not reach the full-schema device"
[ "$(sqlite3 "$E/data/default/mnemon.db" "SELECT effective_importance FROM insights WHERE id='DD-old';")" = "0.5" ] || fail "drift: missing column did not get its default on the full-schema device"
ok "rows sync across devices with different column sets (common columns merged, defaults fill the rest)"

echo "== assert install-hooks idempotency + non-destructiveness =="
ST="$ROOT/settings.json"
cat > "$ST" <<JSON
{
  "env": {"SECRET": "keep-me"},
  "hooks": {
    "SessionStart": [{"hooks": [{"type": "command", "command": "/x/mnemon/prime.sh"}]}],
    "Stop": [{"hooks": [{"type": "command", "command": "/x/mnemon/stop.sh"}]}]
  }
}
JSON
CLAUDE_SETTINGS="$ST" "$SCRIPT" install-hooks >/dev/null
CLAUDE_SETTINGS="$ST" "$SCRIPT" install-hooks >/dev/null   # twice → must stay idempotent

check_hooks() {
python3 - "$ST" "$SCRIPT" <<'PY'
import json, sys
d = json.load(open(sys.argv[1])); script = sys.argv[2]
h = d["hooks"]
def cmds(ev): return [x.get("command","") for g in h.get(ev,[]) for x in g.get("hooks",[])]
ss, stp, sub = cmds("SessionStart"), cmds("Stop"), cmds("SubagentStop")
assert d["env"]["SECRET"] == "keep-me", "env clobbered"
assert any("prime.sh" in c for c in ss), "mnemon prime.sh lost"
assert any("stop.sh" in c for c in stp), "mnemon stop.sh lost"
imp = "%s import" % script
exp = "%s export" % script
assert sum(imp in c for c in ss) == 1, "import hook count != 1: %r" % ss
assert sum(exp in c for c in stp) == 1, "export hook count != 1 in Stop: %r" % stp
assert sum(exp in c for c in sub) == 1, "export hook count != 1 in SubagentStop: %r" % sub
assert imp in ss[0], "import not prepended before prime.sh: %r" % ss
print("hooks-ok")
PY
}
[ "$(check_hooks)" = "hooks-ok" ] || fail "install-hooks structure wrong"
ok "install-hooks idempotent, prepends import, preserves mnemon hooks + env"

echo "== assert uninstall-hooks removes only ours =="
CLAUDE_SETTINGS="$ST" "$SCRIPT" uninstall-hooks >/dev/null
python3 - "$ST" "$SCRIPT" <<'PY'
import json, sys
d = json.load(open(sys.argv[1])); script = sys.argv[2]
h = d["hooks"]
allcmds = [x.get("command","") for ev in h.values() for g in ev for x in g.get("hooks",[])]
assert not any(script in c for c in allcmds), "our hooks not fully removed: %r" % allcmds
assert any("prime.sh" in c for c in allcmds), "mnemon prime.sh removed by uninstall!"
assert any("stop.sh" in c for c in allcmds), "mnemon stop.sh removed by uninstall!"
assert "SubagentStop" not in h, "empty SubagentStop not cleaned up"
print("uninstall-ok")
PY
ok "uninstall-hooks removed only our entries, left mnemon's intact"

echo
echo "ALL TESTS PASSED"
