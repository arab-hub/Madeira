# Madeira fork notes

How to read: read CORE, then only the Index categories the task touches. Grep `^#{1,2} ` for line numbers.

## Index

| Category | Sections |
|---|---|
| Build | CI branches, cache keys, Official build versus CI |
| Safety | Shared setups, deleting game files |
| Performance | Default changes and their switches |
| Games | Per-game configs, JIT pool size, Address space budget, Cyberpunk 2077 |

# CORE

- Builds run in `arab-hub/Madeira` (org fork of `willfaust/Madeira`, git remote `org`). GitHub disabled Actions on `arabdogwater/Madeira` on 2026-11-06; push there only to keep it in sync. Windows has no Swift or Apple compiler, so GitHub Actions is the only compile.
- Push work to `codex/pr-build-*` first. A push to `main` cancels a running `main` build.
- `tests/host/*.py` assert exact source text. Grep them before changing a line or default, and sign off commits (`git commit -s`).
- Nothing below has run on a device unless it says so.

END CORE

# Build

## CI branches

`.github/workflows/build.yml` runs on `main` and `codex/pr-build-*`, and uploads `Madeira-ipa`. A run reuses finished components from `main`'s cache; a new repository starts cold (about an hour). Jobs use GitHub's `xcode-27` image: the ntdll unix side needs the iOS 27 SDK. Depot's macOS runners stop at Xcode 26.6 (and need an organization repository with public repositories allowed in the runner group), and Depot CI has no macOS, so neither can build the app job.

## Cache keys

`tools/build/runtime-components.py` hashes committed blob IDs of the Windows farm, so a changed binary changes the key. `build/windows-runtime/targets.py` keeps `dcomp.dll`, which a rebuild would otherwise replace with Wine's stub.

## Official build versus CI

The official v0.2.0 IPA was built on the developer's machine, with `patches/wine-opengl-winios.patch` applied by hand. `tools/build/apply-wine-patches.sh` now does that in CI. To compare a CI build with the official one, count callers of `_ios_wow_base` in the executable (official 3,415) and read `arm64ec-windows/opengl32.dll`'s image base (official `0x180000000`).

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

# Games

## Per-game configs

A game's own config is `Library/Application Support/GameConfigs/<FNV-1a 64 of the lowercased Windows path>.cfg` inside Madeira's container (`LibraryPrefs.stableHash`). For a library Steam game the path is its `steamapps\common\<folder>`. Built-in lists live in `GameRecommendations.swift`; `tests/host/check-game-recommendations.py` pins the `all` line, the list count and the ids.

## JIT pool size

A single pool region cannot pass about 880 MB: it must sit below `0x180000000`, above the 128 MB executable window. `pool = 1152` without `pool-split = 1` always shrinks. When anything is mapped just above the window at image load, the early placeholder fails and the pool drops below 500 MB. Big 64-bit games then need `pool-split = 1` (Cyberpunk 2077, 2026-11-05: 464 MB pool, libxess failed with c0000017; 880 MB with it). `env.MADEIRA_X64_IMAGE_NOCOPY = 1` crashed Cyberpunk's REDprelauncher.exe in PocoFoundation.dll, so test it per game.

## Address space budget

iOS gives about 60 GB a program can use: `0x7038004000-0x71ffe00000` (7 GB) and `0x73ffff0000-0x8000000000` (48 GB). `0x1000000000-0x7000000000` is the GPU carveout, even with the extended-virtual-addressing entitlement (the map is already 512 GB). The emulator arena takes 16 GB of the top (`arena-mb = 8192` gives 8 GB; FEX used about 2 GB in Cyberpunk). The 32-bit cage holds `0x7200000000+8 GB` until it is handed out.

A game that reserves more than fits gets `oversize-reserve`: a real part and an unmapped rest. Everything else then lives inside that rest unless `oversize-reserve-top = 1` puts the real part against `0x8000000000`. Use top placement with `arena-mb`, so the arena is not inside the rest either. `[oversize] ml1298 commit ... N MB into the reserve` then lists only the game's own commits; the deepest N is the real part it needs.

The fault handler in `signal_arm64_ios.c` repairs emulator pages (restore R|X, zero-fill) only inside the published arena (`ios_in_fex_arena`), not the fixed hardware band, so a moved arena does not hide the game's access violations.

## Cyberpunk 2077

Reserves 16 GB, 64 GB, 32 GB (fails, falls back to 2 x 1 GB), then five 4 GB pools and more 1 GB ones: about 103 GB, against 55 GB free. Budgets follow the reported RAM (`totalphys`): at 6 GB the load ran out of memory (CrashInfo.json `isOom`), at 12 GB Wwise failed (`wwiseAllocator.cpp`: "Those allocations are not expected to ever need reallocation", and a lost wake-up of `AK::IOThread` at start-up). Its crash files are `users/mobile/AppData/Local/CD Projekt Red/Cyberpunk 2077/CrashInfo.json` and `REDEngine/ReportQueue`. `REDEngineErrorReporter.exe` starts 10 s into every launch and waits; it is not a crash by itself.
