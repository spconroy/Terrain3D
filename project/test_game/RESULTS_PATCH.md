# Incremental region texture update: before / after

Branch `incremental-regions` (from `streaming` 8de77e8). Same scene, GPU and settings as RESULTS.md (release DLL, GTX 1080 Ti,
1024 regions, 1 m spacing, height RF + control RF + colour RGBA8 with mipmaps). Run with
`godot --game --path project --gpu-index 1 --windowed res://test_game/main.tscn -- mode=cost|shot|move|ddir [spread=1] [batch=1] [reserve=24] [nocol=1] tag=<dir>`.
Other sessions were using the machine, so single numbers vary by 10 to 50 percent between runs.

## Commits
- 6929153 `import_images(..., update)` parameter, full-region source skips duplicate and blit.
- cd82997 Regions keep a slot (= texture array layer); add writes only its own layer; free slots are reused; arrays grow in steps of 8 layers
  (or `reserve_region_slots(n)`); mipmaps only for regions without them or edited; `get_min_max` reads RF data directly (was 30 ms per image).
- ace67be Dynamic game collision refreshes its shape data instead of freeing and recreating the body on a region change; fix `set_data_directory` crash.

## Add / remove cost (mode=cost, one region per call, camera over the terrain, collision on)
| | before | after |
|---|---|---|
| add, N=2..6 median | 89 ms | 18 ms |
| add, N=19..24 median | 362 ms | 46 ms (about 18 ms plus about 27 ms collision refresh, see below) |
| add, N=19..24, collision disabled | n/a | 16 ms |
| add that has to grow the arrays (N=1, 9, 17) | n/a | 110 to 320 ms, once per 8 regions or once with `reserve_region_slots` |
| unload_region at N=24, median | 260 ms | 28 ms (1 ms with collision disabled) |
| 4 adds in one frame | 406 ms | 266 ms (150 ms collision disabled) |
| 4 unloads with update=false then one update_maps | 3.8 ms | 3.3 ms (empty-ish terrain, not meaningful) |
| VRAM per region | 13.59 MB | 14.18 MB (24 layers allocated) |

Growth is the remaining O(N) cost: `texture_2d_layered_create` of the whole array. It does not happen in steady state.

## Moving window, 500 m/s, 7 x 3 regions, 14 columns (3 adds + 3 removes per column)
| mode | before | after |
|---|---|---|
| burst (6 ops one frame) | 1900 ms per column, max 2500 | 209 ms median, max 296 (non batched) |
| burst, batch=1 (update=false, one update_maps) | n/a | 91 to 142 ms median in two runs, max 170 |
| spread (1 op per frame) | 328 ms median, max 407 | 41 ms median, max 84 |
| frames between ops, median | 1.4 ms | 1.4 ms |
Steady VRAM after the run: 334 MB before (21 regions) vs 501 MB after with 24 layers allocated. Reading is higher than 24 x 14.2 + 48 = 388 MB;
I did not isolate why (suspect RenderingDevice upload staging buffers, not verified). No second copy of the arrays exists in steady state
(slots stay 24) and the old arrays are freed on growth (a leak found and fixed during the work).

## Target check
- Under 30 ms per region at N=24: met for removal (28 ms with collision, 1 ms without) and for add without collision (16 ms).
  Add with collision on is 46 ms. The extra 27 ms is Terrain3DCollision::update(rebuild) in DYNAMIC_GAME mode (height sampling for the shapes around the camera
  target), run on every region_map_changed. It is independent of N. Not reduced further here: it needs a change to only refresh shapes near the changed region.
- No 2x VRAM spike in steady state. A growth step still briefly holds the old and new array.

## Visual check (mode=shot, 4x4 regions tinted per region, then 4 removed, 4 added into freed slots, then all removed and 2 added)
Screenshots in D:/Captures/panzerstrike/scratch/t3d_patch/f/ (`shot_a_4x4`, `shot_b_removed4`, `shot_c_readded`, `shot_d_two_after_clear`).
I viewed shot_a and shot_c: every region has its own colour and height, boundaries have no seams, removed regions are holes (no stale layer drawn),
re-added regions use the freed slots and draw correctly. All four frames are pixel-identical (max channel difference 0) to the same sequence rendered with the
unpatched DLL.

## Crash fix (mode=ddir)
`terrain.data_directory = dir` on a node already in the tree with region files present crashed before (reproduced with the patched build too) and now loads the 4 regions and draws.
Cause: `_destroy_collision()` kept the collision object with its terrain pointer set; it then handled `region_map_changed` while the new data was loading, before the
data had its region size. `set_data_directory` now frees it completely.

## Not verified / not done
- Editor workflows (painting, undo/redo of region add/remove, region labels, instancer) were not run. The editor still uses `update_maps(all_regions=true)`, which does a full rebuild at the current capacity.
- Behaviour change: `get_region_map()` values and `_region_locations` shader uniform are now indexed by slot. `get_region_locations()` is still a dense list but its order is no longer the layer order. Shader code is unchanged.
- `get_height_maps()` etc. now contain null entries for free slots.
- Linux, macOS, debug builds not built. Threading not attempted. Compressed colour maps and mixed mipmap states fall back to a full rebuild (untested).
- Item 2 (mipmaps) is in the same commit as item 3 rather than separate.
