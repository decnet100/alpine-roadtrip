# Alpine Roadtrip

BeamNG.drive mod: Generating a region from several independant maps. Simulating a weather- and traffic system affecting the maps based on their geographical position. To switch from one map to the other, the driver can find their portal, which will take them to the next location once the driver spends the required amount of time in this portal. Time of day and the environmental configuration stay get recreated at the other end.


To generate enough maps in the same region quickly, maps themselves are built by [terrain-worker](https://github.com/decnet100/terrainWorker) using a semi-automated approach on 1m resolution terrain mapping, landcover, orthofoto. This repo is representing what is joining and connecting these maps: portal graph, GE extension, HUD, and the tools that inject the gates into those levels.

Internal id is `alpine_rt`. Mod folder: `mods/autoroad_alpine_rt`. Runtime session file (BeamNG user folder, not in git): `settings/alpine_rt/session.json`.

Concept and gates: [docs/ALPINE_ROADTRIP.md](docs/ALPINE_ROADTRIP.md). In-game registration: [Adding maps in-game](docs/ALPINE_ROADTRIP.md#adding-maps-in-game).

## Layout

| Path | Role |
|------|------|
| [config/alpine_rt/portals.yaml](config/alpine_rt/portals.yaml) | Portal graph (edit this) |
| `mods/autoroad_alpine_rt/` | GE mod (Lua, HUD, portal meshes) |
| `tools/build_portals.py` | Writes `portals.json`, arcs, and level inject |
| `tools/deploy_alpine_rt_mod.py` | Copy or junction into BeamNG unpacked mods |
| `tools/fetch_overview_basemap.py` | basemap.at overview for the HUD |
| `tools/write_map_icons.py` | Weather and traffic icons |
| `settings/alpine_rt/graph.json` | Maps and portals added in-game (BeamNG user folder, not in git) |

`build_portals.py` reads site YAML and heightmaps from a terrain-worker checkout (`config/sites`, `data/processed`). It does not generate terrain.

## Build

```powershell
cd C:\Users\decnet100\Documents\privat\alpine-roadtrip
python -m pip install -r requirements.txt
```

Point at the terrain-worker checkout if it is not the sibling folder `road`:

```powershell
$env:TERRAIN_WORKER = "C:\Users\decnet100\Documents\privat\road"
python tools\build_portals.py
python tools\deploy_alpine_rt_mod.py --link
```

`--link` junctions `%LOCALAPPDATA%\BeamNG\BeamNG.drive\current\mods\unpacked\autoroad_alpine_rt\` at `mods/autoroad_alpine_rt`.

Quit BeamNG completely after a Lua, `portals.json`, or mesh change, then start it again. Do not Save Level in the World Editor over an inject.
