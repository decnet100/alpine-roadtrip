# Hillclimb in freeroam

Design record. Not implemented yet.

The classified run is a BeamNG time trial for the player alone. One or more AI vehicles start ahead of that, in race mode on the same path, outside the classification. The vehicle digest and the central leaderboard apply only to the player.

The session layer already survives `core_levels.startLevel` because [`alpinert.lua`](../mods/autoroad_alpine_rt/lua/ge/extensions/alpinert.lua) stays loaded ([`modScript.lua`](../mods/autoroad_alpine_rt/scripts/modScript.lua)) and `jsonWriteFile` stores state in the BeamNG user folder. BeamNG itself provides the clock, the checkpoints, and the local mission best. This repo has no hillclimb mission and no network yet. `session.segments` stays the placeholder for pass times. BeamNG.drive is not installed on the machine where this note was written. Lua function names are checked against the installed game when the feature is built. The layout follows the current modding docs: [missions](https://documentation.beamng.com/modding/levels/gameplay_data/) and the [Race/Path Editor](https://documentation.beamng.com/world_editor/windows/race_path_editor/).

## Constraints

- **HTTP and a database.** BeamNG GE Lua can POST with LuaSocket `socket.http`. A leaderboard is request and response. MQTT has no client in the game, and the traces are too large for it. TLS via LuaSec is not reliable here, so the endpoint is plain HTTP on a network the operator controls. The base URL lives only in `settings/alpine_rt/climb.json`, not in git.
- **A version code per stage**, set by the author. The board key is mission id plus version. Moving the start, the finish, or rebuilding the road in terrain-worker changes what a time means, so the code is bumped. This repo cannot see a mesh rebuild. The code is an explicit value, not a hash.
- **A clean car for the run, then the previous state.** Before the countdown, `beamstate.save` writes the physical state (nodes, broken beams, deformed beams) to `settings/alpine_rt/damage_stash.json`. The same vehicle is then repaired in place. Classification starts from zero damage. At the end of the run, on abort, and on leaving the stage area, `beamstate.load` puts that state back. Load accepts the file only when the node and beam counts match, so the config must be the same. A vehicle change during the run is invalid. The original model and this stash are what comes back. The repair this mod applies before the green light is not a rejected repair. A repair after the green light is. If the repair fills the tank, the previous fuel level is written back. A portal applies the stash on the next map when it was not applied yet. After that, a portal still drops damage, as it does today.
- **The classification is one car at a time.** Only the player is in the time trial. Their clock runs from their green light to their finish. An AI vehicle is not an entrant, has no board time, and gets no blue flag. Passing one is a fight on the road. The gap is short, 10 seconds by default, so a clearly faster car still meets the one ahead.
- **One countdown, any length.** The time trial only has a short 3-2-1 sequence and no duration setting. The visible start clock is ours: `countdown_s` in `alpine_rt.json`, in simulation time, any length while the player is held. At zero the player is released and the time-trial clock starts. The mission's 3-2-1 sequence is not played as well.
- **The classified clock is the time trial.** Ordered pathnodes, a start trigger, a finish time, and the mission's local best. Files live in `gameplay/missions/<level>/timeTrial/<missionId>/` as `info.json` and `race.race.json`. The player is the only classified entrant. Start and finish sit before the portal boxes. An accepted run that reaches a portal is aborted, then the map change proceeds as today. Finishing stays in the same freeroam session.

```mermaid
sequenceDiagram
  participant Player
  participant Hold
  participant AI
  participant Trial
  Player->>Hold: Accept start trigger
  Hold->>Hold: Hold player at Player Start
  Hold->>AI: Race mode, release, unclassified
  Note over Hold,Player: countdown_s, any length
  Hold->>Trial: At zero, green, player clock only
```

## On the map

- The freeroam offer is the mission **start trigger**. Accepting opens the start phase. Driving on leaves the trigger alone, and no clock runs.
- The time trial contains only the player. Its clock starts when our countdown reaches zero. The mission's 3-2-1 sequence does not run with it.
- After accept: suspend this map's traffic pool (`setTrafficSuspended` in [`alpinert.lua`](../mods/autoroad_alpine_rt/lua/ge/extensions/alpinert.lua)). The player stays held at the race path's Player Start. AI vehicles from `alpine_rt.json` spawn on the same path, the first furthest ahead, each `spawn_gap_m` (default 8) ahead of the next. They drive the path in race mode and are not part of the time trial. The player's `countdown_s` starts when the first of them is released.
- The default is one vehicle and `countdown_s` 10. Further vehicles are listed in the sidecar and start `handicap_s` apart, all before the player. Green is at zero, and only once the last AI vehicle is at least `clear_m` (default 25) ahead along the path. If that gap is missing, the display stays on the last second and the player clock does not start. If the gap is still missing when the grace period ends, that vehicle is removed and the countdown finishes.
- Contact with the AI does not change the classification. The time counts when the player takes the pathnodes in order and the digest and the path length pass. There is no blue flag.
- A missed pathnode ends the time trial under its own rules and produces no best time.
- Abort: cancel the mission, enter a portal, change map, or leave the stage area. Despawn the AI, record no time, restore traffic, and put the damage stash back on the vehicle. A vehicle change, or a repair after the start signal, also ends the run, stores the digest with the reject reason, and then restores the same stash.
- Opt-out in the app, default on. On: mission best, digest, trace, and upload when a URL is set. Off: the run is left out of mission progress, out of `results.json`, and out of the upload. If the time trial already wrote the attempt, that attempt is dropped. Older entries stay until cleared.

## Local persistence

The stage is a mission the mission manager loads. Shipped stages live in the mod:

`mods/autoroad_alpine_rt/gameplay/missions/<level>/timeTrial/<missionId>/`

- `info.json` — name, type `timeTrial`, start trigger
- `race.race.json` — start, pathnodes, finish, start position; editable in the Race/Path Editor
- `alpine_rt.json` — `version`, `countdown_s`, `handicap_s`, `clear_m`, `spawn_gap_m`, `reference_length_m`

The mission id carries the version code (`…_v3`). A new geometry is a new id, so the game's board and the central board share the same boundary. Missions created in the editor stay in the user folder under `gameplay/missions/…`, where the mission editor writes them.

Also in the user folder, independent of the loaded map:

- BeamNG mission progress — the time trial's local best. It lives in the profile and survives `startLevel`.
- `settings/alpine_rt/results.json` — `share`, name, `leaderboard_url`, digest, reject reason, upload queue. The time itself lives in mission progress.
- `settings/alpine_rt/traces/` — one trace per best run: 10 Hz, `t`, position, rotation, vehicle model and config.
- `settings/alpine_rt/damage_stash.json` — physical state from before the run, until it has been loaded back.

`alpinert_climb` uses the same `setExtensionUnloadMode(..., "manual")` as `alpinert` and aborts a running mission before a portal changes the map. After another alpineRT map loads, the app reads progress and `results.json`.

## Player trace

The GE extension samples only the player's drive at 10 Hz. The trace belongs to the classified run and is part of the upload. It is not played back as an AI vehicle. AI model and pace are set in `alpine_rt.json`. The race-mode calls are checked against `lua/vehicle/ai.lua` in the installed BeamNG version.

## Vehicle before and after

The classification digest describes the race car, not the road damage from before the run. At the green light the car is the repaired one. At the finish it is whatever the run did to it.

- Object id, model, config name, hash of `partConfig`
- Broken-beam count and deformed-beam count from `beamstate` (field names checked against the installed version)
- At the finish, whether the in-vehicle counter fell below its own peak after the green light
- Position

The app and each board entry show the pair, for example `broken 0 → 12` or `autobello → etk800`. There is no periodic damage poll. The counter runs in vehicle Lua and is read once at the finish. The repair key is also caught with `onVehicleResetted`. The repair this mod applies before the start is excluded. The 10 Hz trace stores position and rotation only.

A run is rejected when any of these is true. The time stays on disk with a reason and is left out of the best and the board. The stash is still restored afterwards:

- **Different vehicle.** Model, config hash, or player vehicle id changed, or BeamNG reports `onVehicleSwitched` / replace. The run ends at that moment.
- **Repair during the run.** `onVehicleResetted` after the green light, or the damage counter drops by more than a small amount of noise below the peak since the start. A clean start and a worse car at the finish stay valid.
- **Shortcut.** A missed pathnode is already a failed time trial. The driven polyline is also under 85 percent of the pinned reference length. A wrecked car at the finish stays valid when the pathnodes and the length match.

The author sets the reference length in `alpine_rt.json` with the version code, after the race path exists. Without that pin, times stay local (`unpinned`) and are not accepted centrally. The server checks the report against the same pin: same identity, damage not improved, 85 percent length from the trace, start and finish points on the pathnodes. The same mission id with a different `race.race.json` is rejected.

## Leaderboard

Contract for the existing HTTP service. A small Python script with SQLite under `tools/` can stand in for a trial and can be left unused:

- `POST /v1/tracks` — once per mission id, with an author token: `reference_length_m` and the contents of `race.race.json`.
- `POST /v1/runs` — `track_id`, `version`, `time_ms`, display name, `client_run_id`, mod revision, `vehicle_before`, `vehicle_after` (including whether damage fell below its peak), path length, trace. `client_run_id` is unique. Response `accepted` or `reason`: `vehicle_changed`, `repaired`, `short_path`, `missed_gate`, `unpinned`.
- `GET /v1/tracks/{id}/versions/{version}/leaderboard` — accepted player runs only, each entry with the before/after pair.

The trace stays attached to the run for the check. It is not placed on the road as a vehicle.

Offline, the run remains `pending` in `results.json` and is sent with the next successful run. The app always shows the local best, and the central list once a response arrives.

Physics stays on the client. The board is as reliable as the digest and the trace the server checks against the pinned stage. A modified mod can still fake that report. A vehicle swap, a repair, and a coarse shortcut fail on an honest client and on any report that was not altered.

## Build-out

- New extension [`mods/autoroad_alpine_rt/lua/ge/extensions/alpinert/climb.lua`](../mods/autoroad_alpine_rt/lua/ge/extensions/alpinert/climb.lua), loaded from [`modScript.lua`](../mods/autoroad_alpine_rt/scripts/modScript.lua). It hooks the mission manager, spawns the AI before the countdown outside classification, and writes the digest. [`alpinert.lua`](../mods/autoroad_alpine_rt/lua/ge/extensions/alpinert.lua) suspends traffic and aborts the mission before `queueSwitch`.
- New app `alpineRtClimb` next to the map app: start-phase countdown, opt-out, before/after, local mission best, and the central list. The running clock after the start stays the time-trial UI. The route and the checkpoints are authored in the Race/Path Editor and the Mission Editor.
- App strings stay English, like the existing toasts. The mission UI brings its own strings.
