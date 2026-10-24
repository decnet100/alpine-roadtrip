-- Dry-run search, first slice.
-- One call drives one vehicle along the minimal Imst hillclimb and writes the attempt.
-- The race file is a waypoint path. Stock race AI looks up a navgraph, which this
-- stage does not depend on, so the car follows the pathnode positions directly.

local M = {}

local LEVEL = "imst_tarrenz"
local MISSION = "imst_tarrenz_one_bend_v1"
local RACE_FILE = "gameplay/missions/imst_tarrenz/timeTrial/imst_tarrenz_one_bend_v1/race.race.json"
local SIDE_FILE = "gameplay/missions/imst_tarrenz/timeTrial/imst_tarrenz_one_bend_v1/alpine_rt.json"
local LIST_FILE = "/lua/ge/extensions/alpinert/dryrun_vehicles.json"
local OUT_DIR = "settings/alpine_rt/dryrun/imst_tarrenz_one_bend_v1"

local STEP_M = 4
local TAIL_M = 16
local AGGRESSION = 0.9
local SAMPLE_S = 0.1
local TIMEOUT_S = 90

local run = nil
local queue = {}

local function hypot(x, y)
  return math.sqrt(x * x + y * y)
end

local function levelName()
  if getCurrentLevelIdentifier then
    return getCurrentLevelIdentifier()
  end
  if core_levels and getMissionFilename then
    return core_levels.getLevelName(getMissionFilename())
  end
  return nil
end

local function listRows()
  local data = jsonReadFile(LIST_FILE)
  if not data or type(data.vehicles) ~= "table" then
    return nil
  end
  return data.vehicles
end

local function findRow(model, config)
  local rows = listRows()
  if not rows then
    return nil
  end
  for _, row in ipairs(rows) do
    if row.model == model and row.config == config then
      return row
    end
  end
  return nil
end

local function outFile(model, config)
  return OUT_DIR .. "/" .. model .. "__" .. config .. ".json"
end

local function playerStart(race)
  for _, sp in ipairs(race.startPositions or {}) do
    if sp.name == "Player Start" then
      return sp
    end
  end
  return nil
end

local function densify(nodes)
  local out = {}
  local function push(x, y, z, r)
    local last = out[#out]
    if last and hypot(x - last.x, y - last.y) < 0.4 then
      return
    end
    out[#out + 1] = { x = x, y = y, z = z, r = r }
  end
  for i = 1, #nodes - 1 do
    local a = nodes[i]
    local b = nodes[i + 1]
    local dx = b.pos[1] - a.pos[1]
    local dy = b.pos[2] - a.pos[2]
    local dz = b.pos[3] - a.pos[3]
    local dist = hypot(dx, dy)
    local pieces = math.max(1, math.floor(dist / STEP_M))
    local radius = math.max(a.radius or 4, b.radius or 4)
    for k = 0, pieces - 1 do
      local t = k / pieces
      push(a.pos[1] + dx * t, a.pos[2] + dy * t, a.pos[3] + dz * t, radius)
    end
  end
  local last = nodes[#nodes]
  push(last.pos[1], last.pos[2], last.pos[3], last.radius or 4)
  local prev = nodes[#nodes - 1]
  local tx = last.pos[1] - prev.pos[1]
  local ty = last.pos[2] - prev.pos[2]
  local span = hypot(tx, ty)
  if span > 0.1 then
    tx, ty = tx / span, ty / span
    local covered = 0
    while covered < TAIL_M do
      covered = covered + STEP_M
      push(last.pos[1] + tx * covered, last.pos[2] + ty * covered, last.pos[3], last.radius or 4)
    end
  end
  return out
end

local function distToPoly(px, py, script)
  local best = math.huge
  for i = 1, #script - 1 do
    local a = script[i]
    local b = script[i + 1]
    local dx = b.x - a.x
    local dy = b.y - a.y
    local len2 = dx * dx + dy * dy
    local t = 0
    if len2 > 1e-6 then
      t = ((px - a.x) * dx + (py - a.y) * dy) / len2
      if t < 0 then
        t = 0
      elseif t > 1 then
        t = 1
      end
    end
    local d = hypot(px - (a.x + dx * t), py - (a.y + dy * t))
    if d < best then
      best = d
    end
  end
  return best
end

local function segHits(ax, ay, bx, by, px, py, radius)
  local dx = bx - ax
  local dy = by - ay
  local len2 = dx * dx + dy * dy
  local t = 0
  if len2 > 1e-6 then
    t = ((px - ax) * dx + (py - ay) * dy) / len2
    if t < 0 then
      t = 0
    elseif t > 1 then
      t = 1
    end
  end
  return hypot(px - (ax + dx * t), py - (ay + dy * t)) <= radius
end

local function parkPlayer(startPos, dirx, diry)
  local player = getPlayerVehicle(0)
  if not player then
    return
  end
  local p = player:getPosition()
  if hypot(p.x - startPos[1], p.y - startPos[2]) > 18 then
    return
  end
  local rot = player:getRotation()
  vehicleSetPositionRotation(
    player:getID(),
    p.x - diry * 22,
    p.y + dirx * 22,
    p.z + 0.4,
    rot.x, rot.y, rot.z, rot.w
  )
  log("I", "alpine_rt", "dryrun parked the player 22 m beside the start")
end

local function writeResult(reason)
  if not run or run.phase == "done" or run.phase == "gap" then
    return
  end
  if queue[1] then
    run.phase = "gap"
    run.gap = 0
  else
    run.phase = "done"
  end
  local sidecar = jsonReadFile(SIDE_FILE) or {}
  local ref = tonumber(sidecar.reference_length_m) or 0
  local payload = {
    mission = MISSION,
    model = run.model,
    config = run.config,
    weather = "current",
    aggression = AGGRESSION,
    reason = reason,
    time_ms = math.floor(run.time * 1000 + 0.5),
    gates = run.gate,
    gate_count = #run.gates,
    driven_length_m = run.length,
    reference_length_m = ref,
    length_ok = ref > 0 and run.length >= ref * 0.85,
    trace_hz = 10,
    trace = run.trace,
  }
  local ok = jsonWriteFile(run.outFile, payload, true)
  log("I", "alpine_rt", string.format(
    "dryrun %s %s %s time_ms=%d gates=%d/%d length=%.1f ref=%.1f file=%s",
    run.model, run.config, reason, payload.time_ms, run.gate, #run.gates, run.length, ref, ok and run.outFile or "write failed"
  ))
  local veh = getObjectByID(run.vehId)
  if veh then
    veh:queueLuaCommand('ai.setMode("stop")')
  end
end

local function startVehicle(model, config)
  if run and run.phase ~= "done" and run.phase ~= "gap" then
    log("W", "alpine_rt", "dryrun already running")
    return
  end
  local level = levelName()
  if level ~= LEVEL then
    log("E", "alpine_rt", "dryrun wants " .. LEVEL .. ", current level is " .. tostring(level))
    return
  end
  local row = findRow(model, config)
  if not row then
    log("E", "alpine_rt", "dryrun vehicle list has no " .. tostring(model) .. " / " .. tostring(config))
    return
  end
  local race = jsonReadFile(RACE_FILE)
  if not race or type(race.pathnodes) ~= "table" or #race.pathnodes < 2 then
    log("E", "alpine_rt", "dryrun could not read " .. RACE_FILE)
    return
  end
  local start = playerStart(race)
  if not start then
    log("E", "alpine_rt", "dryrun race file has no Player Start")
    return
  end
  local script = densify(race.pathnodes)
  local dirx = script[2].x - script[1].x
  local diry = script[2].y - script[1].y
  local span = hypot(dirx, diry)
  if span > 0.1 then
    dirx, diry = dirx / span, diry / span
  else
    dirx, diry = 0, 1
  end
  if gameplay_traffic and gameplay_traffic.deleteVehicles then
    gameplay_traffic.deleteVehicles()
    log("I", "alpine_rt", "dryrun removed the traffic pool for this attempt")
  end
  parkPlayer(start.pos, dirx, diry)
  local veh = core_vehicles.spawnNewVehicle(row.model, {
    config = row.config,
    pos = vec3(start.pos[1], start.pos[2], start.pos[3] + 0.6),
    rot = quat(start.rot[1], start.rot[2], start.rot[3], start.rot[4]),
    autoEnterVehicle = false,
    cling = true,
  })
  if not veh then
    log("E", "alpine_rt", "dryrun spawn failed for " .. row.model .. " " .. row.config)
    return
  end
  veh:queueLuaCommand("controller.setFreeze(true)")
  run = {
    phase = "spawn",
    wait = 0,
    time = 0,
    sample = 0,
    length = 0,
    gate = 0,
    off = 0,
    slow = 0,
    flip = 0,
    prev = nil,
    model = row.model,
    config = row.config,
    outFile = outFile(row.model, row.config),
    vehId = veh:getID(),
    gates = race.pathnodes,
    script = script,
    aiArg = serialize({ script = script, aggression = AGGRESSION, avoidCars = "off", noOfLaps = 1 }),
    trace = {},
  }
  log("I", "alpine_rt", string.format(
    "dryrun spawned %s %s id=%d points=%d",
    row.model, row.config, run.vehId, #script
  ))
end

local function startOnce()
  queue = {}
  startVehicle("etkc", "kc6_360_M")
end

local function startRest()
  if run and run.phase ~= "done" and run.phase ~= "gap" then
    log("W", "alpine_rt", "dryrun already running")
    return
  end
  local rows = listRows()
  if not rows then
    log("E", "alpine_rt", "dryrun vehicle list missing")
    return
  end
  queue = {}
  for _, row in ipairs(rows) do
    if not (row.model == "etkc" and row.config == "kc6_360_M") then
      queue[#queue + 1] = row
    end
  end
  local first = table.remove(queue, 1)
  if not first then
    log("W", "alpine_rt", "dryrun has no remaining vehicles")
    return
  end
  log("I", "alpine_rt", "dryrun remaining " .. tostring(1 + #queue))
  startVehicle(first.model, first.config)
end

local function onUpdate(dtReal, dtSim)
  if not run or run.phase == "done" or dtSim <= 0 then
    return
  end
  if run.phase == "gap" then
    run.gap = run.gap + dtSim
    if run.gap < 1.5 then
      return
    end
    local oldId = run.vehId
    local row = table.remove(queue, 1)
    local player = getPlayerVehicle(0)
    local old = getObjectByID(oldId)
    if old and (not player or old:getID() ~= player:getID()) then
      old:delete()
    end
    run.phase = "done"
    if row then
      startVehicle(row.model, row.config)
    end
    return
  end
  if run.phase == "spawn" then
    run.wait = run.wait + dtSim
    local veh = getObjectByID(run.vehId)
    if veh and run.wait > 0.6 then
      veh:queueLuaCommand("controller.setFreeze(false)")
      veh:queueLuaCommand("ai.driveUsingPath(" .. run.aiArg .. ")")
      run.phase = "drive"
      run.time = 0
      log("I", "alpine_rt", "dryrun AI started, aggression " .. tostring(AGGRESSION))
    elseif run.wait > 8 then
      writeResult("spawn_timeout")
    end
    return
  end

  local veh = getObjectByID(run.vehId)
  if not veh then
    writeResult("vehicle_gone")
    return
  end
  run.time = run.time + dtSim
  local pos = veh:getPosition()
  local px, py = pos.x, pos.y

  if run.prev then
    local step = hypot(px - run.prev[1], py - run.prev[2])
    run.length = run.length + step
    local gate = run.gates[run.gate + 1]
    if gate and segHits(run.prev[1], run.prev[2], px, py, gate.pos[1], gate.pos[2], gate.radius or 5) then
      run.gate = run.gate + 1
      log("I", "alpine_rt", string.format("dryrun gate %d/%d t=%.1f", run.gate, #run.gates, run.time))
      if run.gate >= #run.gates then
        writeResult("finish")
        return
      end
    end
  end
  run.prev = { px, py }

  run.sample = run.sample + dtSim
  if run.sample >= SAMPLE_S then
    run.sample = run.sample - SAMPLE_S
    run.trace[#run.trace + 1] = {
      t = math.floor(run.time * 1000 + 0.5) / 1000,
      x = px, y = py, z = pos.z,
    }
  end

  local up = veh:getDirectionVectorUp()
  if up and up.z < 0.2 then
    run.flip = run.flip + dtSim
    if run.flip > 0.6 then
      writeResult("rollover")
      return
    end
  else
    run.flip = 0
  end

  if distToPoly(px, py, run.script) > 16 then
    run.off = run.off + dtSim
    if run.off > 0.8 then
      writeResult("left_road")
      return
    end
  else
    run.off = 0
  end

  local speed = veh:getVelocity():length()
  if run.time > 4 and speed < 1 then
    run.slow = run.slow + dtSim
    if run.slow > 8 then
      writeResult("stopped")
      return
    end
  else
    run.slow = 0
  end

  if run.time > TIMEOUT_S then
    writeResult("timeout")
  end
end

local function onExtensionLoaded()
  log("I", "alpine_rt", "dryrun loaded; startOnce, startVehicle(model, config), startRest")
end

M.startOnce = startOnce
M.startVehicle = startVehicle
M.startRest = startRest
M.onUpdate = onUpdate
M.onExtensionLoaded = onExtensionLoaded

return M
