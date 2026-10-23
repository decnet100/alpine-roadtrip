# Alpine Roadtrip — multi-map session

**Status (2026-09-24):** in-game maps and portals, expected traffic from the game clock.  
Not yet: segment-time UI, driving-time countdown, live AI vehicles. Vehicle damage and fuel are kept across a portal.

The maps are built in [terrain-worker](https://github.com/decnet100/terrainWorker). This repo only owns the session mod and the portal inject.

The maps **do not share a geographic edge**. The boxes are logical gates (Fernpass ↔ Imst-Tarrenz ↔ Reschen, plus Imst-Tarrenz ↔ Timmelsjoch), not a landscape seam. Timmelsjoch uses EPSG:25832 in terrain-worker; the overview plots in `map.crs` (EPSG:3857).

The product name is **Alpine Roadtrip**. Internal id is `alpine_rt` (mod folder `autoroad_alpine_rt`, session file `settings/alpine_rt/session.json`).

---

## Current state

### Layers

- **Maps:** Python injects visible volumes + arrival spawns. The terrain pipeline stays independent.
- **Session:** GE extension `alpinert` with `setExtensionUnloadMode(..., "manual")` in `scripts/modScript.lua` (not `mainLevel.lua`).
- **Source of truth on switch:** `settings/alpine_rt/session.json` (user folder). In-memory: countdown, grace, and which discoverable portals were found this session.

### Files

| Path | Role |
|------|------|
| [config/alpine_rt/portals.yaml](../config/alpine_rt/portals.yaml) | Portal graph (edit this) |
| `mods/autoroad_alpine_rt/` | GE mod (Lua + cube/arc art) |
| `lua/ge/extensions/alpinert/portals.json` | Generated from the YAML by `build_portals.py` |
| `settings/alpine_rt/session.json` | Runtime, BeamNG user folder only |
| `settings/alpine_rt/graph.json` | Live user overlay: placed maps, portals, WMTS provider (user folder only, not in git) |
| `settings/alpine_rt/regions/<name>.json` | Named copy of that overlay (`format: alpine_rt_region`, version 1) |

## Adding maps in-game

Built-in gates still come from `portals.yaml` via `build_portals.py` and stay in `portals.json`. Extra maps and portals are created in the **Region Setup** HUD app. The **Alpine Roadtrip Map** app is the driving view: overview, zoom, weather and traffic. Quit BeamNG and start it again after a Lua change so both apps and the new calls are loaded. Add **Region Setup** from the app menu; it is not on the default freeroam layout.

The overview CRS authority is `map.crs` in [portals.yaml](../config/alpine_rt/portals.yaml). The shipped value is `EPSG:3857` (Web Mercator, the CRS of OSM and basemap.at `google3857` tiles). **Place this map** projects the typed WGS84 center into that CRS. If `map.crs` is missing, the app reports that no map CRS is configured and does not save. If the code is set but the mod cannot project it, the app reports that the authority is not supported and does not save the map. Supported authorities are `EPSG:3857` and, for an older graph, `EPSG:31254`. A named region file whose `authority` does not match the running overview is refused. Mercator metres are stretched by `1/cos(latitude)`; a user gate's sky arrow and wait use the ground length (that stretch removed). The built-in wait still uses the distance between map centres in the destination site CRS.

### Place this map

Stand in the level you want to register. In **Region Setup**:

1. **Place this map**
2. Location name, latitude, longitude (WGS84, EPSG:4326)
3. *In which direction is your vehicle currently pointing?* — **Roughly north**, **Roughly east**, **Roughly south**, or **Roughly west**

That click saves the map into the live overlay. The vehicle's forward vector is treated as the chosen cardinal, so the level can be rotated; axes are not mirrored and scale stays 1. Levels that already have a center in `portals.json` (the built passes) count as defined, with level +Y as grid north. Saving again replaces the user center for this level. **Remove** on a placed map drops that location and every user portal that touches it. A foreign level is not defined until this step succeeds.

Saved on the location: display name, WGS84 center, easting/northing in the authority CRS, the authority code, the level-space north vector, and the BeamNG position of the vehicle at save time.

### New portal

**New portal** lists every other installed level. Stock BeamNG maps are named with `core_locales.translate` on `levels.<id>.info.title` (the game language, then English), so the list shows "ETK Driver Experience Center" instead of the raw key. A label already stored as that key is resolved again when the portal list is drawn. The choice places a 12×8×6 m gate at the vehicle, facing the way the vehicle faces. For 10 s after that place, and after **Return**, the new gate does not start a crossing, so standing in the box does not leave the map. The message is `Suppressing new portal for 10s, please move if you don't want to visit <map>`. When the 10 s end, a car still inside the box starts the wait as usual. The current level must already be defined. The portal list leads with every gate that starts on the loaded map, including the shipped passes (Fernpass, Reschen, Timmelsjoch). **Move here** puts that gate at the vehicle and keeps its destination. The way back, when one exists, then arrives 20 m ahead of the new box. A shipped gate keeps its level object; the overlay stores the new pose under `moves` and the mod moves that box while the level is loaded. The sky arrow already in the level is shifted by the same offset. Labels on shipped gates are `To <map>`. **Remove** deletes a user portal. Shipped gates stay in the list.

Until the destination has its own center, the sky arrow is an 800 m hint along that facing and the wait falls back to 5 s. There is no arrival pose yet, so the crossing loads the destination at its default spawn and there is no gate back.

### Return

On the destination, place that map first if it is not a built pass. A built pass is already defined. BeamNG reports some folder names in lower case (`timmelsjoch_2048`); the mod matches that to the spelling in `portals.json` (`Timmelsjoch_2048`) before this check. **Return** lists open one-way links into the current level. The choice places the reverse gate at the vehicle. Each direction then gets an arrival 20 m ahead of the other gate, along the facing stored for that gate, so the vehicle does not sit inside the box it just came through. The existing 8 s grace still applies.

### Region picture

Tiles are fetched **outside the game** by `tools/fetch_region_tiles.py`. It covers `map.bbox` plus 100 km of ground distance on every side, for Geoland, Orthophoto, Terrain, and OSM, and writes `ui/modules/apps/alpineRtTrafficMap/tilecache/<provider>/<z>/<x>/<y>.<ext>`. OSM also keeps a 12 km margin around the ADAC Fahrsicherheitszentrum Augsburg (Mühlhauser Straße, 48.41064 N, 10.93507 E), so that pin is not on the last tile edge. Existing tile files are left in place. The overview composite stays at the cached zoom for up to 96 tiles, which is enough for a center that far north. The driving app only composites those local files for the whole region. It does not download. The vehicle position is not part of that window, and driving does not move the picture. The overview opens on the authored content box. Drag pans that window and the wheel zooms it, out as far as the baked region and in to about 20 km. **Zoom** still crops to the loaded level. **Overview** returns to the authored box. **Region Setup** chooses the provider (**Geoland**, **Orthophoto**, **Terrain**, **OSM**) and **Redraw region map** composites that provider again. Both write `view` on the live overlay and bump a redraw counter. The overview grows to include every saved center, including one outside the original Tyrol box.

### Sky arrow

For a user gate with both centers in the authority CRS, the sky arrow follows that pair's shared centerline, including its free points. The opposite gate walks the same line backwards. Each overview step is rotated by the source level's stored north and drawn from the portal. The ribbon is one hump in level Z over that path: the crest is halfway along the drawn line, and its height is 4 % of the path length, clamped to 40–250 m. It is not a mesh baked into the level. While you are inside the box the line is drawn. Each user gate also spawns the same translucent red box as a built-in gate, on the loaded level only, and that object is not saved into the level. Removing the gate deletes the box. On the zoomed driving map the same gate is a red diamond, using the stored anchor to place it.

Weather and traffic icons use the same center. Wait time, once both centers exist, is that ground distance in kilometres as seconds, then rolled from destination traffic the same way as built-in gates (low ±25 %, medium 100–150 %, heavy 150–200 %). Curved `via_wgs84` points stay on roads authored in `portals.yaml`.

### Connection line

A user connection is one centerline, shared by both directions. It starts as the straight line between the two map centers. **Edit routes** in Region Setup lists each user connection by the two map names. Choosing one opens the driving map on that line and shows an orange handle at the middle of each segment. Clicking the line on the map selects it too. Click the handle and drag to insert a free point; drag a white point to move it; right-click a white point to remove it. Press **Edit routes** again to leave that mode. Shipped passes are in that list too. Their line starts at the authored bends. Moving a point stores the new line under `links` and leaves `portals.yaml` unchanged. Clearing every point stores a straight line between the two portal marks. The sky arrow inside a shipped gate stays the mesh from the level. If the driving map is not in the current layout, the button adds it and says so. The two coloured strokes are offsets of that same line. The list is stored once, in order from the lexicographically first level id to the second, under `links` in the overlay. Both sky arrows use that line for their plan and for the hump height. The wait stays the straight centre-to-centre distance. Up to 24 points.

### graph.json and named region files

The live overlay is always `settings/alpine_rt/graph.json`. **Save** writes a copy under a name; **Files** lists those copies; **Load** replaces the live overlay (locations, gates, `links`, and `view`) and does not touch `portals.json`.

```text
settings/alpine_rt/graph.json
settings/alpine_rt/regions/<name>.json
  format: alpine_rt_region
  version: 1
  authority
  view: { provider, redraw }
  locations.<level id>:
    name, wgs84: [lat, lon], crs: [easting, northing], authority
    north: [x, y], cardinal, anchor_beamng: [x, y, z]
  gates[]:
    id, from_level, to_level, label, user: true
    box: { pos, tangent, size }
    arrive: { pos, tangent }          # omitted until the return gate exists
    center_distance_m                  # set once both centers exist
  links[]:                             # one centerline for both directions
    a, b                               # level ids, a < b
    via: [[easting, northing], ...]    # points between the two map centers
  moves.<gate id>:                     # shipped gate, moved in game
    pos, tangent                       # new box on its own map
    arrive                             # set on the reverse gate only
```

Built-in gates stay in `portals.json`. User gates are merged on load. Re-placing **New portal** for the same pair updates that user gate instead of adding a second one. The name is trimmed to letters, digits, space, `_` and `-`, spaces become `_`, and the result is capped at 48 characters. There is no OS file dialog; the world editor is not required.

### Persistence (today)

Snapshot before `startLevel`, restore after `onWorldReadyState == 2` (once a player vehicle exists):

- Sun clock: the session restores `time`, `play`, and `dayLength` through `core_environment.setTimeOfDay`. 0.40 no longer has `dayScale` or `nightScale`. With no stored clock the Freeroam choice stays, including Level Default and Realtime (`fast` 900 s, `normal` 1800 s, `slow` 7200 s, `realtime` 86400 s, or the level's authored `dayLength`). Clouds and fog from that snapshot are not written back; a full `setState` retriggers the map's own sky. `session.world.day_length_s` and `clock_rate` (`86400 / dayLength`) record the live cycle.
- Destination weather: the class the HUD already shows for that map (`sun`, `clouds`, `rain`, `snow`) is stored on the switch and applied once the new level has a vehicle. Cloud cover and fog go through `core_environment`. Rain and snow also need a `Precipitation` object; the autoroad levels ship without one, so the restore creates `Precipitation` (datablock `rain_drop`, or `snow_drop` when that datablock exists). The same class is applied again if that level loads later without a new switch.
- Universal Dynamic Weather (jbWeather): if that panel is loaded, the destination class is applied with `setPreset` (`clear`, `overcast`, `rain`). That mod has no snow preset, so snow uses `rain`. Cloud cover is not written through `core_environment` in that case; those calls make 0.39 restore the map sky, and the weather mod then puts its own preset back. The rolling forecast is stopped so it does not replace the portal weather on the next tick. Without the mod, clouds, fog, and a `Precipitation` object are set directly.
- Vehicle: model + `partConfig` (same config). `startLevel` gets `{model, {config}}`; position is then set with `spawn.safeTeleport` to the arrival point, because Freeroam would otherwise overwrite `options.pos` with the default spawn
- Damage and fuel: while the car sits in the portal, `partCondition.getConditions` and `energyStorage` are sampled, and `beamstate.save` writes the bent nodes and broken beams to `settings/alpine_rt/vehicle_carry.json`. The switch waits up to 2 s for that sample. After the destination vehicle exists, `beamstate.load` puts the dents back, `initPartConditions` restores part wear and odometer, and `setEnergyStorageEnergy` restores the tank. The arrival teleport runs again after the beam load so the car stays on the arrival point. A fresh car with no part-condition data stays fresh.
- Passengers: BeamNG drops non-player seat occupants whenever the spawned car is reset, and the exit leaves the doors open. The switch records dummy seats and, after the arrival resets, seats those occupants again and latches the doors.
- Still not carried: speed and camera. The car is placed at the arrival point. Live traffic is not part of the snapshot; the test table below spawns a new pool after the destination level is ready.

Without `pending_restore` in the session file: normal Freeroam, no auto-restore.

Anti ping-pong: arrival sits ~20 m further **into the map** than the destination box; then 8 s grace with no new dwell. `startLevel` runs on the **next** `onUpdate` (not on the trigger stack).

### In-map

- Red, **very** transparent TSStatic box, `collisionType: None`, 12×8×6 m. Logic = Lua OBB.
- While the vehicle is in a **built-in** box: a sky wireframe toward the destination map. The start sits 4.5 m above the box (1.5 m deck clearance plus 3 m so the wire misses the vehicle). The end is the **opposite gate's box**, converted from that map's BeamNG position through both site CRS into the source map, at that portal's height. If the return gate is missing, the end stays the DGM bbox centre. With no intermediate points the plan is a straight arc over that span. A road may list any number of WGS84 `[lat, lon]` points in `via_wgs84`, ordered along `via_wgs84.along`; the opposite gate reverses them. Each point is projected into the **source** map’s site CRS, chained with the portal and the destination portal, and drawn as a smoothed curve with the same vertical hump. `portals.json` keeps that list on the road and, in travel order, on the gate arc, so a later UI hint can read it. `visibleDistance` follows the path length (template otherwise 7.5 km). Later the same mesh sits in front of the backdrop panorama from terrain-worker (`docs/BACKDROP.md`). User-made gates use the in-game sky arrow described under [Adding maps in-game](#adding-maps-in-game).
- Two portal kinds. A normal gate (no `discoverable` key) keeps its arrival spawn and, on the zoomed map of the level you are in, a small red diamond at the box. A gate with `discoverable: true` gets no spawn and no overview route. It stays off the zoom map until the vehicle has spent 1 s of sim time in the box this session; then the message is `Hidden portal to <map> discovered` and the same diamond is drawn in gold. That find is not written to the session file. The wait for a discoverable gate always uses the light traffic band. The sky wire still appears while you stand in the box.
- The dwell message is `Travelling to <map> — Ns`. The map name is the level title, or a short name when the title is still the raw level id.
- HUD app **Alpine Roadtrip Map** (driving): weather + traffic icons sit on each **map centre** (not the portals). Each connection is two curves from portal to portal. `via_wgs84` points are projected into the overview CRS and sit on that curve; without them the pair is straight. The strokes stay apart so the middle is clear, and each stroke uses that direction's traffic colour. The loaded map has no icon stack. Portal wait is the distance between the two map centres in km as seconds, then rolled from destination-map traffic (low ±25 %, medium 100–150 %, heavy 150–200 %). Leave and re-enter rolls again. Setup (place a map, portals, save and load a region file) is the separate **Region Setup** app.
- Test traffic (temporary, `TEST_TRAFFIC` in `alpinert.lua`): Fernpass keeps a pool of 100 vehicles and simulates 15 at a time (BeamNG's traffic slider ends at 15; 100 physics vehicles at once is not usable). Imst-Tarrenz (`imst_tarrenz`) spawns 3, Reschen (Kauns) 8. Timmelsjoch has no test-traffic entry yet. The spawn waits until `map.getMap().nodes` contains roads. `map.nodes` is not that table, so a check against it never starts traffic. The same steps colour the map and scale the portal wait. The calendar density is not used on those levels while that table is set. Remove the table to return to clock-driven density with no live vehicles.
- Expected traffic outside that test is not live AI, and the app does not show the clock. One session seed comes from the UTC start time (`YYYYMMDDHHMM`). Density follows the in-game sun: a game day advances when `TimeOfDay` wraps past midnight, at whatever day length the session kept. Weekend waves (Friday afternoon, Saturday, Sunday return) and a nationwide German holiday envelope multiply the value. Summer (1 Jul–15 Aug) is the strongest inbound boost. This is not 16 Bundesland calendars — only the typical travel windows that fill Alpine roads.
- Background map: `tools/fetch_region_tiles.py` downloads EPSG:3857 tiles for the region plus a 100 km buffer, for every provider, into `tilecache/`. OSM additionally covers 12 km past the ADAC Fahrsicherheitszentrum Augsburg. The driving app composites up to 96 of those tiles so a center that far north still draws at the cached zoom. The driving app composites that folder for the whole region and draws the connections on top in screen pixels, so zoom does not thicken them. It refetches nothing. A new composite runs when the provider or the redraw counter changes, or when the region box grows. Zoom crops that picture. `tools/fetch_overview_basemap.py` can still write one `basemap.png` for a build. Attribution for Geoland stays „Datenquelle: basemap.at“. OSM tiles are © OpenStreetMap contributors.

| Gate | from | to | Box (BeamNG m) |
|------|------|-----|----------------|
| `hahntenn_to_fernpass` | `autoroad_m28_test` | `autoroad_fernpass_8192` | ~485, 357 (east end of M28) |
| `fernpass_to_hahntenn` | `autoroad_fernpass_8192` | `autoroad_m28_test` | ~3030, 30 (south end of B179) |

---

## Build / deploy

Map rebuilds (heightmap, guardrails, level setup) stay in terrain-worker. A portal-only change does not need them.

From this repo, with terrain-worker as the sibling `road` or via `TERRAIN_WORKER`:

```powershell
cd C:\Users\decnet100\Documents\privat\alpine-roadtrip
$env:TERRAIN_WORKER = "C:\Users\decnet100\Documents\privat\road"
python tools\build_portals.py
python tools\deploy_alpine_rt_mod.py --link
```

`--link` creates a junction to `%LOCALAPPDATA%\BeamNG\BeamNG.drive\current\mods\unpacked\autoroad_alpine_rt\`.

`build_portals.py` reads `config/sites/*.yaml` and `data/processed/<site>/heightmap_*.png` from terrain-worker (bbox centre, `center_z_m`, sun lat/lon). It writes `portals.json` and the arc meshes here, and injects boxes and arrival spawns into the BeamNG user levels.

Lua / `portals.json` / injected TSStatics: **quit BeamNG entirely and start it again** (not only Freeroam → load map, not only World Editor reload). Do not Save Level in the World Editor if inject is the source of the portal objects.

Seasonal water (lakes / Gewässernetz rivers) is baked by terrain-worker (`docs/WATER.md` there). On load the session calendar month applies `levels/<map>/water_stages.json`. The file is decoded once for that stay; a missing file is remembered too. A later game month applies the next stage without reading it again. Console: `extensions.alpinert.applyWaterStage("autumn")`.

New gate: add YAML, run `build_portals.py`, reload the level. `dwell_s` will later be replaced by routed driving time.

---

## Session JSON

```text
settings/alpine_rt/session.json
  session_id, started_at
  settings: { environment: { time, play, dayLength, cloudCover, fogDensity, ... }, weather_preset }
  world: { day_length_s, clock_rate, calendar_start, game_day, last_tod }
  vehicle: { model, config }
  pending_restore: { to_level, from_gate, arrive: { pos, tangent } }   # only during load
  segments: []   # placeholder, no summary UI
```

---

## Product goal

The player drives pass segments and, at the edge, continues on purpose. Hard switch, session stays:

- Segment times + total time (not yet)
- Environment + same vehicle (today)
- Overview at the end (not yet)

No engine world streaming.

## What BeamNG can / cannot do

| Reality | Consequence |
|---------|-------------|
| No seamless streaming | One map = one load |
| `core_levels.startLevel("/levels/<name>/main/")` | Hard switch |
| Stock timers do not survive the switch | Own timing later |
| Weather / car do not persist magically | Snapshot in session.json |
| GE extension `unloadMode=manual` survives the switch | Session core lives there |

## Non-goals (for now)

- Real streaming / one mega heightmap of every pass
- Official race UI across maps
- Online leaderboards
- Traffic as a persisted snapshot

Reference: level change via `core_levels.startLevel`; persistence via `jsonWriteFile` / `jsonReadFile` (not `settings` as a dumping ground).
