# Madeira fork notes

How to read: read CORE, then only the Index categories the task touches. Grep `^#{1,2} ` for line numbers.

## Index

| Category | Sections |
|---|---|
| Build | CI branches, cache keys, Official build versus CI |
| Safety | Shared setups, deleting game files |
| Performance | Default changes and their switches |

# CORE

- This is `arabdogwater/Madeira`, a fork of `willfaust/Madeira`. Windows has no Swift or Apple compiler, so GitHub Actions is the only compile.
- Push work to `codex/pr-build-*` first. A push to `main` cancels a running `main` build.
- `tests/host/*.py` assert exact source text. Grep them before changing a line or default, and sign off commits (`git commit -s`).
- Nothing below has run on a device unless it says so.

END CORE

# Build

## CI branches

`.github/workflows/build.yml` runs on `main` and `codex/pr-build-*`, and uploads `Madeira-ipa`. A run reuses finished components from `main`'s cache.

## Cache keys

`tools/build/runtime-components.py` hashes committed blob IDs of the Windows farm, so a changed binary changes the key. `build/windows-runtime/targets.py` keeps `dcomp.dll`, which a rebuild would otherwise replace with Wine's stub.

# Safety

## Shared setups

`GameSetupShare.launchSafeConfig` strips launch-target variables from imported setups, and generated batch lines are caret-escaped. A setup can still change settings, write `.ini` files under `drive_c`, pass flags to the game and set other environment variables.

## Deleting game files

`GameFolderRemoval` only returns the entry's own program folder, and refuses shared folders, links, store games and folders another entry uses.

# Performance

## Default changes and their switches

| Default now | Put it back with |
|---|---|
| D3D12 `quiet-log` on | `quiet-log = 0` |
| Lean diagnostics on, stuck-store check still runs | `env.MADEIRA_LEAN_DIAG = 0` |
| Adaptive 120 Hz at the 60 cap | `env.MADEIRA_PROMOTE_ADAPTIVE = 0` |
| Full client scan every 50 ms | `env.MADEIRA_SRV_FULLSCAN_MS = 10` |

Commit dd39f3b removed lean plus `FASTSYNC_SEM` from the GTA V lists after loading stalled on an 8 GB phone. Test GTA V if lean stays the default.

Direct requests and the lower-memory D3D12 options stay off, under Settings › Performance experiments.

## Official build versus CI

The official v0.2.0 IPA was built on the developer's machine, with `patches/wine-opengl-winios.patch` applied by hand. `tools/build/apply-wine-patches.sh` now does that in CI. To compare a CI build with the official one, count callers of `_ios_wow_base` in the executable (official 3,415) and read `arm64ec-windows/opengl32.dll`'s image base (official `0x180000000`).
