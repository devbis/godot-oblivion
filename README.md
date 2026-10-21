# OpenOB

OpenOB is an early Godot prototype that reads Oblivion's installed `Data` directory at runtime. It does not include game data. The current milestone indexes the base game's ESM4 cells and BSA archives, converts NIF meshes and diffuse textures, and assembles the player and placed NPCs on the original 71-bone skeleton. It reads original idle, directional walk, fast-movement, and jump KF sequences and plays them in Godot. It applies NPC FaceGen head shapes, expression morphs, and blinking. Static collision is generated from render triangles as a temporary approximation; original Havok collision is not implemented.

## Requirements

- Godot 4.7.2 stable, using the built-in Jolt 3D physics backend. The Godot engine is installed separately and is not included in this repository.
- CMake 3.22+, a C++20 compiler, and zlib.
- The matching `godot-cpp` 4.7 API source tree at `extern/godot-cpp` and the `nifly` NIF parser source at `extern/nifly`. These third-party sources are not included in this repository.
- The base Oblivion game installed locally, including `Oblivion.esm` and its BSA files.

## Build

Build and run the standalone data inspector:

```sh
cmake -S native -B build
cmake --build build
ctest --test-dir build --output-on-failure
./build/oblivion-inspect "/path/to/Oblivion/Data" ImperialDungeon01
```

The GDExtension build uses the 4.7 API in `extern/godot-cpp` plus `nifly` to parse NIF geometry, skin weights, skeleton nodes, and KF transform tracks. These third-party dependencies are supplied locally and are excluded from this repository.

```sh
godot --headless --editor --path . --quit
```

Run the project and provide the game's `Data` directory either as an environment variable or a user argument:

```sh
OBLIVION_DATA_DIR="/path/to/Oblivion/Data" godot --path .
godot --path . -- --game-data "/path/to/Oblivion/Data"
```

The in-game reader searches for `Oblivion.esm` and all `.bsa` files in that directory. Loose files override archived resources. The GDScript controller uses editable placeholder movement values; those values are not presented as verified Oblivion physics.

## Current support

- Oblivion BSA version 103 directory parsing and zlib asset extraction.
- Base-game ESM4 CELL, placed-reference, door-target, NPC AI-package, item world/equipment model-path, and float GMST indexing. ARMO/CLOT world models come from `MOD2`/`MOD4`; wearable models use `MODL`/`MOD3`.
- Imperial Prison discovery through editor ID `ImperialDungeon01`.
- Asynchronous ESM/BSA indexing and NIF parsing through `OblivionData`, plus case-insensitive loose/BSA asset lookup.
- Static NIF mesh extraction with node transforms, triangle/UV/normal arrays, diffuse texture paths, and per-shape alpha blend/test flags; parsing runs on a worker thread and Godot resource creation runs on the main thread.
- Diffuse DDS, TGA, PNG, and JPEG loading from loose files or BSA archives. DDS files with incomplete mip chains are decoded from their top mip and receive a regenerated mip chain.
- The Imperial male body is assembled from original upper body, lower body, hand, and foot meshes, with the original human head and hair. Skin weights bind those meshes to `Characters/_male/skeleton.nif`.
- The default male avatar is currently dressed with the base game's `LowerShirt05` and `LowerPants05` CLOT models, looked up by ESM editor ID and skinned to the same skeleton. This outfit choice is a prototype default; its match to the original player's starting inventory has not been verified. Female model paths are available from the same records.
- Original idle, forward/backward/left/right walking, four fast-movement directions, and jump start/loop/land KF sequences are loaded at runtime. The prototype samples translations linearly and rotations with quaternion slerp; WASD selects direction, Shift selects the fast sequence, and airborne/floor transitions select the jump sequences. NPC route actors also switch between forward and fast-forward clips based on their route speed.
- The centered third-person camera stays directly behind the player's facing direction. Captured horizontal mouse motion immediately turns the player; vertical motion adjusts pitch. Mouse wheel and trackpad pan gestures adjust camera distance, and the trackpad magnify gesture also zooms. A sphere sweep checks the full camera path against streamed cell collision, shortening the camera distance before it reaches a wall and easing back to the selected distance once clear. Zoom changes move the camera directly, without waiting for a physics tick. Press `T` or click the face-view button to move the camera in front of the player for expression checks; the close-up tracks the animated head and allows very close inspection. Toggle again to restore the prior camera distance and pitch. The pointer is captured after the cell loads, captured again when the app regains focus, and released with Escape. Distance, sensitivity, and pitch remain prototype values because the original camera measurements are not established.
- Press `E` near a placed world item to pick it up. The HUD names the nearby pickup and counts inventory items, including duplicate copies. Press `I` to inspect inventory quantities and equipped gear; click an ARMO, CLOT, or WEAP entry to equip it again. ARMO/CLOT items use their biped-slot masks and replace overlapping gear; WEAP items attach to the right hand. Other supported item types go into the prototype inventory only. When no item is nearby, `E` follows the next linked door.
- A linked-door transition unloads the current cell's NPC nodes, loads the target cell's geometry and placed NPCs, and applies the door's destination position and heading. Player inventory and avatar remain across the transition.
- Placed `ACHR` NPC references use their ESM transform, race sex flag, hair record and color, original hair/clothing/armor/weapon NIFs, and the original rig. The ESM `BMDT` biped-slot mask prevents carried armor and clothing from overlapping: `DOFT` outfit pieces take precedence, and actors without a default outfit select non-overlapping inventory armor before clothing. One inventory weapon is attached to the right hand; the active weapon slot is not parsed yet, so this uses the first WEAP entry. Uriel, Baurus, Glenroy, and Renault follow their intro-scene marker routes; Valen Dreth paces between his two taunt markers. Route speeds use each target's ESM AI-package `Always run` flag when available. Route selection is still curated for this cell rather than resolved through the original package-condition evaluator. Actors use approximate `CharacterBody3D` capsules, snap to generated walkable geometry when a floor is found, and use gravity and floor snapping there; in cells with no generated floor, their ESM route height is retained.
- NPC base parsing retains each record's `FGGS`/`FGGA` FaceGen coefficients and race. Human NPCs use the Imperial human head template; Argonians, Khajiit, and Orcs select their own head NIF plus matching EGM/TRI data. The current Imperial Prison cell exercises individual human coefficients; the nonhuman paths are available for cells that contain those races. The player's original hair keeps its NIF alpha cutout and follows the head bone. Original eyes, mouth, teeth, and tongue meshes are placed in the skeleton's head space. Each head's expression and static morphs are loaded with its own TRI data, and NPCs and player blink on independent timers. Press `F` to cycle the nearest NPC through expressions, or `G` to cycle the player's expression; both blend smoothly and skip expressions absent from that head mesh. The player can cycle through the default human face and distinct human NPC FaceGen profiles with `C`; each selection rebuilds the original head from that NPC's stored coefficients. This is a profile preview, not the original character creation slider system.
- Generated mesh, texture, and static concave-collider resources are cached under the ignored `.godot/openob/cache` directory using source hashes and the converter version.
- Static `ConcavePolygonShape3D` colliders are built from the render geometry for placed NIFs, with collision enabled from either triangle side; sky, dust, and light-beam shapes are excluded. They do not reproduce original Havok collision data. The player starts at the placed `CGPlayerStartMarker` (`0x00032AB5`); the first valid NPC reference is only a fallback if that marker is absent. At startup and after a linked door transition, the controller raycasts for a walkable generated surface and places the player on it. Avatar meshes are offset by the rig root's rest height so the visible soles align with the capsule base. An invisible 6×6 m support is created only when no walkable surface is found below the destination.
- Fixture coverage for ESM4 links/transforms and BSA extraction.

Unsupported formats and features include plugin load order, animation blending and non-linear KF interpolation, non-diffuse material properties, advanced alpha modes, container contents, and collision decoding from NIF/Havok data. The controller movement values, NPC route behavior, static render-mesh colliders, and game-unit-to-meter scale remain provisional and are not claimed to match the original game's physics.

## Local integration run

On 2026-10-21, the project was launched with the installed base-game `Data` directory. It indexed 1,167,016 ESM records, 35,494 cells, and 17 BSA archives, found `ImperialDungeon01` with 467 references, and instantiated 1,203 meshes from 417 placed NIF references, including world models for pickup items. The run generated 353 static render-mesh colliders and assembled 9 placed NPCs; 5 of them use named ESM marker routes. FaceGen decoding reports 1,736 vertices, 50 symmetric and 30 asymmetric modes, 36 expression morphs, and 6 static morphs. Four dust/light-beam effect NIFs were skipped because nifly reported an out-of-range block index. The ESM `CGPlayerStartMarker` (`0x00032AB5`) is now the primary spawn, with the first valid NPC used only as fallback; this corrects the earlier build that placed the player at `CGAssassin04Ref` (`0x000178C4`). Runtime confirms the marker at Godot position `(5.6787, -1.0160, 0.5392)` and the generated floor 3.5 cm below it; the player is initially snapped to 2 cm above that surface. Valen Dreth is the nearest NPC at 8.18 m. The cell also indexes 9 world pickup candidates. The default male avatar loads `LowerShirt05` and `LowerPants05`; this outfit is not verified against the original player's starting inventory. The equipment-aware NPC loader attached Baurus's six Blades armor pieces and sword, and Uriel's robe, shoes, Amulet of Kings, and sword. `0x0007303C` is `CGValenDrethTauntMarker2`, used only by Valen's route. A temporary support is created only when no generated walkable surface is found below the player. Mouse yaw turns the player; the camera uses a swept sphere against static cell geometry. Several large surfaces still render as flat gray geometry. Original-game placement, Havok collision, and movement behavior remain unverified. The inventory HUD now includes the two default clothing items; pickup and duplicate stacking still need an interactive play check.

The inspector also accepts `--list-assets <prefix>`, `--list-editor-ids <prefix>`, `--find-editor-id <EDID>`, `--gmst-prefix <prefix>`, `--nif-summary <paths...>`, `--rig-summary <paths...>`, and `--kf-summary <paths...>` for local asset inspection. Its cell listing includes placed-reference record types, reference EDIDs, and base-object EDIDs. For example:

```sh
./build/oblivion-inspect "/path/to/Oblivion/Data" --kf-summary "Characters/_male/idle.kf" "Characters/_male/walkforward.kf"
```
