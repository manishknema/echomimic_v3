#!/usr/bin/env bash
# a19-echomimicv3-scan.sh
#
# Purpose:
#   Deterministically scan the EchoMimic v3 repo for:
#     - all imports (imports.csv)
#     - third-party modules list (third_party.txt)
#     - heuristic module-scope undefined names (name_errors.txt)
#
# VIGYAN_ROLE=DEV_TOOL
#
# Canonical invocation:
#   sudo ./a19-echomimicv3-scan.sh \
#     --repo /vigyan/projects/ai-video/echomimic-v3 \
#     --out-root /vigyan/projects/ai-video/echomimicv3 \
#     --project project-01 --clone clone-01 \
#     --image python:3.11-slim
#
# Output location:
#   /vigyan/projects/ai-video/echomimicv3/<project>/<clone>/logs/scan/<timestamp>/
#
# Notes:
# - This uses a minimal python container to run static analysis only.
# - It does not install repo deps and does not execute repo code.
# - It only needs the repo mounted read-only and the workspace mounted read-write.
#
set -euo pipefail

LOG_TAG="a19-echomimicv3-scan"
LOG_FILE="/var/log/vigyan/a19-echomimicv3-scan.log"

log() {
  local ts_local ts_utc
  ts_local="$(date +"%Y-%m-%dT%H:%M:%S%z")"
  ts_utc="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  echo "${ts_local} (UTC ${ts_utc}) [${LOG_TAG}] $*" | tee -a "${LOG_FILE}"
}

die() {
  log "ERROR: $*"
  exit 2
}

REPO="/vigyan/projects/ai-video/echomimic-v3"
OUT_ROOT="/vigyan/projects/ai-video/echomimicv3"
PROJECT="project-01"
CLONE="clone-01"
IMAGE="python:3.11-slim"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo) REPO="${2:-}"; shift 2 ;;
    --out-root) OUT_ROOT="${2:-}"; shift 2 ;;
    --project) PROJECT="${2:-}"; shift 2 ;;
    --clone) CLONE="${2:-}"; shift 2 ;;
    --image) IMAGE="${2:-}"; shift 2 ;;
    -h|--help)
      cat <<USAGE
Usage: sudo $0 [--repo PATH] [--out-root PATH] --project P --clone C [--image IMAGE]
USAGE
      exit 0
      ;;
    *) die "Unknown arg: $1" ;;
  esac
done

[[ -d "${REPO}" ]] || die "Repo not found: ${REPO}"
[[ -d "${OUT_ROOT}" ]] || die "Out root not found: ${OUT_ROOT}"

WS="${OUT_ROOT}/${PROJECT}/${CLONE}"
for d in capture out logs tmp; do
  mkdir -p "${WS}/${d}"
done

STAMP="$(date +"%Y%m%d-%H%M%S")"
SCAN_DIR="${WS}/logs/scan/${STAMP}"
mkdir -p "${SCAN_DIR}"

# We expect tools/scan_imports.py to be present in the repo OR you can place it alongside and mount it.
# We'll mount the repo read-only at /repo and workspace at /ws.
# We'll also copy the script into the scan dir for traceability (optional).
if [[ -f "${REPO}/tools/scan_imports.py" ]]; then
  SCAN_SCRIPT_HOST="${REPO}/tools/scan_imports.py"
else
  die "Missing ${REPO}/tools/scan_imports.py (place scan_imports.py there first)"
fi

log "Running static scan using image=${IMAGE}"
log "Repo=${REPO}"
log "ScanDir=${SCAN_DIR}"

docker run --rm \
  -v "${REPO}:/repo:ro" \
  -v "${WS}:/ws" \
  -w /repo \
  "${IMAGE}" \
  bash -lc "
    set -euo pipefail
    mkdir -p /ws/logs/scan/${STAMP}/reports
    cp -f /repo/tools/scan_imports.py /ws/logs/scan/${STAMP}/scan_imports.py
    python /ws/logs/scan/${STAMP}/scan_imports.py /repo /ws/logs/scan/${STAMP}/reports
    ls -la /ws/logs/scan/${STAMP}/reports
  "

log "DONE. Reports are in: ${SCAN_DIR}/reports"

