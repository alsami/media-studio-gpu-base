## Project

The public base image of Media Studio's GPU job (`ghcr.io/alsami/media-studio-gpu-base`). Start with [README.md](README.md). There is no application code here: a Dockerfile, locks and a workflow. The private repository pins the built image by digest and adds its own layer.

## Rules

- **The locks are the source of truth** for the public packages. Change a `.in` file and regenerate its lock with the command in the lock's header; never edit hashes by hand, except where the header says a line was added by hand.
- **No secrets, no weights, no private code, no names of cloud resources.** The image must be safe to publish.
- A build-time check belongs here only if it needs public packages alone. Anything that imports the private repository's code stays in its repository.
- Docs describe what the build does, not what was planned.
- Do not run Docker builds on a development machine for this repository's sake; the pull request's build is the check.

## Commits and pull requests

- One commit per change, a change being one thing that can be understood and reverted on its own.
- Every message starts with a prefix and a colon: `build:`, `ci:`, `docs:`, `chore:`, `fix:`.
- **Every change goes through a pull request that the owner merges.** Never push to `main`. A pull request builds the image without pushing; wait for it to be green.
- After the merge, the run on `main` pushes the image and prints its digest in the job summary. The private repository takes it from there.
