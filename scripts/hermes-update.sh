#!/usr/bin/env bash
set -euo pipefail

REPO="${REPO:-/home/cody/src/hermes-agent}"
VENV="${VENV:-$REPO/.venv}"
LOG_TAG="${LOG_TAG:-hermes-update}"
DEPLOY_BRANCH="${DEPLOY_BRANCH:-main}"
UPSTREAM_REMOTE="${UPSTREAM_REMOTE:-upstream}"
UPSTREAM_BRANCH="${UPSTREAM_BRANCH:-main}"
UPSTREAM_REF="${UPSTREAM_REMOTE}/${UPSTREAM_BRANCH}"
LAST_KNOWN_GOOD_REF="${LAST_KNOWN_GOOD_REF:-refs/local/last-known-good}"
LOCKFILE="${LOCKFILE:-/home/cody/.cache/hermes-update.lock}"
GATEWAY_SERVICE="${GATEWAY_SERVICE:-hermes-gateway.service}"
SKIP_RESTART="${HERMES_UPDATE_SKIP_RESTART:-0}"
SKIP_PUSH="${HERMES_UPDATE_SKIP_PUSH:-0}"
HEALTH_CHECK_DELAY="${HEALTH_CHECK_DELAY:-2}"
SMOKE_CMD="${HERMES_UPDATE_SMOKE_CMD:-}"
PUSH_REMOTE="${PUSH_REMOTE:-origin}"
PUSH_BRANCH="${PUSH_BRANCH:-$DEPLOY_BRANCH}"

PYTHON_DEPS=(pyproject.toml requirements.txt uv.lock)
NODE_DEPS=(package.json package-lock.json)

log() { echo "[$LOG_TAG] $(date -Is) $*"; }

ensure_clean_repo() {
    if ! git diff --quiet --ignore-submodules -- || ! git diff --cached --quiet --ignore-submodules --; then
        log "Refusing to update: repo has uncommitted changes."
        exit 1
    fi
}

rollback_to_previous() {
    local previous_head="$1"
    log "Rolling repo back to $previous_head"
    git reset --hard "$previous_head" --quiet
}

run_smoke_check() {
    if [ -n "$SMOKE_CMD" ]; then
        log "Running custom smoke check..."
        bash -lc "$SMOKE_CMD"
        return
    fi

    log "Running default smoke check..."
    "$VENV/bin/python" - <<'PY'
import gateway.run
import gateway.platforms.slack
import hermes_cli.main
PY
}

push_backup_remote() {
    local current_head="$1"

    if [ "$SKIP_PUSH" = "1" ]; then
        log "Skipping fork sync because HERMES_UPDATE_SKIP_PUSH=1."
        return
    fi

    if [ -z "$PUSH_REMOTE" ]; then
        return
    fi

    log "Pushing $current_head to $PUSH_REMOTE/$PUSH_BRANCH..."
    git push "$PUSH_REMOTE" "$DEPLOY_BRANCH:$PUSH_BRANCH"
}

install_python_deps_if_needed() {
    local previous_head="$1"
    local current_head="$2"

    if git diff --quiet "$previous_head..$current_head" -- "${PYTHON_DEPS[@]}"; then
        return
    fi

    log "Python dependency files changed -- reinstalling editable package..."
    "$VENV/bin/pip" install -e . --quiet
}

install_node_deps_if_needed() {
    local previous_head="$1"
    local current_head="$2"

    if git diff --quiet "$previous_head..$current_head" -- "${NODE_DEPS[@]}"; then
        return
    fi

    log "Node dependency files changed -- reinstalling npm dependencies..."
    if [ -f package-lock.json ]; then
        npm ci --silent
    else
        npm install --silent
    fi
}

mkdir -p "$(dirname "$LOCKFILE")"
exec 9>"$LOCKFILE"
if ! flock -n 9; then
    log "Another update is already in progress; exiting."
    exit 0
fi

cd "$REPO"

git rev-parse --is-inside-work-tree >/dev/null
ensure_clean_repo

log "Fetching $UPSTREAM_REF..."
git fetch "$UPSTREAM_REMOTE" "$UPSTREAM_BRANCH" --quiet

if ! git rev-parse --verify --quiet "$UPSTREAM_REF" >/dev/null; then
    log "Missing upstream ref $UPSTREAM_REF after fetch."
    exit 1
fi

if git show-ref --verify --quiet "refs/heads/$DEPLOY_BRANCH"; then
    current_branch="$(git symbolic-ref --quiet --short HEAD || true)"
    if [ "$current_branch" != "$DEPLOY_BRANCH" ]; then
        log "Checking out deploy branch $DEPLOY_BRANCH..."
        git checkout "$DEPLOY_BRANCH" --quiet
    fi
else
    log "Creating deploy branch $DEPLOY_BRANCH from $UPSTREAM_REF..."
    git checkout -B "$DEPLOY_BRANCH" "$UPSTREAM_REF" --quiet
fi

ensure_clean_repo

previous_head="$(git rev-parse HEAD)"
upstream_head="$(git rev-parse "$UPSTREAM_REF")"

if git merge-base --is-ancestor "$UPSTREAM_REF" HEAD; then
    current_head="$previous_head"
    log "Deploy branch already contains $UPSTREAM_REF ($upstream_head)."
else
    log "Recording last known good commit: $previous_head"
    git update-ref "$LAST_KNOWN_GOOD_REF" "$previous_head"

    log "Rebasing $DEPLOY_BRANCH onto $UPSTREAM_REF..."
    if ! git rebase "$UPSTREAM_REF"; then
        log "Rebase conflict detected while updating $DEPLOY_BRANCH; aborting without restart."
        git rebase --abort || true
        rollback_to_previous "$previous_head"
        exit 1
    fi

    current_head="$(git rev-parse HEAD)"
fi

if ! install_python_deps_if_needed "$previous_head" "$current_head"; then
    log "Python dependency installation failed."
    rollback_to_previous "$previous_head"
    exit 1
fi

if ! install_node_deps_if_needed "$previous_head" "$current_head"; then
    log "Node dependency installation failed."
    rollback_to_previous "$previous_head"
    exit 1
fi

if ! run_smoke_check; then
    log "Smoke check failed."
    rollback_to_previous "$previous_head"
    exit 1
fi

if [ "$SKIP_RESTART" = "1" ]; then
    log "Skipping gateway restart because HERMES_UPDATE_SKIP_RESTART=1."
    git update-ref "$LAST_KNOWN_GOOD_REF" "$current_head"
    if ! push_backup_remote "$current_head"; then
        log "Fork sync failed."
        exit 1
    fi
    log "Prepared update at $(git rev-parse --short HEAD): $(git log -1 --format='%s')"
    exit 0
fi

log "Restarting gateway service $GATEWAY_SERVICE..."
if ! systemctl --user restart "$GATEWAY_SERVICE"; then
    log "Gateway restart failed."
    rollback_to_previous "$previous_head"
    systemctl --user restart "$GATEWAY_SERVICE" || true
    exit 1
fi

sleep "$HEALTH_CHECK_DELAY"
if ! systemctl --user is-active --quiet "$GATEWAY_SERVICE"; then
    log "Gateway failed health check after restart."
    rollback_to_previous "$previous_head"
    systemctl --user restart "$GATEWAY_SERVICE" || true
    exit 1
fi

git update-ref "$LAST_KNOWN_GOOD_REF" "$current_head"
if ! push_backup_remote "$current_head"; then
    log "Fork sync failed."
    exit 1
fi
log "Done. Now at $(git rev-parse --short HEAD): $(git log -1 --format='%s')"
