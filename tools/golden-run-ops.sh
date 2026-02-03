#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
golden-run-ops.sh — historical Flash-Pro CLI validation harness

This script reproduces the original CLI experiment environment.
It assumes all models are already present on disk.

Required environment variables:
  IMAGE_REF    Container image reference (digest recommended)
  MODEL_ROOT   Root directory containing echomimic-v3 models
  WORK_ROOT    Workspace root for inputs/outputs

Optional:
  PROJECT_SLUG (default: project-01)
  RUN_SLUG     (default: run-01)

No model downloads are performed.
EOF
}

[[ "${1:-}" == "-h" || "${1:-}" == "--help" ]] && { usage; exit 0; }

# --------------------------------------------------
# Required inputs
# --------------------------------------------------
IMAGE_REF="${IMAGE_REF:-ghcr.io/manishknema/echomimic-v3@sha256:7fca2a577f8de8141028097075e150fbc5ca42ae305fe712eeab223c3c971f93}"
MODEL_ROOT="${MODEL_ROOT:-/models}"
WORK_ROOT="${WORK_ROOT:-/workspace}"

PROJECT_SLUG="${PROJECT_SLUG:-project-01}"
RUN_SLUG="${RUN_SLUG:-run-01}"

# --------------------------------------------------
# Derived paths (historical layout)
# --------------------------------------------------
FLASH_PRO="${MODEL_ROOT}/echomimic-v3/flash-pro"

WAN="${FLASH_PRO}/Wan2.1-Fun-V1.1-1.3B-InP"
W2V="${FLASH_PRO}/chinese-wav2vec2-base"
TRANSFORMER="${FLASH_PRO}/transformer/diffusion_pytorch_model.safetensors"

REF="${WORK_ROOT}/${PROJECT_SLUG}/input/ref.png"
AUDIO="${WORK_ROOT}/${PROJECT_SLUG}/input/audio.wav"
OUT="${WORK_ROOT}/${PROJECT_SLUG}/out/${RUN_SLUG}"

mkdir -p "${OUT}"

# --------------------------------------------------
# Sanity checks (fail fast)
# --------------------------------------------------
test -f "${REF}" || { echo "Missing ref image: ${REF}" >&2; exit 1; }
test -f "${AUDIO}" || { echo "Missing audio file: ${AUDIO}" >&2; exit 1; }

test -d "${WAN}" || { echo "Missing WAN base: ${WAN}" >&2; exit 1; }
test -f "${WAN}/Wan2.1_VAE.pth" || { echo "Missing VAE" >&2; exit 1; }
test -d "${WAN}/tokenizer" || { echo "Missing tokenizer dir" >&2; exit 1; }
test -d "${WAN}/text_encoder" || { echo "Missing text_encoder dir" >&2; exit 1; }
test -d "${WAN}/image_encoder" || { echo "Missing image_encoder dir" >&2; exit 1; }

test -d "${W2V}" || { echo "Missing wav2vec2 dir" >&2; exit 1; }
test -f "${TRANSFORMER}" || { echo "Missing transformer finetune" >&2; exit 1; }

# --------------------------------------------------
# Run
# --------------------------------------------------
docker run --rm -it --gpus all \
  --ipc=host \
  --ulimit memlock=-1 \
  --ulimit stack=67108864 \
  -e WAN="${WAN}" \
  -e W2V="${W2V}" \
  -e TRANSFORMER="${TRANSFORMER}" \
  -e REF="${REF}" \
  -e AUDIO="${AUDIO}" \
  -e OUT="${OUT}" \
  -v "${MODEL_ROOT}:${MODEL_ROOT}" \
  -v "${WORK_ROOT}:${WORK_ROOT}" \
  -w /work \
  "${IMAGE_REF}" bash -lc '

set -euo pipefail
echo "START: $(date -Is)"

python infer_flash_pro.py \
  --config_path "/work/config/wan2.1/wan_civitai.yaml" \
  --model_name "${WAN}" \
  --transformer_path "${TRANSFORMER}" \
  --vae_path "${WAN}/Wan2.1_VAE.pth" \
  --wav2vec_model_dir "${W2V}" \
  --image_path "${REF}" \
  --audio_path "${AUDIO}" \
  --save_path "${OUT}" \
  \
  --sample_size 512 512 \
  --video_length 360 \
  --fps 24 \
  \
  --num_inference_steps 30 \
  --guidance_scale 5.0 \
  --audio_scale 4.0 \
  --audio_guidance_scale 8.0 \
  \
  --use_dynamic_cfg \
  --use_dynamic_acfg \
  \
  --weight_dtype float16 \
  --GPU_memory_mode model_cpu_offload

echo "DONE: ${OUT}"
'
