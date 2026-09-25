-- Alpine Roadtrip: dwell portals + session persist across core_levels.startLevel.
-- Load via scripts/modScript.lua (manual unload). Do not put this in mainLevel.lua.
-- Internal extension id is "alpinert" (no underscore: BeamNG maps foo_bar to foo/bar.lua).

local M = {}

local SESSION_PATH = "settings/alpine_rt/session.json"
local GRAPH_PATH = "settings/alpine_rt/graph.json"
local PORTALS_PATH = "/lua/ge/extensions/alpinert/portals.json"
-- Bump this when Lua changes; shown on load so a stale in-memory copy is obvious.
local LUA_REV = "2026-09-24k"
-- 24x: 1 real hour = 1 game day (radio hour = 150 s). Weather tick stays UDW's real-time clock.
local DAY_LENGTH_S = 3600

local portals = { grace_s = 8, gates = {} }
local userLocations = {}
local mergeUserGraph
local dwellGate = nil
local dwellAcc = 0
local dwellNeed = 0
local lastMsgS = -1
local dwellMsgHold = 0
local graceUntil = 0
local switchQueued = nil
local worldReady = false
local restoreArmed = false
local restoreTries = 0
local udwResumeLeft = nil
local trafficSpawnedFor = nil
local trafficWait = 0
-- Temporary test. Kauns is the Reschen level. Densities also drive the map colours and the portal wait.
local TEST_TRAFFIC = {
  -- cars = pool. active = how many of those run physics at once (BeamNG slider tops out at 15).
  autoroad_fernpass_8192 = { dens = 0.90, cars = 100, active = 15 },
  autoroad_imst_8192 = { dens = 0.22, cars = 3 },
  autoroad_reschen_8192 = { dens = 0.55, cars = 8 },
}
-- UV Rotate Animation on the rotor material; Lua spin stays off.
local FAN_RPM = 0
local FAN_RAD_PER_S = FAN_RPM * math.pi / 30
local fanRotors = nil
local fanAngle = 0

local function now()
  return os.clock()
end

local function currentLevel()
  local id
  if getCurrentLevelIdentifier then
    id = getCurrentLevelIdentifier()
  end
  if type(id) ~= "string" or id == "" then
    return nil
  end
  id = id:gsub("\\", "/"):gsub("^/levels/", ""):gsub("/+$", "")
  local slash = id:find("/")
  if slash then
    id = id:sub(1, slash - 1)
  end
  return id
end

local function jsonClone(v)
  if v == nil then
    return nil
  end
  local ok, encoded = pcall(jsonEncode, v)
  if not ok or not encoded then
    return nil
  end
  local ok2, decoded = pcall(jsonDecode, encoded)
  if not ok2 then
    return nil
  end
  return decoded
end

local function uiMsg(text, ttl)
  ttl = ttl or 1
  if ui_message then
    ui_message(text, ttl, "info")
  elseif guihooks then
    guihooks.trigger("Message", { ttl = ttl, msg = text, category = "alpine_rt" })
  end
end

local function loadPortals()
  local data = jsonReadFile(PORTALS_PATH)
  if type(data) == "table" and type(data.gates) == "table" then
    portals = data
    log("I", "alpine_rt", "Loaded " .. tostring(#portals.gates) .. " gates from " .. PORTALS_PATH)
  else
    log("W", "alpine_rt", "No portals.json at " .. PORTALS_PATH)
    portals = { grace_s = 8, gates = {} }
  end
  if mergeUserGraph then
    mergeUserGraph()
  end
end

local function readSession()
  local data = jsonReadFile(SESSION_PATH)
  if type(data) == "table" then
    return data
  end
  return nil
end

local function writeSession(data)
  jsonWriteFile(SESSION_PATH, data, true)
end

local function isAlpineRoadtripLevel(level)
  level = level or currentLevel()
  if not level then
    return false
  end
  if userLocations[level] then
    return true
  end
  for _, g in ipairs(portals.gates or {}) do
    if g.from_level == level or g.to_level == level then
      return true
    end
  end
  return false
end

local BOX_SIZE = { 12, 8, 6 }
local ARRIVE_AHEAD_M = 20

local function norm2(x, y)
  local n = math.sqrt(x * x + y * y)
  if n < 1e-6 then
    return 0, 1
  end
  return x / n, y / n
end

local function mapAuthority()
  local crs = portals.map and portals.map.crs
  if type(crs) ~= "string" then
    return nil
  end
  crs = crs:gsub("^%s+", ""):gsub("%s+$", "")
  if crs == "" then
    return nil
  end
  return crs
end

-- EPSG:31254, Bessel transverse mercator. Datum shift omitted (~100 m).
local function wgs84ToGkWest(latDeg, lonDeg)
  local a = 6377397.155
  local f = 1 / 299.1528128
  local b = a * (1 - f)
  local e2 = (a * a - b * b) / (a * a)
  local ep2 = (a * a - b * b) / (b * b)
  local lon0 = math.rad(10 + 20 / 60)
  local e4 = e2 * e2
  local e6 = e4 * e2
  local lat = math.rad(latDeg)
  local lon = math.rad(lonDeg)
  local sinLat = math.sin(lat)
  local cosLat = math.cos(lat)
  local Nrad = a / math.sqrt(1 - e2 * sinLat * sinLat)
  local T = math.tan(lat) * math.tan(lat)
  local C = ep2 * cosLat * cosLat
  local A = (lon - lon0) * cosLat
  local M = a * (
    (1 - e2 / 4 - 3 * e4 / 64 - 5 * e6 / 256) * lat
    - (3 * e2 / 8 + 3 * e4 / 32 + 45 * e6 / 1024) * math.sin(2 * lat)
    + (15 * e4 / 256 + 45 * e6 / 1024) * math.sin(4 * lat)
    - (35 * e6 / 3072) * math.sin(6 * lat)
  )
  local x = Nrad * (
    A
    + (1 - T + C) * A * A * A / 6
    + (5 - 18 * T + T * T + 72 * C - 58 * ep2) * A * A * A * A * A / 120
  )
  local y = M + Nrad * math.tan(lat) * (
    A * A / 2
    + (5 - T + 9 * C + 4 * C * C) * A * A * A * A / 24
    + (61 - 58 * T + T * T + 600 * C - 330 * ep2) * A * A * A * A * A * A / 720
  )
  return x, y - 5000000
end

local function projectToAuthority(lat, lon, authority)
  if authority == "EPSG:31254" then
    local e, n = wgs84ToGkWest(lat, lon)
    return e, n, nil
  end
  return nil, nil, "Map CRS authority " .. tostring(authority) .. " is not supported. This map was not added."
end

local function overviewBBox()
  local b = portals.map and portals.map.bbox
  if type(b) ~= "table" or b[4] == nil then
    return nil
  end
  return b
end

local function inOverview(e, n)
  local b = overviewBBox()
  if not b or not e or not n then
    return false
  end
  return e >= b[1] and e <= b[3] and n >= b[2] and n <= b[4]
end

local function centerOf(levelId)
  local loc = userLocations[levelId]
  if loc and type(loc.crs) == "table" and loc.crs[1] and loc.crs[2] then
    return loc.crs[1], loc.crs[2]
  end
  local levels = portals.map and portals.map.levels
  local rec = levels and levels[levelId]
  if rec and type(rec.crs) == "table" and rec.crs[1] and rec.crs[2] then
    return rec.crs[1], rec.crs[2]
  end
  return nil
end

local function northOf(levelId)
  local loc = userLocations[levelId]
  if loc and type(loc.north) == "table" and loc.north[1] and loc.north[2] then
    return loc.north[1], loc.north[2]
  end
  if centerOf(levelId) then
    return 0, 1
  end
  return nil
end

local function locationReady(levelId)
  if not levelId then
    return false
  end
  local loc = userLocations[levelId]
  if loc and loc.wgs84 and loc.north and loc.crs then
    return true
  end
  local levels = portals.map and portals.map.levels
  local rec = levels and levels[levelId]
  return type(rec) == "table" and type(rec.crs) == "table" and rec.crs[1] ~= nil
end

local function readGraph()
  local data = jsonReadFile(GRAPH_PATH)
  if type(data) ~= "table" then
    return { locations = {}, gates = {} }
  end
  if type(data.locations) ~= "table" then
    data.locations = {}
  end
  if type(data.gates) ~= "table" then
    data.gates = {}
  end
  return data
end

local function writeGraph(data)
  jsonWriteFile(GRAPH_PATH, data, true)
end

local function reloadPortals()
  local dwellId = dwellGate and dwellGate.id
  loadPortals()
  if not dwellId then
    return
  end
  for _, g in ipairs(portals.gates or {}) do
    if g.id == dwellId then
      dwellGate = g
      return
    end
  end
  dwellGate = nil
end

local function levelTitle(id)
  local info = jsonReadFile("/levels/" .. tostring(id) .. "/info.json")
  if type(info) == "table" and type(info.title) == "string" and info.title ~= "" then
    return info.title
  end
  return tostring(id)
end

local function vehiclePose()
  if not be then
    return nil
  end
  local ok, veh = pcall(function()
    return be:getPlayerVehicle(0)
  end)
  if not ok or not veh or not veh.getPosition or not veh.getDirectionVector then
    return nil
  end
  local p = veh:getPosition()
  local d = veh:getDirectionVector()
  if not p or not d then
    return nil
  end
  local tx, ty = norm2(d.x or 0, d.y or 0)
  return { p.x, p.y, p.z }, { tx, ty }
end

local function northFromForward(tx, ty, cardinal)
  if cardinal == "north" then
    return tx, ty
  end
  if cardinal == "south" then
    return -tx, -ty
  end
  if cardinal == "east" then
    return -ty, tx
  end
  if cardinal == "west" then
    return ty, -tx
  end
  return nil
end

local function ahead(pos, tangent, meters)
  local tx, ty = norm2(tangent[1] or 1, tangent[2] or 0)
  return { pos[1] + tx * meters, pos[2] + ty * meters, pos[3] }
end

local function publishLocation(levelId, loc)
  portals.map = portals.map or {}
  portals.map.levels = portals.map.levels or {}
  local rec = portals.map.levels[levelId] or {}
  if loc and type(loc.crs) == "table" and inOverview(loc.crs[1], loc.crs[2]) then
    rec.crs = { loc.crs[1], loc.crs[2] }
  end
  if loc and loc.name then
    rec.title = loc.name
  end
  portals.map.levels[levelId] = rec
end

local function touchLevel(levelId)
  if not levelId then
    return
  end
  portals.map = portals.map or {}
  portals.map.levels = portals.map.levels or {}
  portals.map.levels[levelId] = portals.map.levels[levelId] or {}
end

local function addUserRoads()
  portals.roads = portals.roads or {}
  local used = {}
  for _, g in ipairs(portals.gates or {}) do
    if g.user and not used[g.id] then
      local rev
      for _, o in ipairs(portals.gates) do
        if o ~= g and o.from_level == g.to_level and o.to_level == g.from_level and o.box then
          rev = o
          break
        end
      end
      used[g.id] = true
      if rev then
        used[rev.id] = true
      end
      local e1, n1 = centerOf(g.from_level)
      local e2, n2 = centerOf(g.to_level)
      if e1 and e2 and inOverview(e1, n1) and inOverview(e2, n2) then
        portals.roads[#portals.roads + 1] = {
          id = "user:" .. tostring(g.id),
          a = g.id,
          b = rev and rev.id or nil,
          map_mark = {
            crs = { (e1 + e2) * 0.5, (n1 + n2) * 0.5 },
            heading = { e2 - e1, n2 - n1 },
            length_px = 28,
            gap_px = 7,
          },
        }
      end
    end
  end
end

mergeUserGraph = function()
  local graph = readGraph()
  userLocations = graph.locations
  for _, g in ipairs(graph.gates) do
    if type(g) == "table" and g.id and g.from_level and g.box then
      g.user = true
      g.arc = nil
      portals.gates = portals.gates or {}
      portals.gates[#portals.gates + 1] = g
    end
  end
  for levelId, loc in pairs(userLocations) do
    publishLocation(levelId, loc)
  end
  for _, g in ipairs(graph.gates) do
    if type(g) == "table" then
      touchLevel(g.from_level)
      touchLevel(g.to_level)
    end
  end
  addUserRoads()
end

local function ensureUserArc(gate)
  if not gate or not gate.user or not gate.box or not gate.box.pos then
    return
  end
  local pos = gate.box.pos
  local e1, n1 = centerOf(gate.from_level)
  local e2, n2 = centerOf(gate.to_level)
  local nx, ny = northOf(gate.from_level)
  local dx, dy, length_m
  if e1 and e2 and nx then
    nx, ny = norm2(nx, ny)
    local ex, ey = ny, -nx
    local east_m = e2 - e1
    local north_m = n2 - n1
    dx = east_m * ex + north_m * nx
    dy = east_m * ey + north_m * ny
    length_m = math.sqrt(dx * dx + dy * dy)
    if length_m < 50 then
      dx, dy, length_m = nil, nil, nil
    else
      gate.center_distance_m = length_m
    end
  end
  if not dx then
    local t = gate.box.tangent or { 1, 0 }
    dx, dy = norm2(t[1] or 1, t[2] or 0)
    length_m = 800
    dx, dy = dx * length_m, dy * length_m
  end
  local peak = math.min(250, math.max(40, length_m * 0.04))
  local pts = {}
  local samples = 24
  for i = 0, samples do
    local u = i / samples
    pts[#pts + 1] = {
      pos[1] + dx * u,
      pos[2] + dy * u,
      pos[3] + 4.5 + 4 * peak * u * (1 - u),
    }
  end
  local inv = 1 / math.max(length_m, 1)
  gate.arc = {
    points = pts,
    width_m = 15,
    length_m = length_m,
    generated = true,
    heading = { dx * inv, dy * inv },
  }
end

local function drawUserPortals(level)
  if not debugDrawer or not vec3 or not ColorF or not level then
    return
  end
  local col = ColorF(1.0, 0.35, 0.2, 1.0)
  for _, g in ipairs(portals.gates or {}) do
    if g.user and g.from_level == level and g.box and g.box.pos and g.box.size then
      local c = g.box.pos
      local s = g.box.size
      local fx, fy = norm2((g.box.tangent or { 1, 0 })[1], (g.box.tangent or { 1, 0 })[2])
      local rx, ry = -fy, fx
      local hx, hy = (s[1] or 12) * 0.5, (s[2] or 8) * 0.5
      local z = c[3]
      local function corner(sa, sb)
        return vec3(c[1] + fx * hx * sa + rx * hy * sb, c[2] + fy * hx * sa + ry * hy * sb, z)
      end
      local a, b, d, e = corner(1, 1), corner(1, -1), corner(-1, -1), corner(-1, 1)
      pcall(function()
        debugDrawer:drawLine(a, b, col)
        debugDrawer:drawLine(b, d, col)
        debugDrawer:drawLine(d, e, col)
        debugDrawer:drawLine(e, a, col)
      end)
    end
  end
end

local function findUserGate(fromLevel, toLevel)
  for _, g in ipairs(portals.gates or {}) do
    if g.user and g.from_level == fromLevel and g.to_level == toLevel and g.box then
      return g
    end
  end
  return nil
end

local function openReturns(level)
  local out = {}
  if not level then
    return out
  end
  for _, g in ipairs(portals.gates or {}) do
    if g.user and g.to_level == level and g.box and not findUserGate(level, g.from_level) then
      local back = false
      for _, o in ipairs(portals.gates) do
        if o.from_level == level and o.to_level == g.from_level and o.box then
          back = true
          break
        end
      end
      if not back then
        out[#out + 1] = {
          id = g.id,
          from_level = g.from_level,
          label = g.label or g.from_level,
        }
      end
    end
  end
  return out
end

local function setupState()
  local level = currentLevel()
  local loc = level and userLocations[level] or nil
  local lat, lon
  if loc and type(loc.wgs84) == "table" then
    lat, lon = loc.wgs84[1], loc.wgs84[2]
  end
  return {
    authority = mapAuthority(),
    defined = locationReady(level),
    name = loc and loc.name or nil,
    lat = lat,
    lon = lon,
    open_returns = openReturns(level),
  }
end

local function fail(msg)
  return { ok = false, error = msg }
end

local function defineLocation(name, lat, lon, cardinal)
  local level = currentLevel()
  if not level then
    return fail("No level is loaded.")
  end
  local authority = mapAuthority()
  if not authority then
    return fail("No map CRS authority is configured. This map was not added.")
  end
  name = tostring(name or ""):gsub("^%s+", ""):gsub("%s+$", "")
  if name == "" then
    return fail("Location name is required.")
  end
  if #name > 48 then
    name = name:sub(1, 48)
  end
  lat, lon = tonumber(lat), tonumber(lon)
  if not lat or not lon or lat < -90 or lat > 90 or lon < -180 or lon > 180 then
    return fail("Latitude and longitude are required.")
  end
  local pos, tangent = vehiclePose()
  if not pos then
    return fail("No vehicle.")
  end
  local nx, ny = northFromForward(tangent[1], tangent[2], tostring(cardinal or ""))
  if not nx then
    return fail("Pick roughly north, east, south, or west.")
  end
  local e, n, err = projectToAuthority(lat, lon, authority)
  if not e then
    return fail(err)
  end
  local graph = readGraph()
  graph.locations[level] = {
    name = name,
    wgs84 = { lat, lon },
    crs = { e, n },
    authority = authority,
    north = { nx, ny },
    cardinal = cardinal,
    anchor_beamng = pos,
  }
  writeGraph(graph)
  reloadPortals()
  uiMsg("Map registered: " .. name, 4)
  log("I", "alpine_rt", string.format("defined %s %s %.5f %.5f", level, authority, lat, lon))
  return { ok = true, authority = authority, east = e, north = n }
end

local function placePortal(toLevel)
  toLevel = tostring(toLevel or "")
  local level = currentLevel()
  if not level then
    return fail("No level is loaded.")
  end
  if toLevel == "" or toLevel == level then
    return fail("Choose another map.")
  end
  if not locationReady(level) then
    return fail("Define this map first.")
  end
  local pos, tangent = vehiclePose()
  if not pos then
    return fail("No vehicle.")
  end
  local graph = readGraph()
  local existing
  for _, g in ipairs(graph.gates) do
    if g.from_level == level and g.to_level == toLevel then
      existing = g
      break
    end
  end
  local gate = existing or {
    id = "user_" .. level .. "_" .. toLevel .. "_" .. tostring(os.time()),
    from_level = level,
    to_level = toLevel,
    user = true,
  }
  gate.label = "To " .. levelTitle(toLevel)
  gate.box = { pos = pos, tangent = tangent, size = { BOX_SIZE[1], BOX_SIZE[2], BOX_SIZE[3] } }
  if not existing then
    graph.gates[#graph.gates + 1] = gate
  end
  writeGraph(graph)
  reloadPortals()
  uiMsg("Portal to " .. levelTitle(toLevel), 4)
  return { ok = true, id = gate.id }
end

local function placeReturn(gateId)
  gateId = tostring(gateId or "")
  local level = currentLevel()
  if not level then
    return fail("No level is loaded.")
  end
  if not locationReady(level) then
    return fail("Define this map first.")
  end
  local graph = readGraph()
  local inbound
  for _, g in ipairs(graph.gates) do
    if g.id == gateId and g.to_level == level then
      inbound = g
      break
    end
  end
  if not inbound or not inbound.box or not inbound.box.pos then
    return fail("Open connection not found.")
  end
  for _, g in ipairs(graph.gates) do
    if g.from_level == level and g.to_level == inbound.from_level then
      return fail("Return portal already exists.")
    end
  end
  local pos, tangent = vehiclePose()
  if not pos then
    return fail("No vehicle.")
  end
  local back = {
    id = "user_" .. level .. "_" .. inbound.from_level .. "_" .. tostring(os.time()),
    from_level = level,
    to_level = inbound.from_level,
    label = "To " .. levelTitle(inbound.from_level),
    user = true,
    box = { pos = pos, tangent = tangent, size = { BOX_SIZE[1], BOX_SIZE[2], BOX_SIZE[3] } },
    arrive = { pos = ahead(inbound.box.pos, inbound.box.tangent or tangent, ARRIVE_AHEAD_M), tangent = inbound.box.tangent or tangent },
  }
  inbound.arrive = { pos = ahead(pos, tangent, ARRIVE_AHEAD_M), tangent = tangent }
  graph.gates[#graph.gates + 1] = back
  writeGraph(graph)
  reloadPortals()
  uiMsg("Return portal to " .. levelTitle(inbound.from_level), 4)
  return { ok = true, id = back.id }
end

local function listLevels()
  local out = {}
  local seen = {}
  local function add(id, title)
    if type(id) ~= "string" or id == "" or seen[id] or id == currentLevel() then
      return
    end
    seen[id] = true
    out[#out + 1] = { id = id, title = title or levelTitle(id) }
  end
  local raw
  if core_levels and core_levels.getList then
    local ok, res = pcall(core_levels.getList)
    if ok then
      raw = res
    end
  end
  if type(raw) == "table" then
    if #raw > 0 then
      for i = 1, #raw do
        local v = raw[i]
        if type(v) == "table" then
          add(v.levelName or v.name, v.title)
        elseif type(v) == "string" then
          add(v, nil)
        end
      end
    else
      for k, v in pairs(raw) do
        if type(v) == "table" then
          local id = v.levelName or v.name
          if type(id) ~= "string" and type(k) == "string" then
            id = k
          end
          add(id, v.title)
        elseif type(k) == "string" then
          add(k, type(v) == "string" and v or nil)
        end
      end
    end
  end
  if #out == 0 and FS and FS.findFiles then
    local ok, files = pcall(function()
      return FS:findFiles("/levels/", "info.json", 1, true, false)
    end)
    if ok and type(files) == "table" then
      for _, path in ipairs(files) do
        if type(path) == "string" then
          add(path:match("/levels/([^/]+)/info%.json") or path:match("levels/([^/]+)/info%.json"), nil)
        end
      end
    end
  end
  table.sort(out, function(a, b)
    return tostring(a.title):lower() < tostring(b.title):lower()
  end)
  return out
end

local function envTime(env)
  if type(env) ~= "table" then
    return nil
  end
  if type(env.time) == "number" then
    return env.time
  end
  if type(env.timeOfDay) == "table" and type(env.timeOfDay.time) == "number" then
    return env.timeOfDay.time
  end
  return nil
end

-- Sun clock only. Do not push fog/clouds via setState: jbWeather's onClientStartMission
-- resets to clear, and core_environment.setState retriggers the map default sky.
local function applyClock(env)
  if not (core_environment and core_environment.getTimeOfDay and core_environment.setTimeOfDay) then
    return
  end
  local tod = core_environment.getTimeOfDay() or {}
  local t = envTime(env)
  if t == nil and core_environment.getState then
    t = envTime(core_environment.getState())
  end
  if t ~= nil then
    tod.time = t
  end
  tod.play = true
  tod.dayLength = DAY_LENGTH_S
  tod.dayScale = 1
  tod.nightScale = 1
  pcall(function()
    core_environment.setTimeOfDay(tod)
  end)
end

local function ensureJbWeather()
  if not (extensions and extensions.load) then
    return nil
  end
  if not (extensions.jbWeather and extensions.jbWeather.getForecast) then
    pcall(extensions.load, "jbWeather")
  end
  if extensions.jbWeather and extensions.jbWeather.getForecast then
    return extensions.jbWeather
  end
  return nil
end

local function snapshotUdw()
  local jbw = ensureJbWeather()
  if not jbw then
    return nil
  end
  local fc
  local ok, data = pcall(jbw.getForecast)
  if ok and type(data) == "table" and data.current then
    fc = jsonClone(data) or data
  end
  if type(fc) ~= "table" then
    return nil
  end
  if jbw.getLook then
    local okL, look = pcall(jbw.getLook)
    if okL and type(look) == "table" then
      fc.look = jsonClone(look) or look
    end
  end
  return fc
end

-- jbWeather has no setState. onClientStartMission wipes to clear; we re-apply the last
-- preset and delay startForecast until nextIn so the portal does not skip a weather step.
local function applyUdw(st)
  udwResumeLeft = nil
  if type(st) ~= "table" or not st.current then
    return
  end
  local jbw = ensureJbWeather()
  if not jbw then
    log("W", "alpine_rt", "jbWeather not loaded, skip UDW restore")
    return
  end
  if st.look and jbw.setLookAll then
    pcall(jbw.setLookAll, st.look.dark, st.look.cloud, st.look.fog, st.look.grey)
  end
  if st.current == "custom" then
    log("I", "alpine_rt", "UDW was custom; sliders are not in getForecast, skip")
  elseif jbw.setPreset then
    pcall(jbw.setPreset, st.current, 1)
  end
  if st.tickInterval and jbw.setTick then
    pcall(jbw.setTick, st.tickInterval)
  end
  if st.forecastOn then
    local wait = tonumber(st.nextIn)
    if wait == nil then
      wait = tonumber(st.tickInterval) or 180
    end
    udwResumeLeft = math.max(0.05, wait)
  end
  log("I", "alpine_rt", "UDW restore " .. tostring(st.current)
    .. (st.forecastOn and (" forecast in " .. tostring(udwResumeLeft) .. "s") or ""))
end

local function tickUdwResume(dtReal)
  if not udwResumeLeft then
    return
  end
  udwResumeLeft = udwResumeLeft - (dtReal or 0)
  if udwResumeLeft > 0 then
    return
  end
  udwResumeLeft = nil
  local jbw = ensureJbWeather()
  if not (jbw and jbw.startForecast) then
    return
  end
  local tick = 180
  local session = readSession()
  if session and session.udw and session.udw.tickInterval then
    tick = session.udw.tickInterval
  end
  pcall(jbw.startForecast, tick)
  log("I", "alpine_rt", "UDW forecast resumed")
end

local function snapshotEnvironment()
  local env
  if core_environment and core_environment.getState then
    env = jsonClone(core_environment.getState())
  elseif core_environment and core_environment.getTimeOfDay then
    env = jsonClone(core_environment.getTimeOfDay())
  end
  return { environment = env }
end

local function playerVehicle()
  if not be then
    return nil
  end
  local ok, veh = pcall(function()
    return be:getPlayerVehicle(0)
  end)
  if ok then
    return veh
  end
  return nil
end

local function snapshotVehicle()
  local veh = playerVehicle()
  if not veh then
    return nil
  end
  local model = veh.jbeam or veh.JBeam
  local config
  if core_vehicle_manager and core_vehicle_manager.getPlayerVehicleData then
    local vd = core_vehicle_manager.getPlayerVehicleData()
    if vd then
      config = jsonClone(vd.config)
      if not model and vd.config and vd.config.model then
        model = vd.config.model
      end
    end
  end
  if not config then
    local pc = veh.partConfig
    if type(pc) == "string" or type(pc) == "table" then
      config = jsonClone(pc) or pc
    end
  end
  if not model then
    return nil
  end
  return { model = model, config = config }
end

local function yawToQuat(tx, ty)
  local dx, dy = tonumber(tx) or 1, tonumber(ty) or 0
  local n = math.sqrt(dx * dx + dy * dy)
  if n < 1e-6 then
    dx, dy = 1, 0
  else
    dx, dy = dx / n, dy / n
  end
  if quatFromDir then
    return quatFromDir(vec3(dx, dy, 0), vec3(0, 0, 1))
  end
  local yaw = math.atan2(dx, dy)
  local half = yaw * 0.5
  return quat(0, 0, math.sin(half), math.cos(half))
end

local function teleportToArrive(arrive)
  local veh = playerVehicle()
  if not veh or not arrive or not arrive.pos then
    return
  end
  local p = arrive.pos
  local pos = vec3(p[1], p[2], p[3])
  local t = arrive.tangent or { 1, 0 }
  local rot = yawToQuat(t[1], t[2])
  if spawn and spawn.safeTeleport then
    spawn.safeTeleport(veh, pos, rot)
  else
    veh:setPositionRotation(pos.x, pos.y, pos.z, rot.x, rot.y, rot.z, rot.w)
  end
end

local function gatesForLevel(level)
  local out = {}
  if not level then
    return out
  end
  for _, g in ipairs(portals.gates or {}) do
    if g.from_level == level then
      table.insert(out, g)
    end
  end
  return out
end

local function pointInBox(px, py, pz, box)
  if not box or not box.pos or not box.size then
    return false
  end
  local c = box.pos
  local s = box.size
  local t = box.tangent or { 1, 0 }
  local fx, fy = t[1], t[2]
  local n = math.sqrt(fx * fx + fy * fy)
  if n < 1e-6 then
    fx, fy = 1, 0
  else
    fx, fy = fx / n, fy / n
  end
  local rx, ry = -fy, fx
  local dx, dy, dz = px - c[1], py - c[2], pz - c[3]
  local along = dx * fx + dy * fy
  local across = dx * rx + dy * ry
  return math.abs(along) <= s[1] * 0.5
    and math.abs(across) <= s[2] * 0.5
    and math.abs(dz) <= (s[3] * 0.5 + 4)
end

local function playerInGate(gate)
  local veh = playerVehicle()
  if not veh then
    return false
  end
  local p = veh:getPosition()
  return pointInBox(p.x, p.y, p.z, gate.box)
end

local function drawGateArc(gate)
  local arc = gate and gate.arc
  if not arc or type(arc.points) ~= "table" or #arc.points < 2 then
    return
  end
  if not debugDrawer then
    return
  end
  local col = ColorF(1.0, 0.35, 0.22, 1.0)
  local colDim = ColorF(1.0, 0.35, 0.22, 0.35)
  local w = tonumber(arc.width_m) or 15
  local hw = w * 0.5
  for i = 1, #arc.points - 1 do
    local a = arc.points[i]
    local b = arc.points[i + 1]
    if a and b then
      local ax, ay, az = a[1], a[2], a[3]
      local bx, by, bz = b[1], b[2], b[3]
      pcall(function()
        debugDrawer:drawLine(vec3(ax, ay, az), vec3(bx, by, bz), col)
      end)
      -- 20 m wide: two edge lines
      local tx, ty = bx - ax, by - ay
      local len = math.sqrt(tx * tx + ty * ty)
      if len > 1e-3 then
        local rx, ry = -ty / len * hw, tx / len * hw
        pcall(function()
          debugDrawer:drawLine(vec3(ax - rx, ay - ry, az), vec3(bx - rx, by - ry, bz), colDim)
          debugDrawer:drawLine(vec3(ax + rx, ay + ry, az), vec3(bx + rx, by + ry, bz), colDim)
        end)
      end
    end
  end
end

local liveArcId = nil
local liveArcGateId = nil

local function hideAllArcs()
  if liveArcId then
    local obj = scenetree.findObjectById and scenetree.findObjectById(liveArcId)
    if obj then
      pcall(function()
        obj:delete()
      end)
    end
  end
  local leftover = scenetree.findObject and scenetree.findObject("alpine_rt_arc_live")
  if leftover then
    pcall(function()
      leftover:delete()
    end)
  end
  liveArcId = nil
  liveArcGateId = nil
end

local function ensureLiveArc(gate)
  if not gate or not createObject then
    return false
  end
  if liveArcGateId == gate.id and liveArcId then
    local existing = scenetree.findObjectById and scenetree.findObjectById(liveArcId)
    if existing then
      existing.hidden = false
      existing.isRenderEnabled = true
      return true
    end
  end
  hideAllArcs()
  local pts = gate.arc and gate.arc.points
  if not pts or not pts[1] then
    return false
  end
  local level = currentLevel()
  if not level then
    return false
  end
  local shape = string.format(
    "/levels/%s/art/shapes/portals/portal_arc_%s.dae",
    level,
    tostring(gate.id)
  )
  local obj = createObject("TSStatic")
  if not obj then
    log("E", "alpine_rt", "createObject TSStatic failed")
    return false
  end
  obj.canSave = false
  obj:setField("shapeName", 0, shape)
  obj.shapeName = shape
  obj:setField("collisionType", 0, "None")
  obj:setField("decalType", 0, "None")
  obj:setField("castShadows", 0, "0")
  obj:setPosition(vec3(pts[1][1], pts[1][2], pts[1][3]))
  obj.scale = vec3(1, 1, 1)
  obj.hidden = false
  obj.isRenderEnabled = true
  obj:registerObject("alpine_rt_arc_live")
  local grp = scenetree.findObject and (
    scenetree.findObject("alpine_rt_portals") or scenetree.findObject("MissionGroup")
  )
  if grp and grp.addObject then
    pcall(function()
      grp:addObject(obj)
    end)
  end
  liveArcId = obj:getId()
  liveArcGateId = gate.id
  log("I", "alpine_rt", "Spawned arc " .. shape)
  return true
end

-- BeamNG TimeOfDay.time: 0=noon, 0.25=sunset, 0.5=midnight, 0.75=sunrise.
local function todToHour(t)
  t = tonumber(t)
  if t == nil then
    return 12
  end
  return (t * 24 + 12) % 24
end

local function readTodFraction()
  if core_environment and core_environment.getTimeOfDay then
    local tod = core_environment.getTimeOfDay()
    if type(tod) == "table" and type(tod.time) == "number" then
      return tod.time % 1
    end
  end
  if core_environment and core_environment.getState then
    local t = envTime(core_environment.getState())
    if t ~= nil then
      return t % 1
    end
  end
  return nil
end

local function parseYmd(s)
  local y, m, d = tostring(s or ""):match("^(%d%d%d%d)%-(%d%d)%-(%d%d)")
  if not y then
    local now = os.date("!*t")
    return now.year, now.month, now.day
  end
  return tonumber(y), tonumber(m), tonumber(d)
end

local function isLeap(y)
  return y % 4 == 0 and (y % 100 ~= 0 or y % 400 == 0)
end

local MONTH_DAYS = { 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 }

local function addDays(y, m, d, n)
  d = d + (n or 0)
  while d < 1 do
    m = m - 1
    if m < 1 then
      m = 12
      y = y - 1
    end
    local dim = MONTH_DAYS[m]
    if m == 2 and isLeap(y) then
      dim = 29
    end
    d = d + dim
  end
  while true do
    local dim = MONTH_DAYS[m]
    if m == 2 and isLeap(y) then
      dim = 29
    end
    if d <= dim then
      break
    end
    d = d - dim
    m = m + 1
    if m > 12 then
      m = 1
      y = y + 1
    end
  end
  return y, m, d
end

-- 0=Sunday … 6=Saturday (Sakamoto).
local function weekdaySun0(y, m, d)
  local t = { 0, 3, 2, 5, 0, 3, 5, 1, 4, 6, 2, 4 }
  local yy = y
  if m < 3 then
    yy = yy - 1
  end
  return (yy + math.floor(yy / 4) - math.floor(yy / 100) + math.floor(yy / 400) + t[m] + d) % 7
end

local function easterYmd(y)
  local a = y % 19
  local b = math.floor(y / 100)
  local c = y % 100
  local d = math.floor(b / 4)
  local e = b % 4
  local f = math.floor((b + 8) / 25)
  local g = math.floor((b - f + 1) / 3)
  local h = (19 * a + b - d - g + 15) % 30
  local i = math.floor(c / 4)
  local k = c % 4
  local l = (32 + 2 * e + 2 * i - h - k) % 7
  local n = math.floor((a + 11 * h + 22 * l) / 451)
  local month = math.floor((h + l - 7 * n + 114) / 31)
  local day = ((h + l - 7 * n + 114) % 31) + 1
  return month, day
end

local function ymdNum(m, d)
  return m * 100 + d
end

local function daysBetween(y1, m1, d1, y2, m2, d2)
  local function absDay(y, m, d)
    local v = d
    for i = 1, m - 1 do
      v = v + MONTH_DAYS[i]
      if i == 2 and isLeap(y) then
        v = v + 1
      end
    end
    v = v + (y - 2000) * 365 + math.floor((y - 2000 + 3) / 4)
    return v
  end
  return absDay(y2, m2, d2) - absDay(y1, m1, d1)
end

-- Nationwide-ish DE travel windows, not every Bundesland calendar.
local function holidayFactor(y, m, d)
  local md = ymdNum(m, d)
  local em, ed = easterYmd(y)
  local fromEaster = daysBetween(y, em, ed, y, m, d)
  if md >= 701 and md <= 815 then
    return 1.85, "Sommerferien"
  end
  if md >= 626 and md <= 630 then
    return 1.45, "Sommerferien"
  end
  if md >= 816 and md <= 910 then
    return 1.45, "Sommerferien"
  end
  if md >= 1220 or md <= 106 then
    return 1.65, "Weihnachten"
  end
  if md >= 210 and md <= 305 then
    return 1.50, "Winterferien"
  end
  if fromEaster >= -8 and fromEaster <= 2 then
    return 1.50, "Ostern"
  end
  if fromEaster >= 46 and fromEaster <= 52 then
    return 1.35, "Pfingsten"
  end
  if md >= 1010 and md <= 1026 then
    return 1.30, "Herbstferien"
  end
  if md == 501 or md == 1003 or md == 1101 then
    return 1.35, "Feiertag"
  end
  return 1.0, nil
end

local function weekendFactor(wd, hour)
  if wd == 5 and hour >= 14 then
    return 1.40
  end
  if wd == 6 then
    if hour >= 10 and hour < 18 then
      return 1.40
    end
    return 1.25
  end
  if wd == 0 then
    if hour >= 12 and hour < 20 then
      return 1.45
    end
    return 1.15
  end
  return 1.0
end

local function diurnalFactor(hour)
  if hour >= 22 or hour < 6 then
    return 0.32
  end
  if hour < 10 then
    return 0.90
  end
  if hour < 16 then
    return 1.00
  end
  if hour < 19 then
    return 1.15
  end
  return 0.70
end

local function gameClock(session)
  session = session or {}
  session.world = session.world or {}
  local w = session.world
  if not w.calendar_start then
    local started = tostring(session.started_at or "")
    w.calendar_start = started:match("^(%d%d%d%d%-%d%d%-%d%d)") or os.date("!%Y-%m-%d")
  end
  w.game_day = tonumber(w.game_day) or 0
  local tod = readTodFraction()
  if tod == nil then
    tod = 0
  end
  local sy, sm, sd = parseYmd(w.calendar_start)
  local y, mo, d = addDays(sy, sm, sd, w.game_day)
  local hour = todToHour(tod)
  local wd = weekdaySun0(y, mo, d)
  local hol = holidayFactor(y, mo, d)
  local wee = weekendFactor(wd, hour)
  local dia = diurnalFactor(hour)
  return {
    year = y,
    month = mo,
    day = d,
    hour = hour,
    weekday = wd,
    tod = tod,
    game_day = w.game_day,
    holiday = hol,
    weekend = wee,
    diurnal = dia,
  }
end

local function hash01(text, seed, extra)
  local h = 0
  local s = tostring(text or "") .. ":" .. tostring(seed or 0) .. ":" .. tostring(extra or 0)
  for i = 1, #s do
    h = (h * 131 + string.byte(s, i)) % 2147483647
  end
  return (h % 10000) / 10000.0
end

local function playTimeSeed(session)
  local started = tostring((session and session.started_at) or "")
  local y, m, d, H, M = started:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)T(%d%d):(%d%d)")
  if y then
    return tonumber(y .. m .. d .. H .. M)
  end
  return os.time()
end

local function stampWorld(session)
  session = session or {}
  session.world = session.world or {}
  local w = session.world
  w.clock_rate = 24
  w.day_length_s = DAY_LENGTH_S
  if not w.calendar_start then
    local started = tostring(session.started_at or "")
    w.calendar_start = started:match("^(%d%d%d%d%-%d%d%-%d%d)") or os.date("!%Y-%m-%d")
  end
  w.game_day = tonumber(w.game_day) or 0
  return w
end

local function tickGameCalendar(session)
  session = session or {}
  local w = stampWorld(session)
  local tod = readTodFraction()
  if tod == nil then
    return session
  end
  local last = tonumber(w.last_tod)
  local wrap = last ~= nil and tod + 0.35 < last
  if wrap then
    w.game_day = (tonumber(w.game_day) or 0) + 1
  end
  w.last_tod = tod
  if wrap then
    writeSession(session)
    log("I", "alpine_rt", string.format("game day -> %s (tod wrap)", tostring(w.game_day)))
  end
  return session
end

local function ensureSession(session)
  session = session or readSession() or {}
  if not session.session_id then
    session.session_id = tostring(os.time()) .. "-" .. tostring(math.random(10000, 99999))
    session.started_at = os.date("!%Y-%m-%dT%H:%M:%SZ")
    session.segments = session.segments or {}
    session.traffic = session.traffic or { epoch = os.time(), seed = playTimeSeed(session) }
  end
  return session
end

local function ensureTraffic()
  local session = ensureSession()
  if type(session.traffic) ~= "table" then
    session.traffic = { epoch = os.time(), seed = playTimeSeed(session) }
    writeSession(session)
    return session.traffic.epoch, session.traffic.seed, session
  end
  local epoch = tonumber(session.traffic.epoch)
  local seed = tonumber(session.traffic.seed)
  local changed = false
  if not epoch then
    epoch = os.time()
    session.traffic.epoch = epoch
    changed = true
  end
  if not seed then
    seed = playTimeSeed(session)
    session.traffic.seed = seed
    changed = true
  end
  if changed then
    writeSession(session)
  end
  return epoch, seed, session
end

local function segDensity(segId, tSec, seed)
  local h = 0
  local text = tostring(segId or "")
  for i = 1, #text do
    h = (h * 131 + string.byte(text, i)) % 2147483647
  end
  local x = (h + (seed or 0) * 1013) % 2147483647
  local a = (x % 10000) / 10000.0
  local b = ((math.floor(x / 10000) % 10000)) / 10000.0
  local p1 = math.sin((tSec or 0) * (0.0009 + 0.0022 * a) + 6.28318 * b)
  local p2 = math.sin((tSec or 0) * (0.0041 + 0.0011 * b) + 6.28318 * a)
  local v = 0.52 + 0.30 * p1 + 0.18 * p2
  if v < 0 then
    v = 0
  elseif v > 1 then
    v = 1
  end
  return v
end

local function gateById(id)
  if not id then
    return nil
  end
  for _, g in ipairs(portals.gates or {}) do
    if tostring(g.id or "") == tostring(id) then
      return g
    end
  end
  return nil
end

local function classifyWeather(env)
  if type(env) ~= "table" then
    return "sun"
  end
  local snow = tonumber(env.snowCoef or env.snowAmount or env.snow) or 0
  local rain = tonumber(env.precipitationAmount or env.precipitation or env.rainAmount) or 0
  local clouds = tonumber(env.cloudCover) or 0
  if snow > 0.15 then
    return "snow"
  end
  if rain > 0.12 then
    return "rain"
  end
  if clouds > 0.45 then
    return "clouds"
  end
  return "sun"
end

local function classifyTraffic(d)
  d = tonumber(d) or 0
  if d < 0.40 then
    return "clear"
  end
  if d < 0.70 then
    return "medium"
  end
  return "heavy"
end

local function classifyWeatherSim(mapId, tSec, seed)
  local v = segDensity("wx:" .. tostring(mapId), tSec, seed)
  if v > 0.85 then
    return "snow"
  end
  if v > 0.70 then
    return "rain"
  end
  if v > 0.45 then
    return "clouds"
  end
  return "sun"
end

local function testTraffic(levelId)
  return TEST_TRAFFIC[tostring(levelId or "")]
end

local function mapDensity(levelId, clock, seed)
  local fixed = testTraffic(levelId)
  if fixed then
    return fixed.dens
  end
  clock = clock or gameClock()
  local bucket = math.floor((tonumber(clock.hour) or 12) * 4)
  local day = tonumber(clock.game_day) or 0
  local noise = hash01(tostring(levelId or ""), seed, day * 100 + bucket)
  local base = 0.20 + 0.34 * noise
  local bias = 0.85 + 0.30 * hash01("bias:" .. tostring(levelId or ""), seed, 0)
  local v = base * bias * (clock.diurnal or 1) * (clock.weekend or 1) * (clock.holiday or 1)
  if v < 0 then
    v = 0
  elseif v > 1 then
    v = 1
  end
  return v
end

local function dwellBaseS(gate)
  local m = gate and tonumber(gate.center_distance_m)
  if m and m > 0 then
    return m / 1000.0
  end
  return tonumber(gate and gate.dwell_base_s) or tonumber(gate and gate.dwell_s) or 5
end

-- New roll every time the player enters a box. Leave + re-enter is allowed to repeat.
local function rollDwellNeed(gate, clock, seed)
  local base = dwellBaseS(gate)
  local dest = gate and gate.to_level
  local cls = classifyTraffic(mapDensity(dest, clock, seed))
  local u = math.random()
  local need
  if cls == "clear" then
    need = base * (0.75 + 0.50 * u)
  elseif cls == "medium" then
    need = base * (1.00 + 0.50 * u)
  else
    need = base * (1.50 + 0.50 * u)
  end
  if need < 1 then
    need = 1
  end
  return need, cls, base
end

-- Same classes the map icon uses. The icon is a forecast; the level does not carry it.
local FORECAST_SKY = {
  sun = { cloud = 0.08, drops = 0, fog = 0.00002 },
  clouds = { cloud = 0.72, drops = 0, fog = 0.00005 },
  rain = { cloud = 0.92, drops = 2800, fog = 0.00014, block = "rain_drop" },
  snow = { cloud = 0.86, drops = 1600, fog = 0.00020, block = "snow_drop" },
}

local function storedForecast(session, level)
  local rec = session and session.applied_weather
  if type(rec) ~= "table" or not rec.kind then
    return nil
  end
  if level and rec.level and rec.level ~= level then
    return nil
  end
  return rec.kind
end

local function forecastFor(levelId)
  local epoch, seed = ensureTraffic()
  local t = os.time() - (epoch or os.time())
  return classifyWeatherSim(levelId, t, seed)
end

local function ensurePrecip(spec)
  local obj = getObject and getObject("Precipitation") or nil
  if spec.drops <= 0 then
    if obj then
      obj.numOfDrops = 0
    end
    return
  end
  if obj then
    obj.numOfDrops = spec.drops
    if spec.block then
      pcall(function() obj:setField("dataBlock", 0, spec.block) end)
    end
    return
  end
  if not createObject then
    log("W", "alpine_rt", "no Precipitation object; rain and snow stay dry")
    return
  end
  obj = createObject("Precipitation")
  if not obj then
    return
  end
  obj.canSave = false
  local block = spec.block or "rain_drop"
  local function arm(name)
    obj:setField("dataBlock", 0, name)
    obj.numOfDrops = spec.drops
    obj.boxWidth = 220
    obj.dropSize = (name == "snow_drop") and 1.5 or 0.7
    obj.minSpeed = (name == "snow_drop") and 0.4 or 1.2
    obj.maxSpeed = (name == "snow_drop") and 1.0 or 2.2
    obj.followCam = 1
    obj:registerObject("Precipitation")
  end
  local ok = pcall(arm, block)
  if not ok and block ~= "rain_drop" then
    ok = pcall(arm, "rain_drop")
    block = "rain_drop"
  end
  if not ok then
    log("W", "alpine_rt", "Precipitation register failed")
    return
  end
  local grp = scenetree and (scenetree.findObject("sky_and_sun") or scenetree.findObject("MissionGroup"))
  if grp and grp.addObject then
    pcall(function() grp:addObject(obj) end)
  end
  log("I", "alpine_rt", "Precipitation " .. tostring(block) .. " drops " .. tostring(spec.drops))
end

-- Universal Dynamic Weather owns the sky while its panel is loaded. Writing cloud cover
-- through core_environment makes 0.39 put the map default back, and UDW then heals
-- fog and clouds to its own preset every couple of seconds.
local UDW_PRESET = {
  sun = "clear",
  clouds = "overcast",
  rain = "rain",
  snow = "rain",
}

local function dropStrayPrecip()
  local o = scenetree and scenetree.findObject and scenetree.findObject("Precipitation")
  if o and o.delete then
    pcall(function() o:delete() end)
  end
end

local function applyForecast(kind)
  local spec = FORECAST_SKY[kind]
  if not spec then
    return
  end
  local jbw = ensureJbWeather()
  local udwName = UDW_PRESET[kind]
  if jbw and jbw.setPreset and udwName then
    udwResumeLeft = nil
    if jbw.stopForecast then
      pcall(jbw.stopForecast)
    end
    dropStrayPrecip()
    pcall(jbw.setPreset, udwName, 6)
    log("I", "alpine_rt", "forecast weather " .. tostring(kind) .. " via UDW " .. udwName)
    return
  end
  if core_environment then
    pcall(function()
      if core_environment.setCloudCover then
        core_environment.setCloudCover(spec.cloud)
      end
      if core_environment.setFogDensity then
        core_environment.setFogDensity(spec.fog)
      end
      if core_environment.setPrecipitation then
        core_environment.setPrecipitation(spec.drops)
      end
    end)
  end
  local ok, err = pcall(ensurePrecip, spec)
  if not ok then
    log("W", "alpine_rt", "forecast precip " .. tostring(err))
  end
  log("I", "alpine_rt", "forecast weather " .. tostring(kind))
end

local function getTrafficMap()
  local epoch, seed, session = ensureTraffic()
  tickGameCalendar(session)
  local clock = gameClock(session)
  local t = os.time() - (epoch or os.time())
  local level = currentLevel()
  local snap = snapshotEnvironment()
  local env = snap and snap.environment or nil
  local hereWeather = storedForecast(session, level) or classifyWeather(env)
  local roads = {}
  for _, r in ipairs(portals.roads or {}) do
    local a = gateById(r.a)
    local b = gateById(r.b)
    local mark = r.map_mark
    if type(mark) == "table" and type(mark.crs) == "table" and #mark.crs >= 2 then
      local da = a and mapDensity(a.to_level, clock, seed) or nil
      local db = b and mapDensity(b.to_level, clock, seed) or nil
      roads[#roads + 1] = {
        id = tostring(r.id or r.a or ""),
        mark = mark,
        route = type(r.route_crs) == "table" and r.route_crs[1] and r.route_crs or nil,
        a = a and { id = tostring(a.id or r.a), to_level = a.to_level, density = da } or nil,
        b = b and { id = tostring(b.id or r.b), to_level = b.to_level, density = db } or nil,
      }
    end
  end
  local maps = {}
  local levels = (portals.map and portals.map.levels) or {}
  for id, rec in pairs(levels) do
    local dens = mapDensity(id, clock, seed)
    local wx = (id == level) and hereWeather or classifyWeatherSim(id, t, seed)
    maps[#maps + 1] = {
      id = tostring(id),
      crs = rec.crs,
      weather = wx,
      traffic = classifyTraffic(dens),
      density = dens,
      alert = rec.alert == true,
    }
  end
  return {
    product = "Alpine Roadtrip",
    short = "alpine-rt",
    lua_rev = LUA_REV,
    level = level,
    now_s = os.time(),
    t_s = t,
    weather = hereWeather,
    map = portals.map,
    maps = maps,
    roads = roads,
    setup = setupState(),
  }
end

local function queueSwitch(gate)
  local settings = snapshotEnvironment()
  local vehicle = snapshotVehicle()
  local _, _, session = ensureTraffic()
  local wx = forecastFor(gate.to_level)
  session.settings = settings
  session.udw = snapshotUdw()
  stampWorld(session)
  session.vehicle = vehicle
  session.pending_restore = {
    to_level = gate.to_level,
    from_gate = gate.id,
    arrive = gate.arrive,
    weather = wx,
  }
  writeSession(session)
  log("I", "alpine_rt", "Queued switch " .. tostring(gate.from_level) .. " -> " .. tostring(gate.to_level) .. " weather " .. tostring(wx))
  switchQueued = {
    to_level = gate.to_level,
    vehicle = vehicle,
  }
end

local function doQueuedSwitch()
  local q = switchQueued
  switchQueued = nil
  if not q then
    return
  end
  local path = "/levels/" .. q.to_level .. "/main/"
  local spawnArg
  if q.vehicle and q.vehicle.model then
    spawnArg = { q.vehicle.model, { config = q.vehicle.config } }
  end
  log("I", "alpine_rt", "startLevel " .. path)
  -- next frame / after JSON flush; not from a trigger callback
  if core_levels and core_levels.startLevel then
    core_levels.startLevel(path, false, nil, spawnArg)
  else
    log("E", "alpine_rt", "core_levels.startLevel missing")
  end
end

local function applyPendingRestore()
  local session = readSession()
  if not session or not session.pending_restore then
    if isAlpineRoadtripLevel() then
      applyClock(session and session.settings and session.settings.environment)
      local kind = storedForecast(session, currentLevel())
      if kind then
        applyForecast(kind)
      else
        applyUdw(session and session.udw)
      end
    end
    restoreArmed = false
    restoreTries = 0
    return true
  end
  if not playerVehicle() then
    restoreTries = restoreTries + 1
    return false
  end
  local pending = session.pending_restore
  local level = currentLevel()
  if pending.to_level and level and pending.to_level ~= level then
    log("W", "alpine_rt", "pending_restore for " .. tostring(pending.to_level) .. " but on " .. tostring(level))
    restoreArmed = false
    return true
  end
  applyClock(session.settings and session.settings.environment)
  if session.vehicle and session.vehicle.model then
    local veh = playerVehicle()
    local needReplace = true
    if veh and veh.jbeam == session.vehicle.model then
      needReplace = false
    end
    if needReplace and core_vehicles and core_vehicles.replaceVehicle then
      core_vehicles.replaceVehicle(session.vehicle.model, { config = session.vehicle.config })
    end
  end
  teleportToArrive(pending.arrive)
  if pending.weather then
    applyForecast(pending.weather)
    session.applied_weather = { level = pending.to_level or level, kind = pending.weather }
  else
    applyUdw(session.udw)
  end
  session.pending_restore = nil
  writeSession(session)
  local grace = tonumber(portals.grace_s) or 8
  graceUntil = now() + grace
  dwellGate = nil
  dwellAcc = 0
  dwellNeed = 0
  restoreArmed = false
  restoreTries = 0
  uiMsg("Alpine Roadtrip: map loaded", 3)
  log("I", "alpine_rt", "Restore done, grace " .. tostring(grace) .. "s")
  return true
end

local function col3(mat, i)
  local c = mat:getColumn(i)
  return vec3(c.x, c.y, c.z)
end

local function collectFanRotors()
  fanRotors = {}
  fanAngle = 0
  if not scenetree or not scenetree.findClassObjects then
    return
  end
  local names = scenetree.findClassObjects("TSStatic") or {}
  for _, name in ipairs(names) do
    if type(name) == "string" and name:find("__fanrotor_", 1, true) then
      local obj = scenetree.findObject(name)
      if obj and obj.getTransform then
        local t = obj:getTransform()
        local shape = tostring(obj.shapeName or obj:getField("shapeName", 0) or "")
        local dir = 1
        if shape:find("ccw", 1, true) then
          dir = -1
        end
        fanRotors[#fanRotors + 1] = {
          id = obj:getId(),
          pos = obj:getPosition(),
          x = col3(t, 0),
          y = col3(t, 1),
          z = col3(t, 2),
          dir = dir,
        }
      end
    end
  end
  log("I", "alpine_rt", "fan rotors " .. tostring(#fanRotors) .. " @ " .. tostring(FAN_RPM) .. " rpm")
end

local function tickFanRotors(dt)
  if FAN_RPM == 0 then
    return
  end
  if fanRotors == nil then
    collectFanRotors()
  end
  if not fanRotors or #fanRotors == 0 then
    return
  end
  fanAngle = fanAngle + (dt or 0) * FAN_RAD_PER_S
  local c = math.cos(fanAngle)
  local s = math.sin(fanAngle)
  for i = 1, #fanRotors do
    local f = fanRotors[i]
    local obj = scenetree.findObjectById and scenetree.findObjectById(f.id)
    if obj and obj.setTransform then
      local sd = s * f.dir
      local y2 = f.y * c + f.z * sd
      local z2 = f.z * c - f.y * sd
      local mat = MatrixF(true)
      mat:setColumn(0, f.x)
      mat:setColumn(1, y2)
      mat:setColumn(2, z2)
      mat:setColumn(3, f.pos)
      obj:setTransform(mat)
    end
  end
end

local function onExtensionLoaded()
  loadPortals()
  math.randomseed(os.time())
  hideAllArcs()
  ensureJbWeather()
  log("I", "alpine_rt", "extension loaded " .. LUA_REV)
  uiMsg("Alpine Roadtrip Lua " .. LUA_REV, 4)
end

local function onWorldReadyState(state)
  worldReady = (state == 2)
  if state == 2 then
    loadPortals()
    hideAllArcs()
    fanRotors = nil
    restoreArmed = true
    restoreTries = 0
  end
end

local function onClientEndMission()
  local session = readSession()
  if session then
    session.settings = snapshotEnvironment()
    session.udw = snapshotUdw()
    stampWorld(session)
    writeSession(session)
  end
  worldReady = false
  dwellGate = nil
  dwellAcc = 0
  dwellNeed = 0
  udwResumeLeft = nil
  trafficSpawnedFor = nil
  trafficWait = 0
  fanRotors = nil
  hideAllArcs()
end

local function navgraphReady()
  -- map.nodes is not the road graph. The graph lives behind map.getMap().
  if not (map and map.getMap) then
    return false
  end
  local graph = map.getMap()
  if not (graph and graph.nodes) then
    return false
  end
  local n = 0
  for _ in pairs(graph.nodes) do
    n = n + 1
    if n >= 4 then
      return true
    end
  end
  return false
end

local function ensureTestTraffic(level)
  if trafficSpawnedFor == level or not playerVehicle() then
    return
  end
  local spec = testTraffic(level)
  if not spec then
    return
  end
  if not navgraphReady() then
    trafficWait = trafficWait + 1
    if trafficWait == 300 then
      log("W", "alpine_rt", "navgraph still empty, traffic not spawned")
    end
    return
  end
  if not (gameplay_traffic and gameplay_traffic.setupTraffic) and extensions and extensions.load then
    pcall(extensions.load, "gameplay_traffic")
  end
  if not (gameplay_traffic and gameplay_traffic.setupTraffic) then
    trafficSpawnedFor = level
    log("W", "alpine_rt", "gameplay_traffic missing")
    return
  end
  trafficSpawnedFor = level
  local ok, err = pcall(function()
    gameplay_traffic.setupTraffic(spec.cars, { activeAmount = spec.active or spec.cars })
  end)
  if ok then
    log("I", "alpine_rt", "test traffic " .. tostring(level) .. " cars=" .. tostring(spec.cars) .. " active=" .. tostring(spec.active or spec.cars))
    uiMsg("Traffic " .. tostring(spec.cars), 4)
  else
    log("W", "alpine_rt", "test traffic failed " .. tostring(err))
  end
end

local function onUpdate(dtReal, dtSim)
  if switchQueued then
    doQueuedSwitch()
    return
  end
  if restoreArmed then
    hideAllArcs()
    if applyPendingRestore() or restoreTries > 180 then
      if restoreTries > 180 then
        log("W", "alpine_rt", "Restore timed out waiting for player vehicle")
      end
      restoreArmed = false
    end
    return
  end
  if not worldReady then
    return
  end
  tickFanRotors(dtReal)
  tickUdwResume(dtReal)
  local level = currentLevel()
  if not level then
    return
  end
  ensureTestTraffic(level)
  pcall(drawUserPortals, level)
  if graceUntil > now() then
    hideAllArcs()
    return
  end
  local veh = playerVehicle()
  if not veh then
    dwellGate = nil
    dwellAcc = 0
    dwellNeed = 0
    hideAllArcs()
    return
  end

  local inside = nil
  for _, g in ipairs(gatesForLevel(level)) do
    if playerInGate(g) then
      inside = g
      break
    end
  end

  if not inside then
    if dwellGate then
      uiMsg("Left portal", 1)
    end
    hideAllArcs()
    dwellGate = nil
    dwellAcc = 0
    dwellNeed = 0
    lastMsgS = -1
    dwellMsgHold = 0
    return
  end

  if inside.user then
    ensureUserArc(inside)
  end

  if not dwellGate or dwellGate.id ~= inside.id then
    dwellGate = inside
    dwellAcc = 0
    lastMsgS = -1
    dwellMsgHold = 0
    local _, seed, session = ensureTraffic()
    tickGameCalendar(session)
    local clock = gameClock(session)
    local cls, base
    dwellNeed, cls, base = rollDwellNeed(inside, clock, seed)
    log("I", "alpine_rt", string.format(
      "enter %s need=%.1fs base=%.1fs traffic=%s dest=%s rev=%s",
      tostring(inside.id),
      dwellNeed,
      base,
      tostring(cls),
      tostring(inside.to_level),
      LUA_REV
    ))
  end
  if inside.user then
    drawGateArc(inside)
  else
    ensureLiveArc(inside)
    drawGateArc(inside)
  end

  -- dtSim is 0 while physics is paused, and follows slow motion. dtReal keeps running.
  local simDt = dtSim
  if simDt == nil then
    simDt = dtReal or 0
  end
  local paused = simDt < 0.00001
  if paused then
    dwellMsgHold = dwellMsgHold - (dtReal or 0)
  else
    dwellAcc = dwellAcc + simDt
    dwellMsgHold = 0
  end
  local need = dwellNeed
  if need <= 0 then
    need = dwellBaseS(inside)
  end
  local remain = math.max(0, need - dwellAcc)
  local sec = math.ceil(remain)
  if sec ~= lastMsgS or (paused and dwellMsgHold <= 0 and remain > 0.05) then
    if paused then
      dwellMsgHold = 0.4
    end
    lastMsgS = sec
    local label = inside.label or inside.id
    if remain > 0.05 then
      uiMsg(string.format("%s — switching in %ds", label, sec), paused and 0.5 or 1.05)
    end
  end

  if dwellAcc >= need then
    dwellGate = nil
    dwellAcc = 0
    dwellNeed = 0
    hideAllArcs()
    uiMsg((inside.label or "Portal") .. " — loading map", 2)
    queueSwitch(inside)
  end
end

local function onSerialize()
  return {
    dwellAcc = dwellAcc,
    dwellNeed = dwellNeed,
    dwellId = dwellGate and dwellGate.id or nil,
    graceUntil = graceUntil,
  }
end

local function onDeserialized(data)
  loadPortals()
  hideAllArcs()
  if type(data) == "table" then
    dwellAcc = data.dwellAcc or 0
    dwellNeed = data.dwellNeed or 0
    graceUntil = data.graceUntil or 0
  end
end

M.onExtensionLoaded = onExtensionLoaded
M.onWorldReadyState = onWorldReadyState
M.onClientEndMission = onClientEndMission
M.onUpdate = onUpdate
M.onSerialize = onSerialize
M.onDeserialized = onDeserialized

M.getTrafficMap = getTrafficMap
M.defineLocation = defineLocation
M.placePortal = placePortal
M.placeReturn = placeReturn
M.listLevels = listLevels

return M
