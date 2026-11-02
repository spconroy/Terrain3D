# Region add/remove cost and streaming API measurements

Branch `measure-region-cost`, based on `streaming` (upstream main 1.2-dev plus 8de77e8: update_streaming / unload_region).
Scripts: `main.gd`, `main.tscn`. Run with
`godot --game --path project --gpu-index 1 --resolution 1280x720 --windowed res://test_game/main.tscn -- mode=cost|decomp|move|stream|twonodes` (add `spread=1` for mode=move).
Raw logs and screenshots: `D:/Captures/panzerstrike/scratch/terrain3d_fork_test/`.

## Setup
- Godot 4.8-dev (fbae1c408), GTX 1080 Ti, 1280x720 window, vsync off, Vulkan Forward+.
- Windows release DLL (1,482,240 B, contains the streaming API). It was loaded by the editor binary by copying it over the
  (git-ignored) `libterrain.windows.debug.x86_64.dll` name, because the debug DLL found in the checkout (8.7 MB) was an older build
  without `unload_region`. A first run with that unoptimised debug DLL was 5-10x slower (0.6 to 1.6 s per add) and is not reported.
- Region size 1024, vertex_spacing 1.0, images 1024x1024: height FORMAT_RF, control FORMAT_RF, colour FORMAT_RGBA8.
  `import_images(..., offset 0, scale 1.0)`; heights are pre-scaled in the source image (see the scale note below).
- Timings are main-thread wall time of the call. "next frame" is the delta of the following frame.

## (a)(b) Add cost vs. resident region count (24 regions, one per frame)
| N resident after add | import_images ms |
|---|---|
| 1 | 53 |
| 2..6 (median) | 89 |
| 12 | 206 |
| 19..24 (median) | 391 |
| 24 | 436 |
| 2..24 median / worst | 210 / 472 |

Cost grows linearly: about 17 ms per resident region on top of about 50 ms.
Next frame after an add: median 1.6 ms, worst 2.4 ms (frame two: occasional 10-15 ms). The GPU side is cheap; the cost is CPU time in the call.
Decomposition (`mode=decomp`): `update_maps(TYPE_MAX, all_regions=true)` alone is 10 ms at N=1, 65 at N=4, 91 at N=8, 230 at N=16,
294 ms at N=24 (height 90, control 79, colour 138 ms). So about 70 percent of an add at N=24 is the full texture-array rebuild;
the remainder (duplicate, blit, sanitize_maps) is about 140 ms.
`update_maps(..., generate_mipmaps=true)` adds about 40 ms at N=24 (it regenerates every region's colour mipmaps, not only the new one).
`import_images` with `scale != 1` or `offset != 0` runs a per-pixel get_pixel/set_pixel loop: 443 ms at N=24 (scale 1.5).
Pre-scale the images and pass scale 1.0, offset 0.

## (c) Batching
- 4 adds in one frame: 417 ms total (N=0..3). 4 adds in 4 frames: 396 ms total (81, 93, 104, 118 ms). No saving: every `import_images` rebuilds everything.
- 4 more adds in one frame with 4 resident: 689 ms.
- 4 x `unload_region(loc, false)` then one `update_maps`: 3 ms, but measured on a nearly empty terrain (not meaningful at N=24).

## (d) Removal
- `unload_region(loc)` (update=true), 12 removals from N=24 down: median 274 ms, worst 409 ms (first 334, last 195).
- `remove_regionl(loc)` (soft delete), 12 removals from N=12 down: median 86 ms, worst 180 ms. It does not free memory until a save, so it is not comparable.

## (e) VRAM (RENDERING_INFO_VIDEO_MEM_USED)
47.8 MB before, 373.9 MB after 24 regions: 13.59 MB per region (3 maps x 4 MiB plus colour mipmaps).
Rebuilding the texture arrays doubles it transiently: one spread-mode run read 627 MB (22 resident) at the end before the old
arrays were freed; after 90 frames a rerun settled to 347 MB. Budget about 2x the resident size at peak.

## (f) Camera moving 500 m/s over 14 columns, window 7 columns x 3 rows (2 behind, current, 4 ahead), 21 regions resident
Each column crossing = 3 adds + 3 `unload_region`.
- Burst (all 6 ops in one frame): 14 hitches, each 1.90 s median, 2.08 s worst. Other frames median 1.37 ms.
- Spread (1 op per frame): 75 op frames, median 333 ms, worst 587 ms. Other frames median 1.34 ms (p99 27 ms, max 327 ms).
Neither reaches 60 fps; spreading only turns a 2 s stall into six 0.3 to 0.6 s stalls. Steady-state frames are fine.

## Streaming API (mode=stream)
- 10 regions generated at run time, `save_directory(dir)`: files `terrain3d_00_00.res` .. `terrain3d_09_00.res`.
- New Terrain3D with `data_directory = dir` set BEFORE `add_child`: all 10 regions load eagerly (resident 10). `update_streaming` then evicts.
- `terrain.data.update_streaming(PackedVector3Array([pos]), 1500)` with a target stepping 1 km: resident x-locations tracked the target
  ([0,1] -> [0,1,2] -> [1,2,3] ... -> [8,9]), as expected for region-centre distance <= 1500. 51 to 120 ms per call that loads/evicts one region (main thread, synchronous).
- Property `region_streaming_radius = 1500` with the camera as target: the automatic update works but needs real time
  (every 30 physics ticks, 0.5 s at 60 Hz); after 1.5 s the resident set followed the camera ([3,4,5] at x=4608, [8,9] at x=9728).
- `add_streaming_target(node3d)` keeps regions near that node resident (camera at x=512, node at x=8704: resident [0,1,7,8,9]); `remove_streaming_target` returns to [0,1].
- Run-time generated regions: with `data_directory` empty `update_streaming` is a no-op (6 regions stay resident, nothing evicted).
  With a `data_directory` set, modified in-memory regions are saved on eviction and reloaded later (resident [0,1], files for 2..5 appear;
  moving to x=5632 gives [4,5]; back gives [0,1]). So it works for run-time generated regions too, with the directory acting as a swap file.
  Streaming never creates regions; it only loads existing files.
- With the property set the camera is also a target, so explicit `update_streaming` calls are unioned with the camera position at the next tick.
- Crash (reproduced): assigning `data_directory` on a Terrain3D already in the tree, with region files in the directory, crashes:
  `CrashHandlerException: Program crashed`, backtrace in libterrain via `Object::emit_signalp` -> `CallableCustomExtension::call`, GDScript line `terrain.data_directory = dir`.
  `set_data_directory` frees and re-creates `_data` while signal connections remain. The PR does not touch that function; not checked against stock upstream main.
  Workaround used: set `data_directory` before `add_child`.
- Not verified: streaming from a thread, collision and instancer behaviour while regions come and go, regions beyond +/-16.

## Two nodes (mode=twonodes)
Terrain3D A: vertex_spacing 1, one region with a 121 x 121 m hole (`set_control_hole`). Terrain3D B: vertex_spacing 10, regions (0,0) and (1,0), heights offset -150.
Screenshots `twonodes_a_low.png`, `_c_hole`, `_d_coarse_only`, `_e_fine_only`: both nodes draw; the hole shows B underneath (or sky when B is hidden); each node alone draws.
The "neither node draws" case from the game was NOT reproduced (default material only, one fine region; the high view `_b_high` is dark and inconclusive).

## Is a patch needed
Yes, for a 5 km ahead / 2 km behind window. A column step costs about 1.9 s (burst) and every op scales with resident count.
Sketch (not implemented):
1. `import_images(..., update := true)` and batched `unload_region(..., false)`, then a single `update_maps()` per frame: removes 5 of 6 rebuilds per column (estimate 1.9 s -> about 0.7 s: 3 x 140 ms blit plus one 300 ms rebuild).
2. Generate colour mipmaps only for the regions just added (`update_maps` with `p_all_regions` regenerates every region's mipmaps).
3. Incremental texture-array update: keep the layered RIDs, update one layer per added region and reuse free slots on removal instead of recreating all layers; removes the O(N) term and the 2x transient VRAM.
4. Do the image duplicate/blit/sanitize work off the main thread and apply the result in one frame.
