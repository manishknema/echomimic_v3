IMG="vigyan/echomimic-v3:vigyan-core-20260131-numpyfix"
IMG2="vigyan/echomimic-v3:canonical-py311-cu128-flashattn-libxcb1"
IMG3="vigyan/echomimic-v3:canonical-py311-cu128-flashattn-runtime-libs"

PROJECT_SLUG="project-01"
CLONE_SLUG="clone-01"
WS="/vigyan/projects/ai-video2/echomimicv3/${PROJECT_SLUG}/${CLONE_SLUG}"
REF="${WS}/capture/ref.png"
AUDIO="${WS}/capture/base.wav"

# ---------------------------
# Configurable roots (override via env before running)
# ---------------------------
HF_BASE_ROOT="${HF_BASE_ROOT:-/vigyan/hf-base-models}"
HF_DOMAIN="${HF_DOMAIN:-ai-video2}"
MODEL_CACHE_ROOT="${MODEL_CACHE_ROOT:-/vigyan/model-cache}"
MODEL_CACHE_DOMAIN_ROOT="${MODEL_CACHE_ROOT}/${HF_DOMAIN}"

# Flash-Pro layout derived from HF_BASE_ROOT + HF_DOMAIN
FLASH_PRO="${HF_BASE_ROOT}/${HF_DOMAIN}/echomimic-v3/flash-pro"
W2V="${FLASH_PRO}/chinese-wav2vec2-base"
WAN="${FLASH_PRO}/Wan2.1-Fun-V1.1-1.3B-InP"
VAE="${WAN}/Wan2.1_VAE.pth"
TRANSFORMER="${FLASH_PRO}/transformer/diffusion_pytorch_model.safetensors"

OUT="${WS}/out/flashpro-$(date +%Y%m%d-%H%M%S)"
sudo mkdir -p "${OUT}"
sudo chown -R manish:vigyan-devcache "${OUT}"
sudo chmod -R g+rwX "${OUT}"

# Sanity checks (host)
ls -la "${W2V}/config.json"
ls -la "${WAN}/config.json" "${VAE}"
ls -la "${TRANSFORMER}"

sudo docker run --rm -it \
  --gpus all \
  --ipc=host \
  --ulimit memlock=-1 \
  --ulimit stack=67108864 \
  -e PYTORCH_CUDA_ALLOC_CONF=expandable_segments:True \
  -e HF_HOME="${MODEL_CACHE_DOMAIN_ROOT}/hf-home" \
  -e HUGGINGFACE_HUB_CACHE="${MODEL_CACHE_DOMAIN_ROOT}/hf-hub" \
  -e TRANSFORMERS_CACHE="${MODEL_CACHE_DOMAIN_ROOT}/transformers" \
  -e XDG_CACHE_HOME="${MODEL_CACHE_DOMAIN_ROOT}/xdg-cache" \
  -e WAN="${WAN}" \
  -e VAE="${VAE}" \
  -e W2V="${W2V}" \
  -e TRANSFORMER="${TRANSFORMER}" \
  -e REF="${REF}" \
  -e AUDIO="${AUDIO}" \
  -e OUT="${OUT}" \
  -v "${MODEL_CACHE_DOMAIN_ROOT}:${MODEL_CACHE_DOMAIN_ROOT}" \
  -v "${HF_BASE_ROOT}/${HF_DOMAIN}:${HF_BASE_ROOT}/${HF_DOMAIN}" \
  -v /vigyan/projects/ai-video2/echomimicv3:/vigyan/projects/ai-video2/echomimicv3 \
  -v /vigyan/projects/ai-video/echomimic-v3:/work/echomimic-v3:ro \
  -w /work/echomimic-v3 \
  "${IMG3}" bash -lc '

set -euo pipefail
echo "START: $(date -Is)"
echo "HF_BASE_ROOT='${HF_BASE_ROOT:-/vigyan/hf-base-models}'"
echo "HF_DOMAIN='${HF_DOMAIN:-ai-video2}'"
echo "MODEL_CACHE_DOMAIN_ROOT='${MODEL_CACHE_DOMAIN_ROOT:-/vigyan/model-cache/ai-video2}'"
echo "WAN=${WAN}"
echo "VAE=${VAE}"
echo "W2V=${W2V}"
echo "TRANSFORMER=${TRANSFORMER}"

ls -la "${WAN}/config.json" "${VAE}"
ls -la "${W2V}/config.json"
ls -la "${TRANSFORMER}"

echo "Running Ultra-Quality Dynamic Inference..."

python infer_flash_pro.py \
  --config_path "/work/echomimic-v3/config/wan2.1/wan_civitai.yaml" \
  --model_name "${WAN}" \
  --transformer_path "${TRANSFORMER}" \
  --vae_path "${VAE}" \
  --wav2vec_model_dir "${W2V}" \
  --image_path "${REF}" \
  --audio_path "${AUDIO}" \
  --save_path "${OUT}" \
  \
  --prompt "cinematic lighting, realistic person, speaking with expressive hand gestures, waving hands, moving arms, sharp focus, 4k, detailed texture" \
  --negative_prompt "blurry, low quality, static hands, frozen arms, bad anatomy, distortion" \
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

chmod -R 777 "${OUT}"
echo "Done. Saved to ${OUT}"
'

sudo chown -R manish:vigyan-devcache "${OUT}" || true
sudo chmod -R g+rwX "${OUT}" || true
echo "OUTPUT DIR: ${OUT}"

