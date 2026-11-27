# The public base of the GPU job image: CUDA 12.8 runtime, a pinned Python, one base environment with torch, and one venv
# per open-model runner (FLUX 3 Klein over the base, LTX-2.5 and Kandinsky 6 with their own torch). No weights, no job host, no runner code:
# the private repository adds those on top and pins this image by digest.
# Every package comes from a lock with hashes; build-time checks that need only public packages run here.
# Built by .github/workflows/build.yml and published as ghcr.io/alsami/media-studio-gpu-base.

# 12.8 is the newest CUDA runtime driver 570 supports, the driver of serverless GPUs on Container Apps. The index digest
# Docker Hub answered for this tag on 16 Nov 2026. One ARG so the source stage and the image use the same one.
ARG CUDA_IMAGE=nvidia/cuda:12.8.2-runtime-ubuntu24.04@sha256:7e62235c5d6f22a57ec8ba51f1583634fdbbf4b08a15b42dc1a60f086145c210

# LTX-2's two packages at one commit of github.com/Lightricks/LTX-2: git fetches exactly that commit and the check stops
# the build if HEAD is another, so the commit is the pin. Upstream publishes no wheels of them. The CUDA image is reused
# (it is pulled anyway); only the two package folders leave this stage.
FROM ${CUDA_IMAGE} AS ltx-source
ARG LTX_COMMIT=f0f2f8607189c78a72420b2b63cb1975b5eca179
RUN apt-get update \
 && apt-get install -y --no-install-recommends git ca-certificates \
 && rm -rf /var/lib/apt/lists/*
# The commit is written twice, here and in requirements.in (the lock's source of the two packages); one must not drift.
COPY runners/ltx25/requirements.in /tmp/ltx25.requirements.in
RUN test "$(grep -c "@${LTX_COMMIT}#" /tmp/ltx25.requirements.in)" = 2
WORKDIR /src/LTX-2
RUN git init -q \
 && git fetch -q --depth 1 https://github.com/Lightricks/LTX-2 "$LTX_COMMIT" \
 && git checkout -q FETCH_HEAD \
 && test "$(git rev-parse HEAD)" = "$LTX_COMMIT"

FROM ${CUDA_IMAGE}

# uv installs a pinned Python and the locked packages; its image by the index digest GHCR answered on 16 Nov 2026.
COPY --from=ghcr.io/astral-sh/uv:0.13.8@sha256:5cc1805e2426484abca4ad46ea783bab281fdb225fd82d8ce6d66a81254bac85 /uv /usr/local/bin/uv

# No cache in a layer; nothing in the image reaches Hugging Face: the weights come only from a mounted share.
ENV UV_NO_CACHE=1 \
    UV_PYTHON_INSTALL_DIR=/opt/python \
    UV_PYTHON_PREFERENCE=only-managed \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    HF_HUB_OFFLINE=1 \
    HF_HUB_DISABLE_TELEMETRY=1

# The job host talks to Blob over TLS, for which .NET loads the system's OpenSSL 3 and trusts its CA bundle. The CUDA base
# image should have both, from the ca-certificates it installs for its package keys; the build stops with a sentence if
# either is missing, so a new base digest cannot take them away unnoticed.
RUN if ! ldconfig -p | grep -q 'libssl\.so\.3'; then echo "The base image has no libssl.so.3, which the job host needs for Blob over TLS." >&2; exit 1; fi \
 && if [ ! -s /etc/ssl/certs/ca-certificates.crt ]; then echo "The base image has no CA bundle, which the job host needs to trust Blob." >&2; exit 1; fi

# The base environment is the interpreter's own site-packages, not a venv: a runner's venv with
# --system-site-packages sees it, so torch and its CUDA libraries (about 3 GB) are in the image once.
# The paths under /opt/media-studio-gpu are a contract with the private top layer (its runners and venv paths).
COPY base/requirements.lock /opt/media-studio-gpu/base/requirements.lock
RUN uv python install 3.12.13 \
 && ln -s "$(uv python find 3.12.13)" /usr/local/bin/python3 \
 && uv pip install --python /usr/local/bin/python3 --system --break-system-packages --require-hashes --only-binary :all: \
      -r /opt/media-studio-gpu/base/requirements.lock

# FLUX 3 Image Klein's packages, each with its hash and without resolving (--no-deps): the lock is complete over the
# base. The check proves at build time what was read only in the source: diffusers 0.43.0 has the distilled FLUX 3
# blocks, transformers has the classes they import, and the prompt upsampler's block can be removed. No weights are
# needed for that.
COPY runners/flux3klein/requirements.lock /opt/media-studio-gpu/runners/flux3klein/requirements.lock
RUN uv venv --python /usr/local/bin/python3 --system-site-packages /opt/media-studio-gpu/runners/flux3klein/.venv \
 && uv pip install --python /opt/media-studio-gpu/runners/flux3klein/.venv/bin/python --require-hashes --no-deps --only-binary :all: \
      -r /opt/media-studio-gpu/runners/flux3klein/requirements.lock \
 && /opt/media-studio-gpu/runners/flux3klein/.venv/bin/python -c "import torchvision; from diffusers.modular_pipelines import Flux3DistilledAutoBlocks; blocks = Flux3DistilledAutoBlocks(); blocks.sub_blocks.pop('prompt_upsampler'); print('flux3klein blocks', list(blocks.sub_blocks), 'torchvision', torchvision.__version__)"

# LTX-2.5's runner in a venv of its own, not over the base: LTX-2 is developed on a newer torch than the base's 2.10.0,
# and PyPI's torch 2.13.0 is built for CUDA 13.0, which the A100 hosts' driver 580 supports. The lock first, each
# package with its hash; then ltx-core and ltx-pipelines from the commit above, without an index and with the locked
# uv-build as their build backend. The check imports both pipelines, the decoder's backends, the blocks the runner
# builds again or passes on, comfy-kitchen and the ltx-core types an int8 policy builds on, which needs no GPU and no
# weights, and prints the versions a run will use. It stops when natten or its CUDA kernels (libnatten) cannot be
# imported, which needs no GPU either: without them the diffusion decoder falls back to Triton, which is slower.
# Triton compiles a small C module against Python's headers the first time a kernel runs, and torch 2.13.0 routes plain
# tensor operations through Triton kernels, so a run needs gcc and the C library's headers: a first run failed without
# them at the text encoder. Ubuntu's packages of the base image's release, not pinned further. The check builds
# compiler_check.c with Triton's own build step, as a run will.
RUN apt-get update \
 && apt-get install -y --no-install-recommends gcc libc6-dev \
 && rm -rf /var/lib/apt/lists/*
COPY runners/ltx25/requirements.lock /opt/media-studio-gpu/runners/ltx25/requirements.lock
COPY runners/ltx25/compiler_check.c /tmp/ltx/compiler_check.c
COPY --from=ltx-source /src/LTX-2/packages/ltx-core /tmp/ltx/ltx-core
COPY --from=ltx-source /src/LTX-2/packages/ltx-pipelines /tmp/ltx/ltx-pipelines
RUN uv venv --python /usr/local/bin/python3 /opt/media-studio-gpu/runners/ltx25/.venv \
 && uv pip install --python /opt/media-studio-gpu/runners/ltx25/.venv/bin/python --require-hashes --no-deps --only-binary :all: \
      -r /opt/media-studio-gpu/runners/ltx25/requirements.lock \
 && uv pip install --python /opt/media-studio-gpu/runners/ltx25/.venv/bin/python --no-deps --no-index --no-build-isolation \
      /tmp/ltx/ltx-core /tmp/ltx/ltx-pipelines \
 && /opt/media-studio-gpu/runners/ltx25/.venv/bin/python -c "from pathlib import Path; from triton.runtime.build import compile_module_from_src; compile_module_from_src(Path('/tmp/ltx/compiler_check.c').read_text(), 'compiler_check'); print('ltx25 compiler ok')" \
 && rm -rf /tmp/ltx /root/.triton \
 && /opt/media-studio-gpu/runners/ltx25/.venv/bin/python -c "import torch, transformers, triton, comfy_kitchen; from comfy_kitchen.tensor import TensorWiseINT8Layout; from ltx_core.quantization.policy import QuantizationPolicy, compose_quantization; from ltx_core.loader.units import FuseRule; from ltx_core.loader.sd_ops import SDOps; from ltx_core.loader.module_ops import ModuleOps; from ltx_core.model.transformer import LTXV_MODEL_COMFY_RENAMING_MAP; from ltx_core.text_encoders.gemma import GemmaTextEncoderConfigurator, get_gemma_ops, resolve_gemma_weight_paths; from ltx_core.loader.simple_builder import SimpleBuilder; from ltx_pipelines.utils.blocks import PromptEncoder; from ltx_pipelines.dfr_pipeline import DFRPipeline; from ltx_pipelines.distilled import DistilledPipeline; from ltx_pipelines.utils.media_io import encode_video; from ltx_pipelines.utils.blocks import DiffusionStage; from ltx_pipelines.utils.samplers import euler_denoising_loop; from ltx_pipelines.utils.helpers import cleanup_memory; from ltx_pipelines.dfr_helpers.ops import DETAILING_LORA_STRENGTH; from ltx_core.loader.registry import ModelRegistry; from ltx_core.loader.placement import NO_RETENTION, Placement, RetentionPolicy; from ltx_core.model.video_vae.transformer import natten_available; from ltx_core.model.video_vae.transformer.fallback_na import triton_na_available; import natten; assert natten_available() and natten.HAS_LIBNATTEN, 'natten or libnatten cannot be imported'; print('ltx25 torch', torch.__version__, 'cuda', torch.version.cuda, 'transformers', transformers.__version__, 'triton', triton.__version__, 'natten', natten_available(), 'libnatten', natten.HAS_LIBNATTEN, natten.__version__, 'comfy_kitchen', comfy_kitchen.__file__)"

# Kandinsky 6.0 Video Lite's runner (the distilled 3B model, image to video, through Hugging Face Diffusers) in a venv of
# its own, with the same torch 2.13.0 for CUDA 13.0 as the LTX venv, whose checks prove that build on the A100 hosts'
# driver. Diffusers has Kandinsky 6 from 0.42.0 as Kandinsky6TI2VAPipeline (text or image to video and audio) and
# Kandinsky6SRPipeline (the VSR super resolution); both run on this Python 3.12. The check imports both pipelines, the
# classes they are built from and what the export needs (PyAV for encode_video, accelerate for the model offload), which
# needs no GPU and no weights.
COPY runners/kandinsky6/requirements.lock /opt/media-studio-gpu/runners/kandinsky6/requirements.lock
RUN uv venv --python /usr/local/bin/python3 /opt/media-studio-gpu/runners/kandinsky6/.venv \
 && uv pip install --python /opt/media-studio-gpu/runners/kandinsky6/.venv/bin/python --require-hashes --no-deps --only-binary :all: \
      -r /opt/media-studio-gpu/runners/kandinsky6/requirements.lock \
 && /opt/media-studio-gpu/runners/kandinsky6/.venv/bin/python -c "import torch, diffusers, transformers, accelerate, av; from diffusers import Kandinsky6TI2VAPipeline, Kandinsky6SRPipeline, Kandinsky6Transformer3DModel, Kandinsky6SRTransformer3DModel, Kandinsky6SRVAE, Kandinsky6SRLatentUpscalerBank, MMAudioVAE, MMAudioVocoder, AutoencoderKLHunyuanVideo, PiflowScheduler, FlowMatchEulerDiscreteScheduler; from diffusers.utils import encode_video, export_to_video; from transformers import CLIPTextModel, CLIPTokenizer, Qwen2_5_VLForConditionalGeneration, Qwen2_5_VLProcessor; print('kandinsky6 venv ok: diffusers', diffusers.__version__, 'torch', torch.__version__, 'cuda', torch.version.cuda, 'transformers', transformers.__version__)"

# The locks again at a fixed path, so a check in an image built on this one can compare installed versions with them,
# and the commit of this repository the image was built from (last, so a new commit does not rebuild the layers above).
ARG BASE_COMMIT=unknown
COPY base/requirements.lock /opt/media-studio-gpu-base/base.requirements.lock
COPY runners/flux3klein/requirements.lock /opt/media-studio-gpu-base/flux3klein.requirements.lock
COPY runners/ltx25/requirements.lock /opt/media-studio-gpu-base/ltx25.requirements.lock
COPY runners/kandinsky6/requirements.lock /opt/media-studio-gpu-base/kandinsky6.requirements.lock
RUN echo "$BASE_COMMIT" > /opt/media-studio-gpu-base/REVISION

LABEL org.opencontainers.image.title="media-studio-gpu-base" \
      org.opencontainers.image.description="CUDA 12.8, Python 3.12 and the locked packages of the FLUX 3 Klein, LTX-2.5 and Kandinsky 6 runners. No weights." \
      org.opencontainers.image.source="https://github.com/alsami/media-studio-gpu-base" \
      org.opencontainers.image.revision="$BASE_COMMIT"
