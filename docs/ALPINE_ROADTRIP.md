# Alpine Roadtrip — multi-map session

**Status (2026-09-24):** in-game maps and portals, expected traffic from the game clock.  
Not yet: segment-time UI, driving-time countdown, live AI vehicles, vehicle damage.

The maps are built in [terrain-worker](https://github.com/decnet100/terrainWorker). This repo only owns the session mod and the portal inject.

The two test maps **do not share a geographic edge**. The boxes are logical gates (east end of Hahntennjoch ↔ south end of Fernpass / toward Imst), not a landscape seam.

The product name is **Alpine Roadtrip**. Internal id is `alpine_rt` (mod folder `autoroad_alpine_rt`, session file `settings/alpine_rt/session.json`).

---

## Current state

### Layers

- **Maps:** Python injects visible volumes + arrival spawns. The terrain pipeline stays independent.
- **Session:** GE extension `alpinert` with `setExtensionUnloadMode(..., "manual")` in `scripts/modScript.lua` (not `mainLevel.lua`).
- **Source of truth on switch:** `settings/alpine_rt/session.json` (user folder). In-memory: countdown / grace only.

### Files

| Path | Role |
|------|------|
| [config/alpine_rt/portals.yaml](../config/alpine_rt/portals.yaml) | Portal graph (edit this) |
| `mods/autoroad_alpine_rt/` | GE mod (Lua + cube/arc art) |
| `lua/ge/extensions/alpinert/portals.json` | Generated from the YAML by `build_portals.py` |
| `settings/alpine_rt/session.json` | Runtime, BeamNG user folder only |
| `settings/alpine_rt/graph.json` | Maps and portals added in-game (user folder only, not in git) |

## Adding maps in-game

Built-in gates still come from `portals.yaml` via `build_portals.py`. Extra maps and portals are created in the **Alpine Roadtrip Map** app and stored in `settings/alpine_rt/graph.json`. Quit BeamNG and start it again after a Lua change so this UI is actually loaded.

The overview CRS authority is `map.crs` in [portals.yaml](../config/alpine_rt/portals.yaml). The shipped value is `EPSG:31254`. **Define map** projects the typed WGS84 center into that CRS. If `map.crs` is missing, the app reports *No map CRS authority is configured. This map was not added.* If the code is set but the mod cannot project it, the app reports that the authority is not supported and does not save the map. The only supported authority today is `EPSG:31254` (Bessel transverse mercator, central meridian 10°20′, false northing −5 000 000 m). The MGI datum shift is not applied, so a plotted point can sit about 100 m off the basemap.

### Define map

Stand in the level you want to register. In the app:

1. **Define map**
2. Location name, latitude, longitude (WGS84, EPSG:4326)
3. *In which direction is your vehicle currently pointing?* — **Roughly north**, **Roughly east**, **Roughly south**, or **Roughly west**

That click saves the map. The vehicle's forward vector is treated as the chosen cardinal, so the level can be rotated; axes are not mirrored and scale stays 1. Levels that already have a center in `portals.json` (the built passes) count as defined, with level +Y as grid north. A foreign level is not defined until this step succeeds.

Saved on the location: display name, WGS84 center, easting/northing in the authority CRS, the authority code, the level-space north vector, and the BeamNG position of the vehicle at save time.

### New portal

**New portal** lists every other installed level. The choice places a 12×8×6 m gate at the vehicle, facing the way the vehicle faces. The current level must already be defined.

Until the destination has its own center, the sky arrow is an 800 m hint along that facing and the wait falls back to 5 s. There is no arrival pose yet, so the crossing loads the destination at its default spawn and there is no gate back.

### Return

On the destination, define that map first if it is not a built pass. **Return** lists open one-way links into the current level. The choice places the reverse gate at the vehicle. Each direction then gets an arrival 20 m ahead of the other gate, along the facing stored for that gate, so the vehicle does not sit inside the box it just came through. The existing 8 s grace still applies.

### Sky arrow and overview

For a user gate with both centers in the authority CRS, easting/northing of the destination minus the source is the arrow. That vector is rotated by the source level's stored north and drawn from the portal. Its length is the distance. The ribbon is a hump in level Z (peak 4 % of the length, clamped to 40–250 m), not a mesh baked into the level. While you are inside the box the line is drawn; the gate outline is drawn whenever that level is loaded.

Weather and traffic icons use the same center. A center or a road mark is drawn on the overview only when it lies inside `map.bbox`. Outside that image the portal and the arrow still work; the icon is omitted so the basemap is not zoomed out to a far point. Wait time, once both centers exist, is that distance in kilometres as seconds, then rolled from destination traffic the same way as built-in gates (low ±25 %, medium 100–150 %, heavy 150–200 %).

### graph.json

```text
settings/alpine_rt/graph.json
  locations.<level id>:
    name, wgs84: [lat, lon], crs: [easting, northing], authority
    north: [x, y], cardinal, anchor_beamng: [x, y, z]
  gates[]:
    id, from_level, to_level, label, user: true
    box: { pos, tangent, size }
    arrive: { pos, tangent }          # omitted until the return gate exists
    center_distance_m                  # set once both centers exist
```

Built-in gates stay in `portals.json`. User gates are merged on load. Re-placing **New portal** for the same pair updates that user gate instead of adding a second one.

### Persistence (today)

Snapshot before `startLevel`, restore after `onWorldReadyState == 2` (once a player vehicle exists):

- Environment: `core_environment.getState` / `setState` (time of day, clouds, fog, precipitation, wind, …)
- Weather preset: `core_weather.getCurrentWeatherPreset` + `activate` if present
- Vehicle: model + `partConfig` (same config). `startLevel` gets `{model, {config}}`; position is then set with `spawn.safeTeleport` to the arrival point, because Freeroam would otherwise overwrite `options.pos` with the default spawn
- Deliberately dropped: damage, fuel, speed, camera, traffic

Without `pending_restore` in the session file: normal Freeroam, no auto-restore.

Anti ping-pong: arrival sits ~20 m further **into the map** than the destination box; then 8 s grace with no new dwell. `startLevel` runs on the **next** `onUpdate` (not on the trigger stack).

### In-map

- Red, **very** transparent TSStatic box, `collisionType: None`, 12×8×6 m. Logic = Lua OBB.
- While the vehicle is in a **built-in** box: 20 m-wide ballistic arc toward the **DGM bbox centre of the destination map** (full CRS distance, end at `center_z_m` in the current map’s Z scale). `visibleDistance` is raised for that (template otherwise 7.5 km). Later the same mesh sits in front of the backdrop panorama from terrain-worker (`docs/BACKDROP.md`). User-made gates use the in-game sky arrow described under [Adding maps in-game](#adding-maps-in-game).
- HUD app **Alpine Roadtrip Map**: weather + traffic icons sit on each **map centre** (not the portals). The loaded map has no stack. Portal wait is the distance between the two map centres in km as seconds, then rolled from destination-map traffic (low ±25 %, medium 100–150 %, heavy 150–200 %). Leave and re-enter rolls again.
- Expected traffic is not live AI, and the app does not show the clock. One session seed comes from the UTC start time (`YYYYMMDDHHMM`). Density then follows the in-game clock (BeamNG `TimeOfDay`, 24×: one real hour is one game day). Weekend waves (Friday afternoon, Saturday, Sunday return) and a nationwide German holiday envelope multiply the value. Summer (1 Jul–15 Aug) is the strongest inbound boost. This is not 16 Bundesland calendars — only the typical travel windows that fill Alpine roads.
- Background map: `build_portals` / `tools/fetch_overview_basemap.py` pulls [basemap.at](https://basemap.at/) WMTS tiles (CC-BY 4.0), warps them onto `map.bbox` in EPSG:31254, and writes `basemap.png` plus a world file (`.pgw`). `image_aspect` grows that box to landscape so a wide HUD fills. The app crops a view matching the window aspect (all portal marks stay visible). Same aspect, larger window: same region, more pixels. Attribution: „Datenquelle: basemap.at“.

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

New gate: add YAML, run `build_portals.py`, reload the level. `dwell_s` will later be replaced by routed driving time.

---

## Session JSON

```text
settings/alpine_rt/session.json
  session_id, started_at
  settings: { environment: { time, play, cloudCover, fogDensity, ... }, weather_preset }
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
- Traffic, damage persistence

Reference: level change via `core_levels.startLevel`; persistence via `jsonWriteFile` / `jsonReadFile` (not `settings` as a dumping ground).
