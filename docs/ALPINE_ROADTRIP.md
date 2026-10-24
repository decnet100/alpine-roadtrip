# Alpine Roadtrip — multi-map session

**Status (2026-10-24):** two HUD apps, in-game maps and portals, test traffic on Fernpass, Imst-Tarrenz, and Reschen.  
Not yet: segment-time UI, driving-time countdown. Vehicle damage and fuel are kept across a portal.

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

## The two apps

Both apps are under Gameplay in the app menu. Neither is on the default freeroam layout, so add the one you need. A Lua change needs a full BeamNG restart before the apps see the new calls. Ctrl+L reloads the app script only. Each header shows the loaded level title and the running Lua revision.

**Region Setup** is for authoring. It writes the live overlay (`settings/alpine_rt/graph.json`). It does not draw the region. The header can collapse to **Hide** / **Show**.

**Alpine Roadtrip Map** is for driving. It draws the region picture, the connection lines, and a weather icon plus a traffic icon on each map centre. Drag pans the overview and the wheel zooms it. **Zoom** crops to the loaded level. **Overview** returns to the authored content box. **Refresh** polls the session again. Strokes stay one pixel wide when you zoom. While a route is being edited, the subtitle says to drag an orange midpoint; a right-click removes a white point.

| | Region Setup | Alpine Roadtrip Map |
|--|----------------|---------------------|
| Use | Place maps, portals, and region files | Drive, and edit a connection line |
| Picture | Chooses the provider and asks for a redraw | Composites the local tiles and draws the lines |
| Portals | Creates, moves, and removes them | Draws a red diamond on the zoomed level; gold after a hidden portal is found |

### Creating a portal

Built-in gates (Fernpass, Reschen, Timmelsjoch, and the links already in `portals.json`) are already in the mod. A new gate is placed from **Region Setup** while you stand in the source level. The world editor is not used.

1. **Place this map**, if this level is not a built pass. Type the WGS84 latitude and longitude of where you are standing. The four buttons (**Roughly north**, **Roughly east**, **Roughly south**, **Roughly west**) save the map and treat the car's forward axis as that cardinal. The level title is the name; you do not type one. A second save replaces the center. **Remove** on a row under **Placed maps** drops that location and every user portal that touches it. **New portal** refuses to open the list until this step has succeeded (`Place this map first.`).
2. **New portal**. Filter the list if you want, then click the destination. Stock maps use the game's level title. The click puts a 12×8×6 m box at the car, facing the way the car faces. For 10 s the new box does not start a crossing (`Suppressing new portal for 10s, please move if you don't want to visit <map>`). The row under **Portals** reads `To <map>` and, until the way back exists, **one way**.
3. Drive to the destination. **Place this map** there too, unless it is a built pass. **Return (n)** appears when a one-way link points into this level. **From &lt;map&gt;** puts the reverse box at the car. Each direction then has an arrival, and the **one way** mark goes away. Placing **New portal** again for the same pair updates that user gate instead of adding a second one.
4. **Move here**, on a row whose gate starts on this level, moves that box to the car and keeps the destination. Shipped gates can be moved this way. The level object stays; the new pose is stored under `moves`. **Remove** deletes a user portal only. Shipped gates stay in the list.

Until the destination has its own center, the sky arrow is an 800 m hint along the facing, the wait is 5 s, and the crossing loads that level at its default spawn. With both centers, the wait is the ground distance in kilometres as seconds, and the sky arrow follows the shared connection line. **Edit routes** lists those lines by the two map names and opens **Alpine Roadtrip Map** on the chosen one, adding that app to the layout if it is missing.

**Region picture** in Region Setup picks **Local**, **Orthophoto**, **Geoland terrain**, or **OSM**. **Redraw region map** composites that provider in the driving app. **Region file** saves a named copy of the overlay. **Files** lists them. **Load** replaces the live overlay and does not touch `portals.json`.

## Adding maps in-game

The button sequence is under [The two apps](#the-two-apps). This section is what those buttons store. Built-in gates still come from `portals.yaml` via `build_portals.py` and stay in `portals.json`.

The overview CRS authority is `map.crs` in [portals.yaml](../config/alpine_rt/portals.yaml). The shipped value is `EPSG:3857` (Web Mercator, the CRS of OSM and basemap.at `google3857` tiles). **Place this map** projects the typed WGS84 center into that CRS. If `map.crs` is missing, the app reports that no map CRS is configured and does not save. If the code is set but the mod cannot project it, the app reports that the authority is not supported and does not save the map. Supported authorities are `EPSG:3857` and, for an older graph, `EPSG:31254`. A named region file whose `authority` does not match the running overview is refused. Mercator metres are stretched by `1/cos(latitude)`; a user gate's sky arrow and wait use the ground length (that stretch removed). The built-in wait still uses the distance between map centres in the destination site CRS.

### Place this map

Stand in the level you want to register. In **Region Setup**:

1. **Place this map**
2. Latitude, longitude (WGS84, EPSG:4326). The shown name is the game's level title, the same one above the minimap. A name typed in an older session is not used.
3. *In which direction is your vehicle currently pointing?* — **Roughly north**, **Roughly east**, **Roughly south**, or **Roughly west**

That click saves the map into the live overlay. The vehicle's forward vector is treated as the chosen cardinal, so the level can be rotated; axes are not mirrored and scale stays 1. Levels that already have a center in `portals.json` (the built passes) count as defined, with level +Y as grid north. Saving again replaces the user center for this level. **Remove** on a placed map drops that location and every user portal that touches it. A foreign level is not defined until this step succeeds.

Saved on the location: the resolved level title, WGS84 center, easting/northing in the authority CRS, the authority code, the level-space north vector, and the BeamNG position of the vehicle at save time. The map and the setup header show that title for the loaded level. Lists show that title only, not the folder id and not a translation key.

### New portal

**New portal** lists every other installed level. Stock BeamNG maps are named with `core_locales.translate` on `levels.<id>.info.title` (the game language, then English), so the list shows "ETK Driver Experience Center" instead of the raw key. A label already stored as that key is resolved again when the portal list is drawn. The choice places a 12×8×6 m gate at the vehicle, facing the way the vehicle faces. For 10 s after that place, and after **Return**, the new gate does not start a crossing, so standing in the box does not leave the map. The message is `Suppressing new portal for 10s, please move if you don't want to visit <map>`. When the 10 s end, a car still inside the box starts the wait as usual. The current level must already be defined. The portal list leads with every gate that starts on the loaded map, including the shipped passes (Fernpass, Reschen, Timmelsjoch). **Move here** puts that gate at the vehicle and keeps its destination. A crossing selects that level's arrival marker as the spawn for this load only, then puts the previous spawn point back. The marker is 0.3 m above the road. The way back, when one exists, then arrives 20 m ahead of the new box. A shipped gate keeps its level object; the overlay stores the new pose under `moves` and the mod moves that box while the level is loaded. The arrival marker on the same map (`alpine_rt_arrive_<return gate>`, the spawn point BeamNG uses for that portal) is moved to the new asphalt arrival before the player is spawned, so a later load does not drop the car on the old marker and correct it after the countdown. The sky arrow already in the level is shifted by the same offset. Labels on shipped gates are `To <map>`. **Remove** deletes a user portal. Shipped gates stay in the list.

Until the destination has its own center, the sky arrow is an 800 m hint along that facing and the wait falls back to 5 s. There is no arrival pose yet, so the crossing loads the destination at its default spawn and there is no gate back.

### Return

On the destination, place that map first if it is not a built pass. A built pass is already defined. BeamNG reports some folder names in lower case (`timmelsjoch_2048`); the mod matches that to the spelling in `portals.json` (`Timmelsjoch_2048`) before this check. **Return** lists open one-way links into the current level. The choice places the reverse gate at the vehicle. Each direction then stores an arrival 20 m ahead of the other gate, along the facing stored for that gate. At the crossing the car is placed on the nearest asphalt centerline instead, so a gate that does not sit on the road does not drop the car on the slope. The existing 8 s grace still applies.

### Region picture

Tiles are fetched **outside the game** by `tools/fetch_region_tiles.py`. It covers `map.bbox` plus 100 km of ground distance on every side, for Local, Orthophoto, Terrain, and OSM, and writes `ui/modules/apps/alpineRtTrafficMap/tilecache/<provider>/<z>/<x>/<y>.<ext>`. OSM and Local also keep a 12 km margin around the ADAC Fahrsicherheitszentrum Augsburg (Mühlhauser Straße, 48.41064 N, 10.93507 E), so that pin is not on the last tile edge. Existing tile files are left in place. The overview composite stays at the cached zoom for up to 96 tiles, which is enough for a center that far north. The driving app only composites those local files for the whole region. It does not download. The vehicle position is not part of that window, and driving does not move the picture. The overview opens on the authored content box. Drag pans that window and the wheel zooms it, out as far as the baked region and in to about 20 km. **Zoom** still crops to the loaded level. **Overview** returns to the authored box. **Region Setup** chooses the provider (**Local**, **Orthophoto**, **Geoland terrain**, **OSM**). Local is one picture assembled by country from the tile centre: basemap.at in Austria, swisstopo in Switzerland, basemap.de in Germany with the Bayern web map when that tile does not load, and the old IGM 25k sheets in Italy. A stored `geoland` choice reads as Local. A tile that crosses a border keeps each national map only inside that country and leaves the rest of the layer transparent, so the neighbours meet in the same file. **Redraw region map** composites that provider again. Both write `view` on the live overlay and bump a redraw counter. The overview grows to include every saved center, including one outside the original Tyrol box.

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
    arrive                             # set on the reverse gate; its SpawnSphere is moved to match
```

Built-in gates stay in `portals.json`. User gates are merged on load. Re-placing **New portal** for the same pair updates that user gate instead of adding a second one. The name is trimmed to letters, digits, space, `_` and `-`, spaces become `_`, and the result is capped at 48 characters. There is no OS file dialog; the world editor is not required.

### Persistence (today)

Snapshot before `startLevel`. Clock and weather are restored once a player vehicle exists. The arrival move runs on the next update after that car exists. If traffic is still spawning, the move waits, at most 20 s. Then the car is moved once, without a vehicle reset, and the saved state is applied once. For a crossing, the level spawn for that load is the destination arrival marker, so the car is not left on the map's old spawn until the move.

- Sun clock: the session restores `time`, `play`, and `dayLength` through `core_environment.setTimeOfDay`. 0.40 no longer has `dayScale` or `nightScale`. With no stored clock the Freeroam choice stays, including Level Default and Realtime (`fast` 900 s, `normal` 1800 s, `slow` 7200 s, `realtime` 86400 s, or the level's authored `dayLength`). Clouds and fog from that snapshot are not written back; a full `setState` retriggers the map's own sky. `session.world.day_length_s` and `clock_rate` (`86400 / dayLength`) record the live cycle.
- Destination weather: the class the HUD already shows for that map (`sun`, `clouds`, `rain`, `snow`) is stored on the switch and applied once the new level has a vehicle. Cloud cover and fog go through `core_environment`. Rain and snow also need a `Precipitation` object; the autoroad levels ship without one, so the restore creates `Precipitation` (datablock `rain_drop`, or `snow_drop` when that datablock exists). The same class is applied again if that level loads later without a new switch.
- Universal Dynamic Weather (jbWeather): if that panel is loaded, the destination class is applied with `setPreset` (`clear`, `overcast`, `rain`). That mod has no snow preset, so snow uses `rain`. Cloud cover is not written through `core_environment` in that case; those calls make 0.39 restore the map sky, and the weather mod then puts its own preset back. The rolling forecast is stopped so it does not replace the portal weather on the next tick. Without the mod, clouds, fog, and a `Precipitation` object are set directly. The environment panel shows `LevelInfo.fogDensity` times 1000. UDW's clear preset settles at 0.8 and overcast at 2, and the 6 s blend starts from the map fog, which on these levels is often already about 2. For the length of that blend, sun is held at panel 0.49 and clouds at 0.99. Rain and snow are not capped, and a map that is already under the cap is not made foggier.
- Vehicle: model + `partConfig` (same config). `startLevel` gets `{model, {config}}`. Freeroam still places that car on the level's own spawn point; the level loader overwrites any position passed in. After the wait, the car is moved to the nearest `decal_` asphalt centerline within 60 m of the destination gate, at that road's height, facing along the road and just outside the box. The gate tangent is not used for this offset: a gate can sit beside the pavement and below it, and a 20 m step along the gate facing then lands on the slope. The stored 20 m point is only the fallback when no asphalt is that close. The level's arrival marker is moved to that same point before the player spawns. If the car is already there when the wait ends, it is not moved again. Otherwise the move uses the ref node directly, 0.3 m above the road, so the car is not left in the surface and does not drop from a raised pose. `spawn.safeTeleport` is not used: its free-spot search walks the car onto a slope when the arrival box touches a hillside. The same pose is stored as the vehicle's original transform, so a later recovery returns to the portal rather than the level spawn. If the car is still inside that gate after the move, the gate does not start a crossing until the vehicle has been outside the box once.
- Damage, fuel, odometer, and cargo fill: while the car sits in the portal, `partCondition.getConditions`, `energyStorage`, `getRootPartOdometer`, and `getCargoContainers` are sampled, and `beamstate.save` writes the bent nodes and broken beams to `settings/alpine_rt/vehicle_carry.json`. The switch waits up to 2 s for that sample. Those values are applied once, after the countdown, in this order: part wear, the root odometer in metres, tank, cargo-container fill, then the beam file. The root reading is the fallback for any part that has no own odometer in the wear sample. A car with no wear sample but a reading above 1 m still gets that reading on every part, so the dashboard is not left at 0. A fresh car with no sample and no reading stays fresh. Cargo parts that are already in the vehicle config respawn with that config. Container fill is the extra runtime load (bed, tank, bulk): each container's target volume and density, skipped when the only cargo type is `passenger` (those seats are the dummy path). `setCargoContainers` puts that fill back. An empty container is left empty.
- Passengers and doors: the beam file is loaded after the single arrival move, which puts the door nodes back where they were when the car entered the portal. The latch controllers then run their spawn close, and for the next 2 s they are asked to catch again. Dummy seats are recorded at the switch and put back after that load. A vehicle reset during the game's own spawn is what used to drop the dummies and leave the doors open; that reset is no longer part of the restore.
- Coupled trailer: a trailer is its own vehicle on the hitch. At the switch the mod walks `attachedCouplers` from the player and keeps up to three vehicles in that chain (model, config, coupler node ids, coupler tag). About half a second after the arrival move it spawns each one with `safeSpawn` off, places it with `spawn.placeTrailer`, and latches the hitch. The object is not saved into the level. Trailer wear and trailer cargo fill are not sampled.
- Still not carried: speed and camera. The car is placed at the arrival point. Live traffic is not part of the snapshot. The test table below spawns a pool only when Freeroam has not already started traffic; a second `setupTraffic` would delete that pool and spawn it again.

Without `pending_restore` in the session file: normal Freeroam, no auto-restore.

Anti ping-pong: arrival is the nearest asphalt beside the destination box, outside the box. If the car is still inside that gate, the gate stays quiet until the vehicle has left the box once. Other gates stay quiet for 8 s after the arrival move. `startLevel` runs on the **next** `onUpdate` (not on the trigger stack).

### In-map

- Red, **very** transparent TSStatic box, `collisionType: None`, 12×8×6 m. Logic = Lua OBB.
- While the vehicle is in a **built-in** box: a sky wireframe toward the destination map. The start sits 4.5 m above the box (1.5 m deck clearance plus 3 m so the wire misses the vehicle). The end is the **opposite gate's box**, converted from that map's BeamNG position through both site CRS into the source map, at that portal's height. If the return gate is missing, the end stays the DGM bbox centre. With no intermediate points the plan is a straight arc over that span. A road may list any number of WGS84 `[lat, lon]` points in `via_wgs84`, ordered along `via_wgs84.along`; the opposite gate reverses them. Each point is projected into the **source** map’s site CRS, chained with the portal and the destination portal, and drawn as a smoothed curve with the same vertical hump. `portals.json` keeps that list on the road and, in travel order, on the gate arc, so a later UI hint can read it. `visibleDistance` follows the path length (template otherwise 7.5 km). Later the same mesh sits in front of the backdrop panorama from terrain-worker (`docs/BACKDROP.md`). User-made gates use the in-game sky arrow described under [Adding maps in-game](#adding-maps-in-game).
- Two portal kinds. A normal gate (no `discoverable` key) keeps its arrival spawn and, on the zoomed map of the level you are in, a small red diamond at the box. A gate with `discoverable: true` gets no spawn and no overview route. It stays off the zoom map until the vehicle has spent 1 s of sim time in the box this session; then the message is `Hidden portal to <map> discovered` and the same diamond is drawn in gold. That find is not written to the session file. The wait for a discoverable gate always uses the light traffic band. The sky wire still appears while you stand in the box.
- The dwell message is `Travelling to <map> — Ns`. The map name is the level title, or a short name when the title is still the raw level id.
- HUD app **Alpine Roadtrip Map** (driving): weather + traffic icons sit on each **map centre** (not the portals). Each connection is two curves from portal to portal. `via_wgs84` points are projected into the overview CRS and sit on that curve; without them the pair is straight. The strokes stay apart so the middle is clear, and each stroke uses that direction's traffic colour. The loaded map has no icon stack. Portal wait is the distance between the two map centres in km as seconds, then rolled from destination-map traffic (low ±25 %, medium 100–150 %, heavy 150–200 %). Leave and re-enter rolls again. Setup (place a map, portals, save and load a region file) is the separate **Region Setup** app.
- Test traffic (temporary, `TEST_TRAFFIC` in `alpinert.lua`): Fernpass spawns 15 vehicles and simulates all of them (BeamNG's traffic slider ends at 15). Imst-Tarrenz (`imst_tarrenz`) spawns 3, Reschen (Kauns) 8. Timmelsjoch has no test-traffic entry yet. Before that spawn, lane-marking `DecalRoad`s (`line_*`, or `hiddenInNavi`) are set to drivability `-1` and the navgraph is rebuilt once, so traffic follows the asphalt instead of a dash. If the closest road to the player is still narrower than 2 m, nothing is spawned. The spawn waits until `map.getMap().nodes` contains roads, and until the portal reapply has finished. `map.nodes` is not that table, so a check against it never starts traffic. The same steps colour the map and scale the portal wait. The calendar density is not used on those levels while that table is set. Remove the table to return to clock-driven density with no live vehicles.
- Expected traffic outside that test is not live AI, and the app does not show the clock. One session seed comes from the UTC start time (`YYYYMMDDHHMM`). Density follows the in-game sun: a game day advances when `TimeOfDay` wraps past midnight, at whatever day length the session kept. Weekend waves (Friday afternoon, Saturday, Sunday return) and a nationwide German holiday envelope multiply the value. Summer (1 Jul–15 Aug) is the strongest inbound boost. This is not 16 Bundesland calendars — only the typical travel windows that fill Alpine roads.
- Background map: `tools/fetch_region_tiles.py` downloads EPSG:3857 tiles for the region plus a 100 km buffer, for every provider, into `tilecache/`. OSM additionally covers 12 km past the ADAC Fahrsicherheitszentrum Augsburg. The driving app composites up to 96 of those tiles so a center that far north still draws at the cached zoom. The driving app composites that folder for the whole region and draws the connections on top in screen pixels, so zoom does not thicken them. It refetches nothing. A new composite runs when the provider or the redraw counter changes, or when the region box grows. Zoom crops that picture. `tools/fetch_overview_basemap.py` can still write one `basemap.png` for a build. The Local credit line keeps „Datenquelle: basemap.at“ and adds swisstopo, GeoBasis-DE / BKG, the Bavarian survey, and IGM. OSM tiles are © OpenStreetMap contributors.

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
  vehicle: { model, config, partConditions, fuel, odometer, cargo, beamFile, passengers, trailers }
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
