/* OpenCharm-authored build guard — NOT part of upstream xiph/rnnoise.
 *
 * Re-vendoring RNNoise only ever copies an explicit list of upstream files
 * (see the Task 6 report / repo history for that list); this file is not on
 * it and always survives a re-vendor.
 *
 * rnnoise_data.c (~74 MB of trained model weights) is intentionally not
 * committed to git (see ../../../.gitignore) — Tools/fetch-rnnoise-model.sh
 * downloads and checksum-verifies it at build time (`make fetch-model`,
 * wired into `make gen`/`build`/`test`). If someone builds this target
 * without having fetched it, fail *compilation of this target* with a clear,
 * actionable compiler diagnostic instead of either a confusing "undefined
 * symbol: rnnoise_arrays" link error, or — as an earlier attempt at this
 * guard did — a Package.swift-level fatalError that crashed manifest
 * evaluation for the *entire* dependency graph (breaking Xcode/SourceKit,
 * `swift package describe`/`resolve`, and any sibling package that merely
 * depends on AudioPipeline by path, none of which need CRNNoise compiled
 * just to resolve the graph).
 */
#if !__has_include("rnnoise_data.c")
#error "RNNoise model missing: run `make fetch-model` from the repo root, then retry."
#endif
