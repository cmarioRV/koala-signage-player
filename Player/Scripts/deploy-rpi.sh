#!/usr/bin/env bash

set -Eeuo pipefail

SERVICE_NAME="${SERVICE_NAME:-koala-signage-agent}"
BINARY_NAME="${BINARY_NAME:-koala-signage-player}"
INSTALL_DIR="${INSTALL_DIR:-/opt/koala-signage}"
LOG_LINES="${LOG_LINES:-40}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
REPO_DIR="$(git -C "${PROJECT_DIR}" rev-parse --show-toplevel 2>/dev/null || true)"

BUILD_BINARY="${PROJECT_DIR}/.build/release/${BINARY_NAME}"
INSTALLED_BINARY="${INSTALL_DIR}/${BINARY_NAME}"
BACKUP_BINARY="${INSTALLED_BINARY}.backup"

log() {
    printf '[deploy] %s\n' "$1"
}

fail() {
    printf '[deploy] ERROR: %s\n' "$1" >&2
    exit 1
}

rollback() {
    if [[ -f "${BACKUP_BINARY}" ]]; then
        log "Restoring previous binary..."
        sudo install -m 0755 "${BACKUP_BINARY}" "${INSTALLED_BINARY}"
        sudo systemctl restart "${SERVICE_NAME}" || true
    fi
}

command -v git >/dev/null 2>&1 || fail "git is not installed."
command -v swift >/dev/null 2>&1 || fail "Swift is not installed."
command -v systemctl >/dev/null 2>&1 || fail "systemctl is not available."

[[ -n "${REPO_DIR}" ]] || fail "Could not locate the Git repository root."
[[ -f "${PROJECT_DIR}/Package.swift" ]] || fail "Package.swift not found in ${PROJECT_DIR}."

cd "${REPO_DIR}"

if [[ -n "$(git status --porcelain)" ]]; then
    fail "The repository has uncommitted changes. Commit or stash them first."
fi

BRANCH="$(git branch --show-current)"
[[ -n "${BRANCH}" ]] || fail "Detached HEAD is not supported."

log "Updating branch ${BRANCH}..."
git fetch --prune
git pull --ff-only

cd "${PROJECT_DIR}"

log "Building ${BINARY_NAME} in release mode..."
swift build -c release

[[ -x "${BUILD_BINARY}" ]] || fail "Compiled binary not found at ${BUILD_BINARY}."

log "Stopping ${SERVICE_NAME}..."
sudo systemctl stop "${SERVICE_NAME}"

if [[ -f "${INSTALLED_BINARY}" ]]; then
    sudo cp "${INSTALLED_BINARY}" "${BACKUP_BINARY}"
fi

log "Installing new binary..."
sudo install -m 0755 "${BUILD_BINARY}" "${INSTALLED_BINARY}"

log "Starting ${SERVICE_NAME}..."
if ! sudo systemctl start "${SERVICE_NAME}"; then
    rollback
    fail "Service failed to start."
fi

sleep 2

if ! sudo systemctl is-active --quiet "${SERVICE_NAME}"; then
    rollback
    fail "Service is not active after deployment."
fi

log "Deployment completed successfully."
sudo systemctl --no-pager --full status "${SERVICE_NAME}"
sudo journalctl -u "${SERVICE_NAME}" -n "${LOG_LINES}" --no-pager
