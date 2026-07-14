#!/usr/bin/env bash

set -Eeuo pipefail

SERVICE_NAME="${SERVICE_NAME:-koala-signage-agent}"
BINARY_NAME="${BINARY_NAME:-koala-signage-player}"
INSTALL_DIR="${INSTALL_DIR:-/opt/koala-signage}"
LOG_LINES="${LOG_LINES:-40}"
SKIP_GIT_UPDATE="${SKIP_GIT_UPDATE:-0}"
CONFIG_PATH="${CONFIG_PATH:-/etc/koala-signage/config.json}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
REPO_DIR="$(git -C "${PROJECT_DIR}" rev-parse --show-toplevel 2>/dev/null || true)"

BUILD_BINARY="${PROJECT_DIR}/.build/release/${BINARY_NAME}"
INSTALLED_BINARY="${INSTALL_DIR}/${BINARY_NAME}"
BACKUP_BINARY="${INSTALLED_BINARY}.backup"
EXAMPLE_CONFIG="${PROJECT_DIR}/Resources/config.example.json"
BACKUP_CONFIG="${CONFIG_PATH}.backup"
DEPLOYMENT_STARTED=0

log() {
    printf '[deploy] %s\n' "$1"
}

fail() {
    printf '[deploy] ERROR: %s\n' "$1" >&2
    if [[ "${DEPLOYMENT_STARTED}" == "1" ]]; then
        rollback
    fi
    exit 1
}

rollback() {
    set +e
    DEPLOYMENT_STARTED=0
    if [[ -f "${BACKUP_BINARY}" ]]; then
        log "Restoring previous binary..."
        sudo install -m 0755 "${BACKUP_BINARY}" "${INSTALLED_BINARY}"
    fi
    if [[ -f "${BACKUP_CONFIG}" ]]; then
        log "Restoring previous configuration..."
        sudo install -m 0644 "${BACKUP_CONFIG}" "${CONFIG_PATH}"
    fi
    sudo systemctl restart "${SERVICE_NAME}" || true
}

on_error() {
    local exit_code=$?
    if [[ "${DEPLOYMENT_STARTED}" == "1" ]]; then
        rollback
    fi
    exit "${exit_code}"
}

trap on_error ERR

command -v git >/dev/null 2>&1 || fail "git is not installed."
command -v swift >/dev/null 2>&1 || fail "Swift is not installed."
command -v systemctl >/dev/null 2>&1 || fail "systemctl is not available."

[[ -n "${REPO_DIR}" ]] || fail "Could not locate the Git repository root."
[[ -f "${PROJECT_DIR}/Package.swift" ]] || fail "Package.swift not found in ${PROJECT_DIR}."
[[ -f "${EXAMPLE_CONFIG}" ]] || fail "Example configuration not found at ${EXAMPLE_CONFIG}."
[[ -f "${CONFIG_PATH}" ]] || fail "Configuration not found at ${CONFIG_PATH}. Run install.sh first."

APP_VERSION="$(sed -nE 's/^[[:space:]]*"appVersion"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/p' "${EXAMPLE_CONFIG}" | head -n 1)"
[[ -n "${APP_VERSION}" ]] || fail "Could not read appVersion from ${EXAMPLE_CONFIG}."

cd "${REPO_DIR}"

if [[ -n "$(git status --porcelain)" ]]; then
    fail "The repository has uncommitted changes. Commit or stash them first."
fi

BRANCH="$(git branch --show-current)"
[[ -n "${BRANCH}" ]] || fail "Detached HEAD is not supported."

if [[ "${SKIP_GIT_UPDATE}" == "1" ]]; then
    log "Skipping Git update because SKIP_GIT_UPDATE=1."
else
    log "Updating branch ${BRANCH}..."
    git fetch --prune
    git pull --ff-only
fi

cd "${PROJECT_DIR}"

log "Building ${BINARY_NAME} in release mode..."
swift build -c release

[[ -x "${BUILD_BINARY}" ]] || fail "Compiled binary not found at ${BUILD_BINARY}."

log "Stopping ${SERVICE_NAME}..."
sudo systemctl stop "${SERVICE_NAME}"
DEPLOYMENT_STARTED=1

if [[ -f "${INSTALLED_BINARY}" ]]; then
    sudo cp "${INSTALLED_BINARY}" "${BACKUP_BINARY}"
fi
sudo cp "${CONFIG_PATH}" "${BACKUP_CONFIG}"

log "Installing new binary..."
sudo install -m 0755 "${BUILD_BINARY}" "${INSTALLED_BINARY}"

log "Updating appVersion in the preserved configuration to ${APP_VERSION}..."
sudo sed -i -E \
    "s|(\"appVersion\"[[:space:]]*:[[:space:]]*\")[^\"]*(\")|\\1${APP_VERSION}\\2|" \
    "${CONFIG_PATH}"
sudo grep -qE "\"appVersion\"[[:space:]]*:[[:space:]]*\"${APP_VERSION}\"" "${CONFIG_PATH}" \
    || fail "Could not update appVersion in ${CONFIG_PATH}."

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

DEPLOYMENT_STARTED=0

log "Deployment completed successfully."
sudo systemctl --no-pager --full status "${SERVICE_NAME}"
sudo journalctl -u "${SERVICE_NAME}" -n "${LOG_LINES}" --no-pager
