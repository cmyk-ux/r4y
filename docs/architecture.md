# Architecture

```
 user's files (outside repo)             R4Y
 ───────────────────────────             ─────────────────────────────────────────
 game assets ──────────────────────────► r4y-pipeline + r4y-game
                                         (r4y-formats, r4y-shader)
                                                    │
                                                    ▼
                                         cache_dir: converted data
                                                    │
 game executable ─► r4y-loader ────► title code (native x86-64)
                    prepare, map, bind      │ imports
                                            ▼
                                         r4y-hle ── host Windows (shared APIs)
                                            │ D3D12.X
                                            ▼
                                         r4y-gpu ─► host D3D12
                                            │ shaders at pipeline creation
                                            ▼
                                         r4y-shader ◄─► cache_dir
```

Shaders are translated when the title creates a pipeline, from the bytes it
passes, wherever it loaded them from (executable, archive, memory).
Converting them ahead of time from files (`r4y translate --cache`) is
only a warm-up: it fills the same cache, under the same key. With
`--pipelines` it also makes the host pipelines of the title's shader pack
into the pipeline library, from the creation streams the engine would pass
(`r4y-game` builds them, `r4y-gpu` reads them as it reads the
title's), so a run finds them under the names it gives them itself.

## Crates

| Crate | Role |
|-------|------|
| `r4y-core` | config, asset-policy guard, logging |
| `r4y-pe` | read-only PE32+ and import-library analysis |
| `r4y-loader` | prepare, map, bind and start the title image |
| `r4y-hle` | console API implementations, host pass-through policy |
| `r4y-gpu` | D3D12.X objects, command lists and GPU memory → host D3D12 |
| `r4y-shader` | Xbox shader containers → host shaders |
| `r4y-formats` | texture layouts (sizes, tiling, detiling), BCPack data and audio codecs |
| `r4y-pipeline` | converter trait, content-addressed cache |
| `r4y-game` | title-specific format adapters, build identities, hooks and pipeline metadata |
| `apps/r4y` | command-line front end |
| `xtask` | asset-policy check, git hooks |
| `tests/fixtures/hle-probe` | a stand-in "title" (our own code) for loader tests |

Everything except `r4y-game` is platform-level and can be tested with
any Xbox Series title.

## Import resolution

For every `dll!function` the title imports, in order:

1. our implementation in `r4y-hle::modules` (always wins);
2. the host's own function, if `HostPolicy` allows that DLL;
3. an export of a DLL the title ships beside its executable, mapped like
   the executable (only DLLs neither of the above serves);
4. a generated stub that names the import when called (`--unimplemented
   trap` breaks into the debugger and aborts; `zero` logs once and returns 0).

`LoadLibrary*` of a console-only DLL we implement (e.g. `xgameruntime.dll`)
returns a pseudo handle; `GetProcAddress` on it finds our functions.
`LoadLibrary*` of a title DLL returns its mapped image, mapping it first if
nothing imports it. By name, as by import, a title gets only host DLLs
`HostPolicy` passes through, and `GetProcAddress` on one returns our
override where import binding would.
`QueryApiImpl` hands out our runtime objects by provider and interface id
(`r4y-hle::modules::xgameruntime` lists the areas); online areas answer
as an offline console. Game saves are files under `R4Y_DATA_DIR`.

Title storage is a drive on the console, and titles build paths on that.
`r4y-hle::modules::files` binds every path-taking title import
(kernel32 and the C/C++ runtime) and rewrites paths on a virtual drive to
the host folder behind it; persistent local storage is one such drive over
a folder under `R4Y_DATA_DIR`. Other paths reach the host unchanged.

An exe's code reaches its static TLS as slot 0; mapped as a DLL it gets
another slot, so the loader redirects those loads (`r4y-loader::tls`).
`r4y run --execute` installs a crash reporter that names faults as
`module+rva` and unwinds the faulting thread's stack
(`r4y-loader::crash`).

`r4y census` shows this classification without running anything (it
does not map title DLLs; `r4y run` without `--execute` does).

## Shaders

`r4y_shader::ir::build` turns a native program into SSA, one
instruction per machine instruction. `r4y_shader::structure` then
removes EXEC: lane masks become per-lane booleans, wave-wide mask tests
become per-lane branches, and vector instructions keep a guard only where
a lane can reach them with its EXEC bit clear. `r4y_shader::range::build`
runs both, again where a bound on the index of a register-relative move
(`v_movrel*`) is proven on the per-lane form, so the move names only the
registers it can reach. `r4y_shader::resource`
traces each descriptor and scalar memory address to the root parameter it
comes from (table, heap, root descriptor or constant). A descriptor a
waterfall loop reads from the first lane (`v_readfirstlane_b32`) is traced
to the per-lane load or choice that gives each lane its own (a mask's
`v_cndmask_b32`, or an if/else whose arms each set it: traced on the paths
the lanes take, from structurisation), and accessed with a non-uniform heap
index in one pass. `r4y translate`
runs every shader it finds (containers, SGD5 files) through these and
lists what they cannot handle yet.
