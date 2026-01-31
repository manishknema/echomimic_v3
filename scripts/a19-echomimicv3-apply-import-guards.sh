#!/usr/bin/env bash
# a19-echomimicv3-apply-import-guards.sh
#
# Purpose:
#   Apply minimal, deterministic import-guard patches so that:
#     - python infer_flash_pro.py --help runs without import-time traceback
#   Specifically:
#     - Ensure FLASH_ATTN_2_AVAILABLE / FLASH_ATTN_3_AVAILABLE are always defined.
#     - Guard distributed/fuser symbols so single-node "help gate" does not fail.
#
# VIGYAN_ROLE=DEV_TOOL
#
# Canonical invocation:
#   sudo bash /vigyan/projects/ai-video/echomimic-v3/scripts/a19-echomimicv3-apply-import-guards.sh \
#     --repo /vigyan/projects/ai-video/echomimic-v3
#
# Exit codes:
#   0 success
#   2 usage error
#   3 patch error

set -euo pipefail

LOG_TAG="a19-echomimicv3-apply-import-guards"
LOG_FILE="/var/log/vigyan/a19-echomimicv3-apply-import-guards.log"

log() {
  local ts_local ts_utc
  ts_local="$(date +"%Y-%m-%dT%H:%M:%S%z")"
  ts_utc="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  echo "${ts_local} (UTC ${ts_utc}) [${LOG_TAG}] $*" | tee -a "${LOG_FILE}"
}

die() {
  log "ERROR: $*"
  exit 3
}

usage() {
  cat <<'USAGE'
Usage:
  a19-echomimicv3-apply-import-guards.sh --repo <path>

Options:
  --repo PATH   Repo root (default: /vigyan/projects/ai-video/echomimic-v3)
USAGE
}

REPO="/vigyan/projects/ai-video/echomimic-v3"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo) REPO="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown arg: $1" ;;
  esac
done

[[ -d "${REPO}" ]] || die "Repo not found: ${REPO}"

patch_flash_flags() {
  local f="$1"
  [[ -f "$f" ]] || return 0

  # If marker already present, skip.
  if grep -q "VIGYAN_IMPORT_GUARD_FLASH_ATTN" "$f"; then
    log "SKIP (already patched): $f"
    return 0
  fi

  log "PATCH: $f (define FLASH_ATTN_* flags deterministically)"

  # Prepend guard block near top, after any shebang or encoding comment.
  # We insert after the first line if it's a shebang, else at top.
  local tmp
  tmp="$(mktemp)"
  {
    read -r first || true
    if [[ "${first:-}" == "#!"* ]]; then
      echo "$first"
      echo
      cat <<'BLOCK'
# VIGYAN_IMPORT_GUARD_FLASH_ATTN: ensure flags always exist at import-time
FLASH_ATTN_2_AVAILABLE = False
FLASH_ATTN_3_AVAILABLE = False
try:
    import flash_attn  # noqa: F401
    FLASH_ATTN_2_AVAILABLE = True
except Exception:
    FLASH_ATTN_2_AVAILABLE = False

try:
    import flash_attn_interface  # noqa: F401
    FLASH_ATTN_3_AVAILABLE = True
except Exception:
    FLASH_ATTN_3_AVAILABLE = False
BLOCK
      echo
      cat
    else
      # No shebang: insert at very top
      cat <<'BLOCK'
# VIGYAN_IMPORT_GUARD_FLASH_ATTN: ensure flags always exist at import-time
FLASH_ATTN_2_AVAILABLE = False
FLASH_ATTN_3_AVAILABLE = False
try:
    import flash_attn  # noqa: F401
    FLASH_ATTN_2_AVAILABLE = True
except Exception:
    FLASH_ATTN_2_AVAILABLE = False

try:
    import flash_attn_interface  # noqa: F401
    FLASH_ATTN_3_AVAILABLE = True
except Exception:
    FLASH_ATTN_3_AVAILABLE = False
BLOCK
      echo
      echo "$first"
      cat
    fi
  } <"$f" >"$tmp"

  cp -f "$tmp" "$f"
  rm -f "$tmp"
}

patch_dist_init() {
  local f="$1"
  [[ -f "$f" ]] || return 0

  # If marker already present, skip.
  if grep -q "VIGYAN_IMPORT_GUARD_DIST" "$f"; then
    log "SKIP (already patched): $f"
    return 0
  fi

  log "PATCH: $f (guard distributed symbols for single-node help gate)"

  # Append a guarded export shim at end (minimizes conflict with upstream content).
  cat >>"$f" <<'BLOCK'

# VIGYAN_IMPORT_GUARD_DIST:
# The upstream research stack may assume distributed/fuser symbols exist.
# For single-node local benchmarks and for --help gate, we must not crash at import time.
# These shims provide clear errors only if the distributed path is actually invoked.
def _vigyan_dist_unavailable(name: str):
    raise RuntimeError(
        f"{name} is unavailable in this single-node benchmark build. "
        "Distributed / fuser stack is intentionally optional."
    )

for _sym in [
    "get_sequence_parallel_rank",
    "get_sequence_parallel_world_size",
    "get_sp_group",
    "get_world_group",
    "init_distributed_environment",
    "initialize_model_parallel",
    "xFuserLongContextAttention",
]:
    if _sym not in globals():
        globals()[_sym] = (lambda _n=_sym: _vigyan_dist_unavailable(_n))
BLOCK
}

FLASH_FILES=(
  "${REPO}/src/wan_transformer3d_audio.py"
  "${REPO}/src/wan_transformer3d_audio_2512.py"
)

DIST_INIT="${REPO}/src/dist/__init__.py"

for f in "${FLASH_FILES[@]}"; do
  patch_flash_flags "$f"
done

patch_dist_init "$DIST_INIT"

log "DONE. Import-guard patches applied."

