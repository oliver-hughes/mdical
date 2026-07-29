#!/usr/bin/env bash
#
# The nightly run. Notes in, calendar out, completions back.
#
#   run.sh                  the real thing, as the timer calls it
#   run.sh --dry-run        ingest and build in dry-run, no git, no writes
#   run.sh --no-sync        skip vdirsyncer, for when radicale is not up yet
#   run.sh --verbose        every marker, every diagnostic, every changed line
#
# Order is the whole game. **Ingest before reconcile** - backwards, and anything
# the phone did gets deleted as an orphan on the very first run.
#
#   1  git pull                     the laptop's edits
#   2  vdirsyncer sync              the phone's ticks, into the vdir
#   3  mdical-ingest                completions back into markdown  (3 and 4)
#   5  git commit && git push       durable, BEFORE the resource disappears
#   6  mdical-build                 rebuild the vdir from markdown
#   7  vdirsyncer sync              push it
#   8  healthcheck                  only if none of the above went wrong
#
# Step 5 has to land before step 6 drops the completed resource. If it did not,
# a half-failure would re-publish the task as outstanding and you would tick it
# twice - and the second tick would have nothing left to match.
#
# Everything that writes is idempotent, so a run that dies anywhere is safe to
# repeat. The parts that are not idempotent - the git commit, the vdir delete -
# are ordered so that repeating them is a no-op rather than a loss.

set -euo pipefail

CONFIG="${CAL_CONFIG:-/opt/cal/cal.env}"
# shellcheck source=/dev/null
[ -f "$CONFIG" ] && . "$CONFIG"

CAL_ROOT="${CAL_ROOT:-/opt/cal}"
# The git checkout, and the directory inside it that mdical actually scans. They
# are not the same thing: oliver-hughes/vaults holds `brain`, `main` and `ops`
# side by side, so pointing the scanner at the repo root would read all three.
VAULT_REPO="${VAULT_REPO:-$CAL_ROOT/vault}"
VAULT="${VAULT:-$VAULT_REPO/brain}"
MDICAL="${MDICAL:-$CAL_ROOT/mdical}"
VDIR="${VDIR:-$CAL_ROOT/vdir}"
STATE="${STATE:-$CAL_ROOT/state}"
GIT_NAME="${GIT_NAME:-mdical}"
GIT_EMAIL="${GIT_EMAIL:-mdical@localhost}"
HEALTHCHECK="${HEALTHCHECK:-}"
PUSH_ATTEMPTS="${PUSH_ATTEMPTS:-3}"

DRY_RUN=
NO_SYNC=
VERBOSE=

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    --no-sync) NO_SYNC=1 ;;
    --verbose) VERBOSE=1 ;;
    -h|--help) sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "run.sh: unknown argument: $1" >&2; exit 2 ;;
  esac
  shift
done

# Whether anything went wrong in a way that should not stop the run but should
# stop the healthcheck. A push that fails is the case this exists for: the
# commit is already durable, so the calendar is still correct and only the
# laptop is behind - but somebody should find out.
degraded=

log()  { printf '%s  %s\n' "$(date -u +%H:%M:%S)" "$*"; }
step() { printf '\n== %s\n' "$*"; }
warn() { printf '%s  WARN %s\n' "$(date -u +%H:%M:%S)" "$*" >&2; degraded=1; }
die()  { printf '%s  FAIL %s\n' "$(date -u +%H:%M:%S)" "$*" >&2; exit 1; }

for tool in git luajit vdirsyncer; do
  command -v "$tool" >/dev/null || die "$tool is not on PATH"
done
[ -d "$VAULT_REPO/.git" ] || die "$VAULT_REPO is not a git checkout"
[ -d "$VAULT" ] || die "$VAULT does not exist - is VAULT pointing inside the checkout?"
[ -x "$MDICAL/bin/mdical-build" ] || die "$MDICAL/bin/mdical-build is not executable"

# One run at a time. The timer fires on a schedule and a slow run must not have
# a second one start underneath it - two builds writing one vdir is exactly the
# half-written state the temp-file-plus-rename rule exists to avoid.
mkdir -p "$STATE"
exec 9>"$STATE/run.lock"
flock -n 9 || { log "another run holds the lock - nothing to do"; exit 0; }

log "vault $VAULT"
log "vdir  $VDIR"
[ -n "$DRY_RUN" ] && log "DRY RUN - nothing will be written"

sync_now() {
  if [ -n "$NO_SYNC" ]; then
    log "skipping vdirsyncer (--no-sync)"
    return 0
  fi
  if [ -n "$DRY_RUN" ]; then
    log "skipping vdirsyncer (--dry-run)"
    return 0
  fi
  vdirsyncer sync
}

# ---------------------------------------------------------------- 1  git pull

step "1  pull the notes"
if [ -n "$DRY_RUN" ]; then
  log "skipping git pull (--dry-run)"
else
  # --autostash because the previous run may have left the tree dirty if it died
  # between writing markdown and committing. Without it the pull refuses and the
  # ratchet is stuck for ever.
  git -C "$VAULT_REPO" pull --rebase --autostash || die "could not pull the vault - resolve it by hand"

  # mdical too, so a parser fix reaches the box the same night. --ff-only, since
  # anything else means somebody has been editing the checkout on the server.
  if [ -d "$MDICAL/.git" ]; then
    git -C "$MDICAL" pull --ff-only || warn "could not fast-forward mdical - running the checkout as it stands"
  fi
fi

VAULT_REV="$(git -C "$VAULT_REPO" rev-parse --short HEAD)"
MDICAL_REV="$(git -C "$MDICAL" rev-parse --short HEAD 2>/dev/null || echo unknown)"
log "vault at $VAULT_REV, mdical at $MDICAL_REV"

# --------------------------------------------------------- 2  vdirsyncer pull

step "2  pull the phone's changes into the vdir"
sync_now || die "vdirsyncer failed - not building against a vdir we could not reconcile"

# ------------------------------------------------------------- 3, 4  the ratchet

step "3  read completions back into markdown"
ingest_args=(--vault "$VAULT" --vdir "$VDIR" --state "$STATE")
[ -n "$DRY_RUN" ] && ingest_args+=(--dry-run)
[ -n "$VERBOSE" ] && ingest_args+=(--verbose)

ingest_log="$(mktemp)"
trap 'rm -f "$ingest_log" "$ingest_log.msg"' EXIT
if "$MDICAL/bin/mdical-ingest" "${ingest_args[@]}" | tee "$ingest_log"; then
  :
else
  # A note it could not write is worth shouting about, but the rest of the run
  # is still worth doing: the calendar should not go stale because one file did.
  warn "mdical-ingest reported a problem - see above"
fi

# ------------------------------------------------------------------ 5  commit

step "5  commit and push the completions"
if [ -n "$DRY_RUN" ]; then
  log "skipping git commit (--dry-run)"
elif [ -z "$(git -C "$VAULT_REPO" status --porcelain -- "$VAULT")" ]; then
  log "nothing changed in the vault"
else
  # Scoped to $VAULT, which is the only place ingest writes. The repo holds other
  # vaults beside this one, and a nightly job that swept up whatever you happened
  # to have uncommitted elsewhere - under a message about phone completions - would
  # be a genuinely unpleasant surprise.
  git -C "$VAULT_REPO" add -A -- "$VAULT"
  {
    printf 'cal: completions from the phone\n\n'
    grep -E '^  [^ ].*:[0-9]+ ' "$ingest_log" || true
  } > "$ingest_log.msg"

  git -C "$VAULT_REPO" \
    -c "user.name=$GIT_NAME" -c "user.email=$GIT_EMAIL" \
    commit -q -F "$ingest_log.msg" || die "could not commit - refusing to build on top of it"
  rm -f "$ingest_log.msg"
  log "committed $(git -C "$VAULT_REPO" rev-parse --short HEAD)"

  pushed=
  for attempt in $(seq 1 "$PUSH_ATTEMPTS"); do
    if git -C "$VAULT_REPO" push --quiet; then
      pushed=1
      break
    fi
    log "push rejected (attempt $attempt) - rebasing onto the remote and retrying"
    git -C "$VAULT_REPO" pull --rebase --autostash || break
  done
  # Deliberately not fatal. The commit is durable, so the completion is recorded
  # and will not be applied twice; only the laptop is behind, and the next run
  # pushes both. Marking the run degraded is what gets somebody to look.
  if [ -n "$pushed" ]; then
    log "pushed"
  else
    warn "could not push - the commit is local only"
  fi
fi

# ------------------------------------------------------------------- 6  build

step "6  rebuild the vdir from markdown"
build_args=(--vault "$VAULT" --vdir "$VDIR" --state "$STATE" --rev "$MDICAL_REV")
[ -n "$DRY_RUN" ] && build_args+=(--dry-run)
[ -n "$VERBOSE" ] && build_args+=(--verbose)
"$MDICAL/bin/mdical-build" "${build_args[@]}" \
  || die "the build refused to publish - nothing was changed, look at why before forcing it"

# ------------------------------------------------------------- 7  vdirsyncer push

step "7  push the rebuilt vdir"
sync_now || die "vdirsyncer failed on the way out - the vdir is correct, the server is behind"

# ------------------------------------------------------------- 8  healthcheck

step "8  done"
if [ -n "$degraded" ]; then
  die "finished with warnings - deliberately not pinging the healthcheck"
fi
if [ -n "$HEALTHCHECK" ] && [ -z "$DRY_RUN" ]; then
  if curl -fsS -m 10 "$HEALTHCHECK" >/dev/null 2>&1; then
    log "healthcheck pinged"
  else
    die "healthcheck unreachable - the run itself was clean"
  fi
fi
log "clean run"
