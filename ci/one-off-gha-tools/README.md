# Disposable gha-tools benchmark

This workflow answers PR #467's remaining question: does installing runtime
`gha-tools` in the final layer save enough build time beyond remote caching alone?
It is an experiment on frozen main commit
`37b6aad265003b504922ad44f672bfbfa3bf1dd7`, including #468's image restructuring,
rather than a build of the older PR head. The workflow checks that source out
separately so adding these benchmark files to #467 does not change the comparison.
Production Dockerfiles and workflows are unchanged.

No merge or PR is required. Push the temporary branch
`codex/one-off-gha-tools-benchmark` (or #467's `codex/isolate-gha-tools-layer`)
with a tip commit message
containing `[gha-benchmark-smoke]` for one repetition, or `[run-gha-benchmark]` for
five repetitions. Other pushes skip the experiment. Benchmark execution needs the
upstream repository's runner access and DockerHub secrets; pushing a copy to a fork
does not supply those credentials. The push path uses the input
defaults below; adjust the fallback values in the workflow before pushing if needed.
Do not push a marked commit until the staging publications and runner usage are
intended. The workflow also supports manual dispatch with inputs if temporarily
registered on the default branch; a new side-branch-only workflow cannot receive
its first `workflow_dispatch` without that registration.

Inputs select old/new gha-tools releases, CUDA, Python, architecture and 1–5
repetitions. `previous`/`latest` resolve once to the two newest non-prerelease,
non-draft releases returned by GitHub; explicit versions are preferable for a
repeatable follow-up. Archive SHA-256 checks and base image manifest digests are
frozen in the `benchmark-inputs` artifact. OS is Rocky Linux 8. Both `ci-wheel` and
`ci-conda` use native `linux-{arch}-cpu4` runners and production compression settings.

Each image/repetition runs three variants:

- `baseline`: early pinned gha-tools, no remote build cache.
- `cache`: identical early pinned installation, registry-backed BuildKit cache.
- `isolated`: pinned bootstrap release during construction, runtime release
  installed after the existing final image layout, with registry-backed cache.

Each variant runs a cold build of X, an unchanged rebuild of X, and an update to Y.
Every build uses a new BuildKit container, including cold builds of the baseline.
Only the matching variant/repetition's cold-build cache is imported, and subsequent
builds never overwrite that seed. Variant order alternates across repetitions.
The baseline pins gha-tools to make version updates explicit and comparable; it
is otherwise the same construction path as the cache-only variant.

Elapsed seconds include build execution, image compression/publication and cache
import/export. Builder startup is excluded. Package repositories and other external
services remain live, so cold builds can differ in resolved packages even though
base digests and gha-tools bytes are fixed. Rebuilds intentionally reuse their seed's
resolved packages. A cold build means no imported BuildKit cache, not a cold CDN.

The workflow publishes only uniquely named `rapidsai/staging:gha-bench-*` image and
cache tags, with run ID, attempt, image and repetition in every name. It never writes
production image tags or production cache tags. It needs the same DockerHub secrets
as the normal image workflow. At five repetitions it performs **90 builds**;
start with one repetition to verify the setup. Maximum parallelism is four jobs.

Download `benchmark-summary` for medians/ranges and raw aggregate JSON, the per-job
artifacts for raw BuildKit logs, immutable output digests and layer manifests, and
`benchmark-inputs` for the exact generated Dockerfiles and resolved inputs. Failed
timed builds are recorded and excluded from successful timing statistics; inspect
job failures and sample counts before drawing conclusions. Compare `cache` against
`isolated` for `tools-update`; cold/unchanged cases show overhead. Layer manifests
allow comparison of compressed bytes and digest reuse. This experiment does not
measure consumer pull latency, dependency-update scenarios, or historical update
frequency; do not infer those results from build timings.

After collecting answers, delete `.github/workflows/benchmark-gha-tools.yaml` and
this directory. Artifacts expire after 14 days. Staging tags persist independently;
remove only this experiment's `gha-bench-{run ID}-{attempt}-*` tags through the normal
registry cleanup process after retaining any evidence you need. No automatic
registry deletion is included.
