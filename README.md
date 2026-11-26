# media-studio-gpu-base

The public base image of Media Studio's GPU job: CUDA 12.8, Python 3.12, one base environment with torch, a venv for the FLUX 3 Klein runner and a venv for the LTX-2.5 runner, every package from a lock with hashes. It holds no weights and no private code. The private repository builds a thin top layer on it (its job host and its runners) and serves the final image from its own registry.

Why a separate repository: the heavy part (several GB of torch and CUDA libraries) is public, so it builds here for free on GitHub's runners and is built once, not on every change of the private code.

## What is in it

| path | what |
|---|---|
| `Dockerfile` | the build; comments give the reason of each step |
| `base/requirements.lock` | the base environment (torch 2.10.0 for CUDA 12.8) |
| `runners/flux3klein/requirements.lock` | the FLUX 3 Klein packages over the base |
| `runners/ltx25/requirements.lock` | the LTX-2.5 venv's packages (torch 2.13.0 for CUDA 13.0, natten, comfy-kitchen) |
| `runners/ltx25/requirements.in` | the same, plus the commit of LTX-2 that `ltx-core` and `ltx-pipelines` are built from |

The `.in` files and the header of each lock say how the lock is made. The locks are the single source: change a version here, never in the private repository.

In the image:

- `/opt/media-studio-gpu/base/requirements.lock`, `/opt/media-studio-gpu/runners/{flux3klein,ltx25}/requirements.lock` and the two venvs `/opt/media-studio-gpu/runners/{flux3klein,ltx25}/.venv`.
- The base environment is the interpreter's own site-packages (`/usr/local/bin/python3`, Python in `/opt/python`); the FLUX venv sees it with `--system-site-packages`, the LTX venv does not.
- `/opt/media-studio-gpu-base/` holds the three locks (`base.requirements.lock`, `flux3klein.requirements.lock`, `ltx25.requirements.lock`) and `REVISION`, the commit of this repository (also the label `org.opencontainers.image.revision`). A check in an image built on this one can compare installed versions with them.
- The environment variables of the Dockerfile (`UV_*`, `PYTHONUNBUFFERED`, `HF_HUB_OFFLINE`, ...). No `USER`, no `CMD`, no `WORKDIR`.

The build also checks what needs only public packages: the imports of both runners' libraries, the versions, natten with its CUDA kernels, a Triton compile with gcc, and the OpenSSL 3 and CA bundle the job host needs.

## How it is built

`.github/workflows/build.yml`:

- A pull request builds the image without pushing. That build is the check of every change.
- A push to `main` that changes the Dockerfile, the locks or the workflow, and a run by hand (Actions > build > Run workflow), build and push `ghcr.io/alsami/media-studio-gpu-base:sha-<12 characters of the commit>` and `:latest`. The digest is in the job summary.
- The layer cache is `ghcr.io/alsami/media-studio-gpu-base-cache:layers` (`mode=max`), written by `main` only. The workflow frees about 30 GB of the runner first and prints `df -h` before and after.
- Platform `linux/amd64`, timeout 180 minutes, a build of `main` is never cancelled.

## Raise a package (change a version)

1. Change the `.in` file and regenerate the lock with the command in its header (uv, on any machine; the packages are public).
2. Open a pull request. The build proves the lock installs and the checks pass.
3. The owner merges. The run on `main` pushes the image; copy the digest from its summary.
4. In the private repository, set the pin to `ghcr.io/alsami/media-studio-gpu-base@sha256:<digest>`. Its build is the second gate: it adds its own checks and tests on top of this base, and a base that fails them is not used.

## First time

GHCR creates the package private after the first push. The owner sets it to **Public** once (GitHub > the package `media-studio-gpu-base` > Package settings > Change visibility) so the private repository's build can pull it without credentials. The cache package `media-studio-gpu-base-cache` can stay private; the workflow's token reads and writes it.

## Rules

See [CLAUDE.md](CLAUDE.md). No secrets, no weights and no private code belong here.
