#!/usr/bin/env bash

set -Eeuo pipefail

SERVICE_NAME="${SERVICE_NAME:-koala-signage-agent}"
BINARY_NAME="${BINARY_NAME:-koala-signage-player}"
INSTALL_DIR="${INSTALL_DIR:-/opt/koala-signage}"
CONFIG_PATH="${CONFIG_PATH:-/etc/koala-signage/config.json}"
LOG_LINES="${LOG_LINES:-40}"

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_BINARY="${REPO_DIR}/.build/release/${BINARY_NAME}"
INSTALLED_BINARY="${INSTALL_DIR}/${BINARY_NAME}"
BACKUP_BINARY="${INSTALLED_BINARY}.backup"

log() {
    printf '[deploy] %s\n' "$1"
}

fail() {
    printf '[deploy] ERROR: %s\n' "$1" >&2
    exit 1
}

restore_previous_binary() {
    if [[ -f "${BACKUP_BINARY}" ]]; then
        log "Restoring previous binary..."
        sudo cp "${BACKUP_BINARY}" "${INSTALLED_BINARY}"
        sudo chmod +x "${INSTALLED_BINARY}"
        sudo systemctl restart "${SERVICE_NAME}" || true
    fi
}

trap 'fail "Deployment interrupted at line ${LINENO}."' ERR

command -v git >/dev/null 2>&1 || fail "git is not installed."
command -v swift >/dev/null 2>&1 || fail "Swift is not installed."
command -v systemctl >/dev/null 2>&1 || fail "systemctl is not available."

[[ -d "${REPO_DIR}/.git" ]] || fail "${REPO_DIR} is not a Git repository."
[[ -f "${REPO_DIR}/Package.swift" ]] || fail "Package.swift was not found."
[[ -f "${CONFIG_PATH}" ]] || fail "Configuration not found at ${CONFIG_PATH}."

cd "${REPO_DIR}"

CURRENT_BRANCH="$(git branch --show-current)"
[[ -n "${CURRENT_BRANCH}" ]] || fail "The repository is in detached HEAD state."

if [[ -n "$(git status --porcelain)" ]]; then
    fail "The repository has uncommitted changes. Commit or stash them before deploying."
fi

log "Updating branch ${CURRENT_BRANCH}..."
git fetch --prune
git pull --ff-only

log "Building ${BINARY_NAME} in release mode..."
swift build -c release

[[ -x "${BUILD_BINARY}" ]] || fail "Compiled binary not found at ${BUILD_BINARY}."

log "Stopping ${SERVICE_NAME}..."
sudo systemctl stop "${SERVICE_NAME}"

if [[ -f "${INSTALLED_BINARY}" ]]; then
    log "Backing up current binary..."
    sudo cp "${INSTALLED_BINARY}" "${BACKUP_BINARY}"
fi

log "Installing new binary..."
sudo install -m 0755 "${BUILD_BINARY}" "${INSTALLED_BINARY}"

log "Starting ${SERVICE_NAME}..."
if ! sudo systemctl start "${SERVICE_NAME}"; then
    restore_previous_binary
    fail "The service could not be started. Previous binary restored."
fi

sleep 2

if ! sudo systemctl is-active --quiet "${SERVICE_NAME}"; then
    restore_previous_binary
    fail "The service is not active. Previous binary restored."
fi

log "Deployment completed successfully."
log "Service status:"
sudo systemctl --no-pager --full status "${SERVICE_NAME}"

log "Recent logs:"
sudo journalctl -u "${SERVICE_NAME}" -n "${LOG_LINES}" --no-pager
