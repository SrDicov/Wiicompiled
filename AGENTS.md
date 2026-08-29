# AGENTS.md

## What this repo is

Static recompilation of Mario Kart Wii (PAL `RMCP01`) into a native x86-64 executable. No emulator/JIT at runtime. Three parts:

- `translator/` — .NET 8 (C#) static recompiler: DOL/REL parser → PowerPC decode → IR/SSA lift → emits C++. CLI entry: `translator/src/Translator.Cli`.
- `runtime/` — C++17 runtime (HLE of Wii OS/GX/audio/input under `runtime/src/hle`), built on vendored aurora (`aurora-main/`) for rendering/windowing.
- `Launcher/` — PowerShell setup/installer tooling consumed by Wheel Wizard; Linux build script `Launcher/local-build.sh`.

Platforms: Windows (LLVM-MinGW, Release only) **and** Linux x86_64 (clang, Release only). CI tests only the translator on Windows.

## Commands

```powershell
dotnet build translator/Translator.sln -c Release
dotnet test translator/Translator.sln -c Release
```

Linux native build (requires clang, cmake, ninja, dotnet, legally dumped PAL `main.dol`/`StaticR.rel` in `Assets/`):

```bash
Launcher/local-build.sh --output-dir /path/to/output --profile base
```

- Default translator tests need no game binaries and no host C++ compiler.
- Single test filter: `dotnet test ... --filter <Name>`.
- `RECOMP_GENERIC_DOL=<path>` opt-in generic DOL translation test.
- CI (`.github/workflows/build.yml`) only runs translator build+test on `windows-latest`. Runtime is NOT CI-checked locally.

## Hard constraints

- **Never commit Nintendo code, assets, or game data** (`main.dol`, `StaticR.rel`, `Code.pul`, disc images). Legal rule, no exceptions. `Launcher/Test-PayloadBoundary.ps1` enforces forbidden filenames/extensions in release payloads; manifests pin SHA-256s but reference local `Assets/` that stay untracked.
- Runtime builds **only Release config**, clang, x86_64. Windows requires LLVM-MinGW; Linux uses system clang. Debug builds fatal. MSVC not supported.
- `translation.allow_unsupported_instructions` stays `false`; an "on" build can never ship.
- Base-game behavior must match real hardware exactly — don't "fix" original bugs. Only Retro Rewind profiles patch behavior.
- `*.patch` files must keep LF endings (`.gitattributes`); don't let editors normalize them.

## Pipeline order (matters)

Translation is 4 steps against a manifest (`projects/mkwii/recomp.yml` for MKWii):
1. `translate-recursive <entry> --project <manifest>` → C++ per function
2. `generate-data-init` → data section init + `RuntimeConfig.h`
3. `emit-build-shards` → `shards.cmake` covering generated sources + `runtime/src`
4. CMake+Ninja+Clang compiles everything into one executable

Discovery is recursive from entry points unless `function_map` seeds boundaries (`projects/mkwii/MAP.txt`). Relative paths resolve from `workspace_root` in the manifest.

Linux pipeline uses `Launcher/local-build.sh` which wraps the same 4 steps; `translate-recursive` etc. are called via the translator CLI.

## Duplication gotcha

Pinned facts (addresses, hashes, versions) are duplicated between `recomp.yml` (the owner), C# constants, C++ headers, and PowerShell scripts because three consumers can't read YAML. If you change one copy, update all — `Launcher/Test-PinnedFacts.ps1` fails the release when they diverge.

## Conventions

- Translator tests intentionally exclude old asset/compiler-backed suites in `Translator.Tests/*.csproj` — don't re-enable them casually; they're slow and red on clean setups.
- Errors are deliberately loud (fail fast, never swallow) — preserve that style.
- PR descriptions must be human-written per `CONTRIBUTING.md`; be ready to explain every line you submit. Keep PRs to one change.

## Linux specifics

- Dawn: package provider (prebuilt) by default on Linux; `AURORA_DAWN_PROVIDER=vendor` forces from-source (required for musl).
- Build dir override: `--build-dir` to isolate multiple toolchains (e.g. glibc vs musl).
- Assets: place `main.dol` and `StaticR.rel` in repo root `Assets/` before building.
- Output: `WiiCompiled` executable + `wii_bootstrap/` + `dsp_coef.bin` + `initial_pipeline_cache.db` + `local-build.json` in `--output-dir`.