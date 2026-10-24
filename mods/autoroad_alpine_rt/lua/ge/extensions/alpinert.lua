-- Alpine Roadtrip: dwell portals + session persist across core_levels.startLevel.
-- Load via scripts/modScript.lua (manual unload). Do not put this in mainLevel.lua.
-- Internal extension id is "alpinert" (no underscore: BeamNG maps foo_bar to foo/bar.lua).

local M = {}

local SESSION_PATH = "settings/alpine_rt/session.json"
local GRAPH_PATH = "settings/alpine_rt/graph.json"
local REGION_DIR = "settings/alpine_rt/regions"
local PORTALS_PATH = "/lua/ge/extensions/alpinert/portals.json"
-- Bump this when Lua changes; shown on load so a stale in-memory copy is obvious.
local LUA_REV = "2026-10-24s"
-- Label used only when no TimeOfDay exists yet. 3600 s is 24× (one real hour, one game day).
-- 0.40's live cycle is time / play / dayLength. Do not force this over Freeroam or a level.
local DAY_LENGTH_S = 3600

local portals = { grace_s = 8, gates = {} }
local userLocations = {}
local userLinks = {}
local mergeUserGraph
local dwellGate = nil
local dwellAcc = 0
local dwellNeed = 0
local lastMsgS = -1
local dwellMsgHold = 0
local graceUntil = 0
local freshPortal = { id = nil, untilT = 0 }
local switchQueued = nil
local carry = { conditions = nil, ready = false, token = 0, requested = 0, hold = nil, damage = nil, damageTries = 0 }
local worldReady = false
local restoreArmed = false
local restoreTries = 0
local udwResumeLeft = nil
local trafficSpawnedFor = nil
local waterStageFor = nil
local waterStageLevel = nil
local waterStageMonth = nil
local waterFileLevel = nil
local waterFileData = nil
-- Discoverable portals found this process. Not written to the session file.
local discoveredPortals = {}
local discoverNoticeUntil = 0
local trafficWait = 0
-- Temporary test. Kauns is the Reschen level. Densities also drive the map colours and the portal wait.
local TEST_TRAFFIC = {
  -- cars = pool. active = how many of those run physics at once (BeamNG slider tops out at 15).
  autoroad_fernpass_8192 = { dens = 0.90, cars = 15, active = 15 },
  imst_tarrenz = { dens = 0.22, cars = 3 },
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

-- BeamNG's level identifier is often the folder name in lower case
-- (timmelsjoch_2048). portals.json and saved gates keep the folder spelling.
local function canonicalLevel(id)
  if type(id) ~= "string" or id == "" then
    return nil
  end
  local levels = portals.map and portals.map.levels
  if levels and levels[id] then
    return id
  end
  if userLocations[id] then
    return id
  end
  local lower = id:lower()
  if levels then
    for key in pairs(levels) do
      if type(key) == "string" and key:lower() == lower then
        return key
      end
    end
  end
  for key in pairs(userLocations) do
    if type(key) == "string" and key:lower() == lower then
      return key
    end
  end
  for _, g in ipairs(portals.gates or {}) do
    if type(g.from_level) == "string" and g.from_level:lower() == lower then
      return g.from_level
    end
    if type(g.to_level) == "string" and g.to_level:lower() == lower then
      return g.to_level
    end
  end
  return id
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
  return canonicalLevel(id)
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

-- EPSG:3857 spherical mercator. Matches OSM and basemap.at google3857 tiles.
local MERCATOR_R = 6378137.0

local function wgs84ToWebMercator(latDeg, lonDeg)
  local lat = math.max(-85.05112878, math.min(85.05112878, latDeg))
  local x = MERCATOR_R * math.rad(lonDeg)
  local y = MERCATOR_R * math.log(math.tan(math.pi * 0.25 + math.rad(lat) * 0.5))
  return x, y
end

-- Web mercator metres are stretched by 1/cos(lat). This brings a northing back to ground scale.
local function webMercatorGroundScale(northing)
  local lat = 2 * math.atan(math.exp(northing / MERCATOR_R)) - math.pi * 0.5
  local c = math.cos(lat)
  if c < 0.05 then
    c = 0.05
  end
  return c
end

local function projectToAuthority(lat, lon, authority)
  if authority == "EPSG:3857" then
    local e, n = wgs84ToWebMercator(lat, lon)
    return e, n, nil
  end
  if authority == "EPSG:31254" then
    local e, n = wgs84ToGkWest(lat, lon)
    return e, n, nil
  end
  return nil, nil, "Map CRS authority " .. tostring(authority) .. " is not supported. This map was not added."
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
    return { locations = {}, gates = {}, view = {}, links = {}, moves = {} }
  end
  if type(data.locations) ~= "table" then
    data.locations = {}
  end
  if type(data.gates) ~= "table" then
    data.gates = {}
  end
  if type(data.view) ~= "table" then
    data.view = {}
  end
  if type(data.links) ~= "table" then
    data.links = {}
  end
  if type(data.moves) ~= "table" then
    data.moves = {}
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

local titles = { cache = {} }

local function levelTitle(id)
  id = tostring(id or "")
  if id == "" then
    return ""
  end
  if titles.cache[id] then
    return titles.cache[id]
  end
  local function usable(text)
    return type(text) == "string" and text ~= "" and not text:find("levels%.", 1, true) and not text:find("{{", 1, true)
  end
  local function remember(text)
    titles.cache[id] = text
    return text
  end
  local function fromPacks(key)
    if not titles.packs then
      local loaded = {}
      local lang = "en-US"
      if core_locales and core_locales.getLanguage then
        local ok, value = pcall(core_locales.getLanguage)
        if ok and type(value) == "string" and value ~= "" then
          lang = value
        end
      end
      local function load(code)
        local data = jsonReadFile("/locales/translations/" .. code .. "/main.translation.json")
        if type(data) == "table" then
          loaded[#loaded + 1] = data
        end
      end
      load(lang)
      if lang ~= "en-US" then
        load("en-US")
      end
      if loaded[1] then
        titles.packs = loaded
      end
    end
    for _, data in ipairs(titles.packs or {}) do
      if usable(data[key]) then
        return data[key]
      end
    end
    return nil
  end
  local info = jsonReadFile("/levels/" .. id .. "/info.json")
  local raw = type(info) == "table" and type(info.title) == "string" and info.title or ""
  local key = (raw:find("^levels%.", 1) and raw) or ("levels." .. id .. ".info.title")
  local fromFile = fromPacks(key)
  if fromFile then
    return remember(fromFile)
  end
  if core_locales and core_locales.translate then
    local text = core_locales.translate(key)
    if usable(text) and text ~= key then
      return remember(text)
    end
  end
  if usable(raw) then
    return remember(raw)
  end
  local short = id:gsub("^autoroad_", ""):gsub("_%d+$", ""):gsub("_", " ")
  if short == "" then
    return id
  end
  return short:sub(1, 1):upper() .. short:sub(2)
end

local function destName(gate)
  local id = gate and gate.to_level
  if not id then
    return "the next map"
  end
  local title = levelTitle(id)
  if type(title) == "string" and title ~= "" and not title:find("^autoroad_") then
    return title
  end
  local short = tostring(id):gsub("^autoroad_", ""):gsub("_%d+$", "")
  if short == "" then
    return tostring(id)
  end
  return short:sub(1, 1):upper() .. short:sub(2)
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
  if loc and type(loc.crs) == "table" and loc.crs[1] and loc.crs[2] then
    rec.crs = { loc.crs[1], loc.crs[2] }
  end
  rec.title = levelTitle(levelId)
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
      local lo, hi = g.from_level, g.to_level
      if lo > hi then
        lo, hi = hi, lo
      end
      local e1, n1 = centerOf(lo)
      local e2, n2 = centerOf(hi)
      if e1 and e2 then
        local route = { { e1, n1 } }
        for _, link in ipairs(userLinks) do
          if link.a == lo and link.b == hi and type(link.via) == "table" then
            for _, p in ipairs(link.via) do
              if type(p) == "table" and tonumber(p[1]) and tonumber(p[2]) then
                route[#route + 1] = { tonumber(p[1]), tonumber(p[2]) }
              end
            end
            break
          end
        end
        route[#route + 1] = { e2, n2 }
        portals.roads[#portals.roads + 1] = {
          id = "user:" .. tostring(g.id),
          a = g.id,
          b = rev and rev.id or nil,
          user = true,
          ends = { lo, hi },
          map_mark = {
            crs = { (e1 + e2) * 0.5, (n1 + n2) * 0.5 },
            heading = { e2 - e1, n2 - n1 },
            length_px = 28,
            gap_px = 7,
          },
          route_crs = route,
        }
      end
    end
  end
end

local function applyGateMoves(moves)
  if type(moves) ~= "table" then
    return
  end
  for id, move in pairs(moves) do
    if type(id) == "string" and type(move) == "table" then
      for _, g in ipairs(portals.gates or {}) do
        if g.id == id then
          if type(move.pos) == "table" and move.pos[1] then
            local old = g.box and g.box.pos
            local size = (g.box and g.box.size) or { BOX_SIZE[1], BOX_SIZE[2], BOX_SIZE[3] }
            if type(old) == "table" and old[1] then
              g.moveDelta = {
                move.pos[1] - old[1],
                move.pos[2] - old[2],
                move.pos[3] - (old[3] or move.pos[3]),
              }
            end
            g.box = {
              pos = { move.pos[1], move.pos[2], move.pos[3] },
              tangent = type(move.tangent) == "table" and move.tangent or (g.box and g.box.tangent) or { 1, 0 },
              size = size,
            }
            g.moved = true
          end
          if type(move.arrive) == "table" and type(move.arrive.pos) == "table" then
            g.arrive = move.arrive
          end
          break
        end
      end
    end
  end
end

mergeUserGraph = function()
  local graph = readGraph()
  userLocations = graph.locations
  userLinks = {}
  for _, link in ipairs(graph.links or {}) do
    if type(link) == "table" and link.a and link.b and type(link.via) == "table" then
      userLinks[#userLinks + 1] = link
    end
  end
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
  applyGateMoves(graph.moves)
end

local function groundStep(e0, n0, e1, n1, nx, ny)
  local ex, ey = ny, -nx
  local east_m = e1 - e0
  local north_m = n1 - n0
  if mapAuthority() == "EPSG:3857" then
    local scale = webMercatorGroundScale((n0 + n1) * 0.5)
    east_m = east_m * scale
    north_m = north_m * scale
  end
  local dx = east_m * ex + north_m * nx
  local dy = east_m * ey + north_m * ny
  return dx, dy, math.sqrt(dx * dx + dy * dy)
end

-- Via points stored from the lexicographically first level toward the second.
local function linkRecord(lo, hi)
  for _, link in ipairs(userLinks) do
    if type(link) == "table" and link.a == lo and link.b == hi and type(link.via) == "table" then
      return link
    end
  end
  return nil
end

local function reversePts(pts)
  local rev = {}
  for i = #pts, 1, -1 do
    rev[#rev + 1] = pts[i]
  end
  return rev
end

local function copyMercator(pts)
  local out = {}
  for _, p in ipairs(pts or {}) do
    if type(p) == "table" and tonumber(p[1]) and tonumber(p[2]) then
      out[#out + 1] = { tonumber(p[1]), tonumber(p[2]) }
    end
  end
  return out
end

-- Travel order follows the gate.
local function linkViaOrdered(fromLevel, toLevel)
  local lo, hi = fromLevel, toLevel
  local flip = false
  if lo > hi then
    lo, hi = hi, lo
    flip = true
  end
  local via
  for _, link in ipairs(userLinks) do
    if link.a == lo and link.b == hi and type(link.via) == "table" then
      via = link.via
      break
    end
  end
  local pts = {}
  if via then
    for _, p in ipairs(via) do
      if type(p) == "table" and tonumber(p[1]) and tonumber(p[2]) then
        pts[#pts + 1] = { tonumber(p[1]), tonumber(p[2]) }
      end
    end
  end
  if flip then
    local rev = {}
    for i = #pts, 1, -1 do
      rev[#rev + 1] = pts[i]
    end
    pts = rev
  end
  return pts
end

local function ensureUserArc(gate)
  if not gate or not gate.user or not gate.box or not gate.box.pos then
    return
  end
  local pos = gate.box.pos
  local e1, n1 = centerOf(gate.from_level)
  local e2, n2 = centerOf(gate.to_level)
  local nx, ny = northOf(gate.from_level)
  local corners
  local length_m
  local crs = nil
  if e1 and e2 and nx then
    nx, ny = norm2(nx, ny)
    local _, _, straight_m = groundStep(e1, n1, e2, n2, nx, ny)
    if straight_m >= 50 then
      gate.center_distance_m = straight_m
    end
    if not crs or #crs < 2 then
      crs = { { e1, n1 } }
      for _, p in ipairs(linkViaOrdered(gate.from_level, gate.to_level)) do
        crs[#crs + 1] = p
      end
      crs[#crs + 1] = { e2, n2 }
    end
    corners = { { pos[1], pos[2] } }
    local x, y = pos[1], pos[2]
    local pe, pn = crs[1][1], crs[1][2]
    length_m = 0
    for i = 2, #crs do
      local dx, dy, seg = groundStep(pe, pn, crs[i][1], crs[i][2], nx, ny)
      if seg >= 1 then
        x = x + dx
        y = y + dy
        corners[#corners + 1] = { x, y }
        length_m = length_m + seg
      end
      pe, pn = crs[i][1], crs[i][2]
    end
    if length_m < 50 or #corners < 2 then
      corners = nil
      length_m = nil
    end
  end
  if not corners then
    local tx, ty = norm2((gate.box.tangent or { 1, 0 })[1] or 1, (gate.box.tangent or { 1, 0 })[2] or 0)
    length_m = 800
    corners = {
      { pos[1], pos[2] },
      { pos[1] + tx * length_m, pos[2] + ty * length_m },
    }
  end
  -- One hump over the drawn path. The crest is halfway along that line.
  local peak = math.min(250, math.max(40, length_m * 0.04))
  local pts = {}
  local function emit(x, y, dist)
    local u = dist / math.max(length_m, 1)
    if u < 0 then
      u = 0
    elseif u > 1 then
      u = 1
    end
    pts[#pts + 1] = { x, y, pos[3] + 4.5 + 4 * peak * u * (1 - u) }
  end
  emit(corners[1][1], corners[1][2], 0)
  local travelled = 0
  for i = 1, #corners - 1 do
    local ax, ay = corners[i][1], corners[i][2]
    local bx, by = corners[i + 1][1], corners[i + 1][2]
    local sx, sy = bx - ax, by - ay
    local seg = math.sqrt(sx * sx + sy * sy)
    if seg >= 1 then
      local pieces = math.floor(seg / math.max(400, length_m / 32))
      if pieces < 1 then
        pieces = 1
      elseif pieces > 12 then
        pieces = 12
      end
      for s = 1, pieces do
        if #pts >= 96 then
          break
        end
        local t = s / pieces
        emit(ax + sx * t, ay + sy * t, travelled + seg * t)
      end
      travelled = travelled + seg
    end
  end
  local endc = corners[#corners]
  local last = pts[#pts]
  if not last or (last[1] - endc[1]) ^ 2 + (last[2] - endc[2]) ^ 2 > 4 then
    emit(endc[1], endc[2], length_m)
  end
  local dx, dy = endc[1] - pos[1], endc[2] - pos[2]
  local chord = math.sqrt(dx * dx + dy * dy)
  local inv = 1 / math.max(chord, 1)
  gate.arc = {
    points = pts,
    width_m = 15,
    length_m = length_m,
    peak_m = peak,
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
      local hz = (s[3] or 6) * 0.5
      local function corner(sa, sb, sz)
        return vec3(c[1] + fx * hx * sa + rx * hy * sb, c[2] + fy * hx * sa + ry * hy * sb, z + hz * sz)
      end
      local a, b, d, e = corner(1, 1, -1), corner(1, -1, -1), corner(-1, -1, -1), corner(-1, 1, -1)
      local a2, b2, d2, e2 = corner(1, 1, 1), corner(1, -1, 1), corner(-1, -1, 1), corner(-1, 1, 1)
      pcall(function()
        debugDrawer:drawLine(a, b, col)
        debugDrawer:drawLine(b, d, col)
        debugDrawer:drawLine(d, e, col)
        debugDrawer:drawLine(e, a, col)
        debugDrawer:drawLine(a2, b2, col)
        debugDrawer:drawLine(b2, d2, col)
        debugDrawer:drawLine(d2, e2, col)
        debugDrawer:drawLine(e2, a2, col)
        debugDrawer:drawLine(a, a2, col)
        debugDrawer:drawLine(b, b2, col)
        debugDrawer:drawLine(d, d2, col)
        debugDrawer:drawLine(e, e2, col)
      end)
    end
  end
end

-- Same translucent cube as a built-in gate. Not written into the level file.
local USER_BOX_SHAPE = "/art/shapes/portals/portal_cube.dae"
local userBoxIds = {}
local userBoxErr = nil

local function userBoxName(gateId)
  return "alpine_rt_ubox_" .. tostring(gateId)
end

local function deleteNamed(name, id)
  local obj
  if id and scenetree and scenetree.findObjectById then
    obj = scenetree.findObjectById(id)
  end
  if not obj and name and scenetree and scenetree.findObject then
    obj = scenetree.findObject(name)
  end
  if obj and obj.delete then
    pcall(function()
      obj:delete()
    end)
  end
end

local function orientUserBox(obj, gate)
  local pos = gate.box.pos
  local tangent = gate.box.tangent or { 1, 0 }
  local size = gate.box.size or BOX_SIZE
  local xx, xy = norm2(tangent[1] or 1, tangent[2] or 0)
  local yx, yy = -xy, xx
  local mat = MatrixF(true)
  mat:setColumn(0, vec3(xx, xy, 0))
  mat:setColumn(1, vec3(yx, yy, 0))
  mat:setColumn(2, vec3(0, 0, 1))
  mat:setColumn(3, vec3(pos[1], pos[2], pos[3]))
  obj:setTransform(mat)
  obj.scale = vec3(size[1] or BOX_SIZE[1], size[2] or BOX_SIZE[2], size[3] or BOX_SIZE[3])
end

local function userBoxShape(level)
  local function exists(path)
    return FS and FS.fileExists and FS:fileExists(path)
  end
  if level then
    local path = "/levels/" .. level .. "/art/shapes/portals/portal_cube.dae"
    if exists(path) then
      return path
    end
    local lower = "/levels/" .. tostring(level):lower() .. "/art/shapes/portals/portal_cube.dae"
    if lower ~= path and exists(lower) then
      return lower
    end
  end
  return USER_BOX_SHAPE
end

local function spawnUserBox(gate)
  if not createObject or not gate or not gate.id or not gate.box or not gate.box.pos then
    return false
  end
  local name = userBoxName(gate.id)
  local shape = userBoxShape(gate.from_level)
  local existing = scenetree and scenetree.findObject and scenetree.findObject(name)
  if existing then
    local have = ""
    pcall(function()
      have = tostring(existing:getField("shapeName", 0) or "")
    end)
    if have ~= shape then
      deleteNamed(name, existing:getId())
      existing = nil
    end
  end
  if existing then
    pcall(orientUserBox, existing, gate)
    existing.hidden = false
    existing.isRenderEnabled = true
    existing.useInstanceRenderData = false
    userBoxIds[name] = existing:getId()
    return true
  end
  local obj = createObject("TSStatic")
  if not obj then
    log("E", "alpine_rt", "user box create failed")
    return false
  end
  obj.canSave = false
  obj:setField("shapeName", 0, shape)
  obj.shapeName = shape
  obj:setField("collisionType", 0, "None")
  obj:setField("decalType", 0, "None")
  obj:setField("castShadows", 0, "0")
  obj:setField("useInstanceRenderData", 0, "0")
  obj.useInstanceRenderData = false
  obj.hidden = false
  obj.isRenderEnabled = true
  local pos = gate.box.pos
  obj:setPosition(vec3(pos[1], pos[2], pos[3]))
  local size = gate.box.size or BOX_SIZE
  obj.scale = vec3(size[1] or BOX_SIZE[1], size[2] or BOX_SIZE[2], size[3] or BOX_SIZE[3])
  obj:registerObject(name)
  local grp = scenetree.findObject and (
    scenetree.findObject("alpine_rt_portals") or scenetree.findObject("MissionGroup")
  )
  if grp and grp.addObject then
    pcall(function()
      grp:addObject(obj)
    end)
  end
  pcall(orientUserBox, obj, gate)
  obj.canSave = false
  userBoxIds[name] = obj:getId()
  log("I", "alpine_rt", "user box " .. name .. " " .. shape)
  return true
end

local arcHomePos = {}

local function placeMovedBoxes(level)
  if type(level) ~= "string" or level == "" or level:find("/", 1, true) or level:find("\\", 1, true) then
    level = currentLevel()
  end
  if not level and getMissionFilename then
    local raw = tostring(getMissionFilename()):gsub("\\", "/")
    level = canonicalLevel(raw:match("levels/([^/]+)/"))
  end
  if not level or not scenetree or not scenetree.findObject then
    return
  end
  if not arcHomePos.asphaltNear then
    arcHomePos.asphaltNear = function(gateBox)
      local bx, by, bz = gateBox.pos[1], gateBox.pos[2], gateBox.pos[3]
      local bestSq, rx, ry, rz, rdx, rdy
      if not scenetree.findClassObjects then
        return nil
      end
      for _, name in ipairs(scenetree.findClassObjects("DecalRoad")) do
        if type(name) == "string" and name:sub(1, 6) == "decal_" then
          local road = scenetree.findObject(name)
          local drive = road and tonumber(road.drivability) or 0
          if road and drive > 0 and road.getNodeCount and road.getNodePosition then
            local count = road:getNodeCount()
            local prev = nil
            for i = 0, count - 1 do
              local p = vec3(road:getNodePosition(i))
              if prev then
                local vx, vy = p.x - prev.x, p.y - prev.y
                local len2 = vx * vx + vy * vy
                local t = 0
                if len2 > 1e-4 then
                  t = ((bx - prev.x) * vx + (by - prev.y) * vy) / len2
                  if t < 0 then
                    t = 0
                  elseif t > 1 then
                    t = 1
                  end
                end
                local x = prev.x + vx * t
                local y = prev.y + vy * t
                local z = prev.z + (p.z - prev.z) * t
                local ddx, ddy, ddz = x - bx, y - by, z - bz
                local sq = ddx * ddx + ddy * ddy + ddz * ddz
                if sq < 60 * 60 and (not bestSq or sq < bestSq) then
                  bestSq, rx, ry, rz, rdx, rdy = sq, x, y, z, vx, vy
                end
              end
              prev = p
            end
          end
        end
      end
      if not bestSq then
        return nil
      end
      local fx, fy = rdx, rdy
      local nlen = math.sqrt(fx * fx + fy * fy)
      if nlen < 1e-4 then
        fx, fy = 0, 1
      else
        fx, fy = fx / nlen, fy / nlen
      end
      if fx * (rx - bx) + fy * (ry - by) < 0 then
        fx, fy = -fx, -fy
      end
      if pointInBox(rx, ry, rz, gateBox) then
        local half = gateBox.size and gateBox.size[1] and gateBox.size[1] * 0.5 or 6
        local step = half + 4
        local ax, ay = rx + fx * step, ry + fy * step
        if pointInBox(ax, ay, rz, gateBox) then
          rx, ry = rx - fx * step, ry - fy * step
          fx, fy = -fx, -fy
        else
          rx, ry = ax, ay
        end
      end
      log("I", "alpine_rt", string.format(
        "Arrive on asphalt %.1f %.1f %.1f, %.0f m from the gate",
        rx, ry, rz, math.sqrt(bestSq)))
      -- teleportToArrive and the level spawn both turn this heading 180°.
      return { pos = { rx, ry, rz }, tangent = { -fx, -fy } }
    end
  end
  local function poseAt(obj, pos, tangent)
    local tx, ty = norm2(tangent and tangent[1] or 1, tangent and tangent[2] or 0)
    local mat = MatrixF(true)
    mat:setColumn(0, vec3(tx, ty, 0))
    mat:setColumn(1, vec3(-ty, tx, 0))
    mat:setColumn(2, vec3(0, 0, 1))
    mat:setColumn(3, vec3(pos[1], pos[2], pos[3]))
    obj:setTransform(mat)
  end
  for _, g in ipairs(portals.gates or {}) do
    if g.moved and canonicalLevel(g.from_level) == level and g.box and g.box.pos then
      local obj = scenetree.findObject("alpine_rt_box_" .. tostring(g.id))
      if obj then
        pcall(orientUserBox, obj, g)
        obj.isRenderEnabled = true
        obj.hidden = false
      end
      local delta = g.moveDelta
      local arc = delta and scenetree.findObject("alpine_rt_arc_" .. tostring(g.id))
      if arc and arc.getPosition and arc.setPosition then
        local home = arcHomePos[g.id]
        if not home then
          local p = arc:getPosition()
          home = { p.x, p.y, p.z }
          arcHomePos[g.id] = home
        end
        arc:setPosition(vec3(home[1] + delta[1], home[2] + delta[2], home[3] + delta[3]))
      end
    end
  end
  -- Once per load, before BeamNG spawns the player: the baked SpawnSphere is still
  -- the old arrival. Move it onto the live gate so the level spawn and the later
  -- reapply are the same place.
  if arcHomePos.arriveLevel ~= level then
    arcHomePos.arriveLevel = level
    for _, g in ipairs(portals.gates or {}) do
      if g.arrive and type(g.arrive.pos) == "table" and canonicalLevel(g.to_level) == level then
        local sphere = scenetree.findObject("alpine_rt_arrive_" .. tostring(g.id))
        local home = nil
        if sphere then
          for _, other in ipairs(portals.gates or {}) do
            if other.box and other.box.pos
              and canonicalLevel(other.from_level) == level
              and canonicalLevel(other.to_level) == canonicalLevel(g.from_level) then
              home = other
              break
            end
          end
        end
        local pose = nil
        if home then
          local okPose, got = pcall(arcHomePos.asphaltNear, home.box)
          if okPose then
            pose = got
          end
        end
        if sphere and not pose then
          pose = { pos = g.arrive.pos, tangent = g.arrive.tangent }
        end
        if sphere and pose and pose.pos then
          pose = {
            pos = { pose.pos[1], pose.pos[2], (pose.pos[3] or 0) + 0.3 },
            tangent = pose.tangent,
          }
          local p = sphere:getPosition()
          local dx = p.x - pose.pos[1]
          local dy = p.y - pose.pos[2]
          local dz = p.z - (pose.pos[3] or p.z)
          if dx * dx + dy * dy + dz * dz > 1 then
            pcall(poseAt, sphere, pose.pos, pose.tangent)
            log("I", "alpine_rt", string.format(
              "Arrival marker %s -> %.1f %.1f %.1f",
              tostring(g.id), pose.pos[1], pose.pos[2], pose.pos[3] or 0))
          end
          local session = readSession()
          local pending = session and session.pending_restore
          if pending and pending.from_gate == g.id and canonicalLevel(pending.to_level) == level
            and setSpawnpoint and setSpawnpoint.setDefaultSP then
            local marker = "alpine_rt_arrive_" .. tostring(g.id)
            local prev = setSpawnpoint.loadDefaultSpawnpoint and setSpawnpoint.loadDefaultSpawnpoint(level) or nil
            if prev ~= marker then
              arcHomePos.restoreSpawn = { level = level, name = prev }
              setSpawnpoint.setDefaultSP(marker, level)
              log("I", "alpine_rt", "This crossing spawns at " .. marker)
            end
          end
        end
      end
    end
  end
end

local function syncUserBoxes(level)
  if not level then
    return
  end
  local keep = {}
  for _, g in ipairs(portals.gates or {}) do
    if g.user and g.from_level == level and g.box and g.box.pos then
      local name = userBoxName(g.id)
      if spawnUserBox(g) then
        keep[name] = true
      end
    end
  end
  for name, id in pairs(userBoxIds) do
    if not keep[name] then
      deleteNamed(name, id)
      userBoxIds[name] = nil
    end
  end
end

local function userGateMarkCrs(gate)
  local loc = userLocations[gate.from_level]
  local pos = gate.box and gate.box.pos
  if not loc or not pos or type(loc.anchor_beamng) ~= "table" or type(loc.crs) ~= "table" or type(loc.north) ~= "table" then
    return nil
  end
  if not loc.anchor_beamng[1] or not loc.crs[1] or not loc.north[1] then
    return nil
  end
  local nx, ny = norm2(loc.north[1], loc.north[2] or 0)
  local ex, ey = ny, -nx
  local dx = pos[1] - loc.anchor_beamng[1]
  local dy = pos[2] - loc.anchor_beamng[2]
  local east_m = dx * ex + dy * ey
  local north_m = dx * nx + dy * ny
  if loc.authority == "EPSG:3857" then
    local scale = webMercatorGroundScale(loc.crs[2])
    east_m = east_m / scale
    north_m = north_m / scale
  end
  return { loc.crs[1] + east_m, loc.crs[2] + north_m }
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
        local label = g.label
        if type(label) ~= "string" or label == "" or label:find("levels%.", 1, true) then
          label = levelTitle(g.from_level)
        end
        out[#out + 1] = {
          id = g.id,
          from_level = g.from_level,
          label = label,
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
  if name == "" or name:find("levels%.", 1, true) then
    name = levelTitle(level)
  end
  if name == "" then
    name = level
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

local function holdFreshPortal(gate)
  freshPortal.id = gate and gate.id or nil
  freshPortal.untilT = now() + 10
  dwellGate = nil
  dwellAcc = 0
  dwellNeed = 0
  uiMsg("Suppressing new portal for 10s, please move if you don't want to visit " .. destName(gate), 10)
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
  pcall(syncUserBoxes, level)
  uiMsg("Portal to " .. levelTitle(toLevel), 4)
  holdFreshPortal(gate)
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
  pcall(syncUserBoxes, level)
  uiMsg("Return portal to " .. levelTitle(inbound.from_level), 4)
  holdFreshPortal(back)
  return { ok = true, id = back.id }
end

local function listLevels()
  local out = {}
  local seen = {}
  local function add(id, title)
    id = canonicalLevel(id)
    if type(id) ~= "string" or id == "" or seen[id] or id == currentLevel() then
      return
    end
    seen[id] = true
    if type(title) ~= "string" or title == "" or title:find("levels%.", 1, true) or title:find("{{", 1, true) then
      title = nil
    end
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

local PROVIDERS = {
  ["local"] = true,
  geoland = true,
  ["geoland-aerial"] = true,
  ["geoland-terrain"] = true,
  osm = true,
}

local function regionName(name)
  name = tostring(name or ""):gsub("^%s+", ""):gsub("%s+$", "")
  name = name:gsub("[^%w_%- ]", "")
  name = name:gsub("%s+", "_")
  if #name > 48 then
    name = name:sub(1, 48)
  end
  return name
end

local function regionPath(name)
  return REGION_DIR .. "/" .. name .. ".json"
end

local function regionDocument(graph)
  local view = graph.view or {}
  return {
    format = "alpine_rt_region",
    version = 1,
    authority = mapAuthority(),
    view = {
      provider = (view.provider == "geoland" or type(view.provider) ~= "string" or not PROVIDERS[view.provider]) and "local" or view.provider,
      redraw = tonumber(view.redraw) or 0,
    },
    locations = graph.locations,
    gates = graph.gates,
    links = graph.links or {},
    moves = graph.moves or {},
  }
end

local function regionCatalog(graph)
  local locs = {}
  for id, loc in pairs(graph.locations or {}) do
    if type(loc) == "table" then
      local w = loc.wgs84
      locs[#locs + 1] = {
        id = tostring(id),
        name = levelTitle(id),
        lat = type(w) == "table" and w[1] or nil,
        lon = type(w) == "table" and w[2] or nil,
      }
    end
  end
  table.sort(locs, function(a, b)
    return tostring(a.name):lower() < tostring(b.name):lower()
  end)
  local gates = {}
  local seen = {}
  local here = currentLevel()
  local function addGate(g)
    if type(g) ~= "table" or not g.id or seen[g.id] then
      return
    end
    seen[g.id] = true
    gates[#gates + 1] = {
      id = g.id,
      from_level = g.from_level,
      to_level = g.to_level,
      label = (g.user ~= true and type(g.label) == "string" and g.label ~= "" and not g.label:find("levels%.", 1, true) and not g.label:find("{{", 1, true)) and g.label or ("To " .. levelTitle(g.to_level)),
      linked = type(g.arrive) == "table",
      builtin = g.user ~= true,
      here = canonicalLevel(g.from_level) == here,
    }
  end
  for _, g in ipairs(portals.gates or {}) do
    if canonicalLevel(g.from_level) == here then
      addGate(g)
    end
  end
  for _, g in ipairs(graph.gates or {}) do
    addGate(g)
  end
  return { locations = locs, gates = gates }
end

local function regionView(graph)
  local view = graph.view or {}
  local provider = view.provider
  if provider == "geoland" then
    provider = "local"
  end
  if type(provider) ~= "string" or not PROVIDERS[provider] then
    provider = "local"
  end
  return { provider = provider, redraw = tonumber(view.redraw) or 0 }
end

local function saveRegion(name)
  name = regionName(name)
  if name == "" then
    return fail("Region name is required.")
  end
  if FS and FS.directoryCreate and FS.directoryExists and not FS:directoryExists(REGION_DIR) then
    FS:directoryCreate(REGION_DIR, true)
  end
  local path = regionPath(name)
  if not jsonWriteFile(path, regionDocument(readGraph()), true) then
    return fail("Could not write the region file.")
  end
  log("I", "alpine_rt", "saved region " .. name)
  return { ok = true, name = name, path = path }
end

local function listRegions()
  local out = {}
  if not (FS and FS.findFiles) then
    return out
  end
  local ok, files = pcall(function()
    return FS:findFiles(REGION_DIR .. "/", "*.json", 0, true, false)
  end)
  if not ok or type(files) ~= "table" then
    return out
  end
  local seen = {}
  for _, path in ipairs(files) do
    if type(path) == "string" then
      local name = path:match("([^/\\]+)%.json$")
      if name and name ~= "" and not seen[name] then
        seen[name] = true
        out[#out + 1] = { name = name }
      end
    end
  end
  table.sort(out, function(a, b)
    return a.name:lower() < b.name:lower()
  end)
  return out
end

local function loadRegion(name)
  name = regionName(name)
  if name == "" then
    return fail("Region name is required.")
  end
  local data = jsonReadFile(regionPath(name))
  if type(data) ~= "table" or data.format ~= "alpine_rt_region" then
    return fail("Not a region file.")
  end
  if data.authority and mapAuthority() and data.authority ~= mapAuthority() then
    return fail("This file is " .. tostring(data.authority) .. ". The overview is " .. mapAuthority() .. ".")
  end
  if type(data.locations) ~= "table" or type(data.gates) ~= "table" then
    return fail("Region file is missing locations or gates.")
  end
  local view = type(data.view) == "table" and data.view or {}
  writeGraph({
    locations = data.locations,
    gates = data.gates,
    view = view,
    links = type(data.links) == "table" and data.links or {},
    moves = type(data.moves) == "table" and data.moves or {},
  })
  reloadPortals()
  uiMsg("Region loaded: " .. name, 4)
  log("I", "alpine_rt", "loaded region " .. name)
  return { ok = true, name = name, gates = #data.gates }
end

local function setRegionProvider(id)
  id = tostring(id or "")
  if id == "geoland" then
    id = "local"
  end
  if not PROVIDERS[id] then
    return fail("Unknown map provider.")
  end
  local graph = readGraph()
  graph.view.provider = id
  graph.view.redraw = (tonumber(graph.view.redraw) or 0) + 1
  writeGraph(graph)
  return { ok = true, provider = id, redraw = graph.view.redraw }
end

local function setUserLink(levelA, levelB, via)
  levelA = tostring(levelA or "")
  levelB = tostring(levelB or "")
  if levelA == "" or levelB == "" or levelA == levelB then
    return fail("Two maps are required.")
  end
  local clean = {}
  if type(via) == "table" then
    for _, p in ipairs(via) do
      if type(p) == "table" then
        local e, n = tonumber(p[1]), tonumber(p[2])
        if e and n then
          clean[#clean + 1] = { e, n }
          if #clean >= 24 then
            break
          end
        end
      end
    end
  end
  if levelA > levelB then
    levelA, levelB = levelB, levelA
    local rev = {}
    for i = #clean, 1, -1 do
      rev[#rev + 1] = clean[i]
    end
    clean = rev
  end
  local graph = readGraph()
  local kept = {}
  for _, link in ipairs(graph.links) do
    if type(link) ~= "table" or link.a ~= levelA or link.b ~= levelB then
      kept[#kept + 1] = link
    end
  end
  kept[#kept + 1] = { a = levelA, b = levelB, via = clean }
  graph.links = kept
  writeGraph(graph)
  reloadPortals()
  return { ok = true, points = #clean }
end

local function redrawRegion()
  local graph = readGraph()
  graph.view.redraw = (tonumber(graph.view.redraw) or 0) + 1
  writeGraph(graph)
  return { ok = true, redraw = graph.view.redraw }
end

-- CEF cancels https images inside the HUD (OnBeforeResourceLoad). The game
-- client downloads the tiles; the app then draws those local files.
local TILE_ROOT = "/ui/modules/apps/alpineRtTrafficMap/tilecache"
local TILE_SOURCES = {
  geoland = {
    url = "https://mapsneu.wien.gv.at/basemap/geolandbasemap/normal/google3857/{z}/{y}/{x}.png",
    ext = "png",
  },
  ["geoland-aerial"] = {
    url = "https://mapsneu.wien.gv.at/basemap/bmaporthofoto30cm/normal/google3857/{z}/{y}/{x}.jpeg",
    ext = "jpeg",
  },
  ["geoland-terrain"] = {
    url = "https://mapsneu.wien.gv.at/basemap/bmapgelaende/grau/google3857/{z}/{y}/{x}.jpeg",
    ext = "jpeg",
  },
  osm = {
    url = "https://tile.openstreetmap.org/{z}/{x}/{y}.png",
    ext = "png",
  },
}
local tileJob = { id = 0 }
local tileHttp = {}
local tileHttpSeq = 0

-- core_online.download stores a full https URL as "url" only. This game's
-- client rejects that table unless "uri" is set, and then never calls back.
local function onTileDownload(id, responseCode)
  local done = tileHttp[id]
  tileHttp[id] = nil
  if done then
    done(tonumber(responseCode) or 0)
  end
end

local function downloadTile(url, path, done)
  if not (SecureComm and SecureComm.apiCall) then
    done(0)
    return
  end
  tileHttpSeq = tileHttpSeq + 1
  local id = tileHttpSeq
  tileHttp[id] = done
  local ok, err = pcall(SecureComm.apiCall, {
    id = id,
    uri = url,
    url = url,
    outfile = path,
    reqType = "get",
    isJson = false,
    postDataString = "",
    postFileName = "",
    callback_finish_c = "extensions.alpinert.onTileDownload",
  })
  if not ok then
    tileHttp[id] = nil
    log("E", "alpine_rt", "tile http " .. tostring(err))
    done(0)
  end
end

local function tileUrl(template, z, x, y)
  return (template:gsub("{z}", tostring(z)):gsub("{x}", tostring(x)):gsub("{y}", tostring(y)))
end

local function tilePath(provider, z, x, y, ext)
  return string.format("%s/%s/%d/%d/%d.%s", TILE_ROOT, provider, z, x, y, ext)
end

local function tileFileReady(path)
  if not (FS and FS.fileExists and FS:fileExists(path)) then
    return false
  end
  local size = (FS.fileSize and FS:fileSize(path)) or 0
  if size < 32 then
    if FS.removeFile then
      FS:removeFile(path)
    end
    return false
  end
  return true
end

local function fetchRegionTiles(provider, z, x0, y0, x1, y1)
  provider = tostring(provider or "")
  if provider == "local" then
    return fail("Local tiles are fetched by tools/fetch_region_tiles.py.")
  end
  local spec = TILE_SOURCES[provider]
  if not spec or not PROVIDERS[provider] then
    return fail("Unknown map provider.")
  end
  z = math.floor(tonumber(z) or -1)
  x0 = math.floor(tonumber(x0) or 0)
  y0 = math.floor(tonumber(y0) or 0)
  x1 = math.floor(tonumber(x1) or -1)
  y1 = math.floor(tonumber(y1) or -1)
  local count = (x1 - x0 + 1) * (y1 - y0 + 1)
  if z < 0 or z > 18 or x1 < x0 or y1 < y0 or count < 1 or count > 48 then
    return fail("Tile window is out of range.")
  end
  if not (SecureComm and SecureComm.apiCall) then
    return fail("Map download is unavailable.")
  end
  if settings and settings.getValue and settings.getValue("onlineFeatures") ~= "enable" then
    return fail("Online features are disabled in the BeamNG settings.")
  end

  local id = (tonumber(tileJob.id) or 0) + 1
  local job = { id = id, pending = 0, closed = false, ready = false, failed = 0, files = {} }
  tileJob = job

  local function settle(x, y, path, ok)
    if tileJob ~= job then
      return
    end
    job.files[#job.files + 1] = { x = x, y = y, path = path, ok = ok == true }
    if not ok then
      job.failed = job.failed + 1
    end
    job.pending = job.pending - 1
    if job.closed and job.pending <= 0 then
      job.ready = true
      log("I", "alpine_rt", string.format("tiles %s z=%d failed=%d", provider, z, job.failed))
    end
  end

  for y = y0, y1 do
    for x = x0, x1 do
      local path = tilePath(provider, z, x, y, spec.ext)
      job.pending = job.pending + 1
      if tileFileReady(path) then
        settle(x, y, path, true)
      else
        local parent = path:match("^(.*)/[^/]+$")
        if parent and FS and FS.directoryCreate and not (FS.directoryExists and FS:directoryExists(parent)) then
          FS:directoryCreate(parent, true)
        end
        local url = tileUrl(spec.url, z, x, y)
        downloadTile(url, path, function(code)
          settle(x, y, path, code == 200 and tileFileReady(path))
        end)
      end
    end
  end
  job.closed = true
  if job.pending <= 0 then
    job.ready = true
  end
  return { ok = true, id = id, pending = job.pending, error = job.error }
end

local function regionTiles(id)
  id = tonumber(id)
  if not id or tileJob.id ~= id then
    return { ready = false, id = id }
  end
  if not tileJob.ready then
    return { ready = false, id = id, pending = tileJob.pending }
  end
  return {
    ready = true,
    id = id,
    failed = tileJob.failed or 0,
    files = tileJob.files,
    error = tileJob.error,
  }
end

local function moveUserGate(id)
  id = tostring(id or "")
  local level = currentLevel()
  if not level then
    return fail("No level is loaded.")
  end
  local pos, tangent = vehiclePose()
  if not pos then
    return fail("No vehicle.")
  end
  local graph = readGraph()
  local gate
  for _, g in ipairs(graph.gates) do
    if type(g) == "table" and g.id == id then
      gate = g
      break
    end
  end
  if gate then
    if canonicalLevel(gate.from_level) ~= level then
      return fail("This portal belongs to another map.")
    end
    gate.box = { pos = pos, tangent = tangent, size = { BOX_SIZE[1], BOX_SIZE[2], BOX_SIZE[3] } }
    local dest = canonicalLevel(gate.to_level)
    for _, other in ipairs(graph.gates) do
      if type(other) == "table" and other ~= gate
        and canonicalLevel(other.from_level) == dest
        and canonicalLevel(other.to_level) == level then
        other.arrive = { pos = ahead(pos, tangent, ARRIVE_AHEAD_M), tangent = tangent }
        break
      end
    end
    writeGraph(graph)
    reloadPortals()
    pcall(syncUserBoxes, level)
    uiMsg("Portal moved", 3)
    return { ok = true, id = gate.id }
  end
  local shipped
  for _, g in ipairs(portals.gates or {}) do
    if g.id == id and not g.user then
      shipped = g
      break
    end
  end
  if not shipped or not shipped.from_level then
    return fail("Portal not found.")
  end
  if canonicalLevel(shipped.from_level) ~= level then
    return fail("This portal belongs to another map.")
  end
  local rec = type(graph.moves[id]) == "table" and graph.moves[id] or {}
  rec.pos = pos
  rec.tangent = tangent
  graph.moves[id] = rec
  local dest = canonicalLevel(shipped.to_level)
  for _, other in ipairs(portals.gates) do
    if not other.user and other.id ~= id
      and canonicalLevel(other.from_level) == dest
      and canonicalLevel(other.to_level) == level then
      local back = type(graph.moves[other.id]) == "table" and graph.moves[other.id] or {}
      back.arrive = { pos = ahead(pos, tangent, ARRIVE_AHEAD_M), tangent = tangent }
      graph.moves[other.id] = back
      break
    end
  end
  writeGraph(graph)
  reloadPortals()
  arcHomePos.arriveLevel = nil
  pcall(placeMovedBoxes, level)
  uiMsg("Portal moved", 3)
  return { ok = true, id = id }
end

local function removeUserGate(id)
  id = tostring(id or "")
  local graph = readGraph()
  local kept = {}
  local found = false
  for _, g in ipairs(graph.gates) do
    if type(g) == "table" and g.id == id then
      found = true
    else
      kept[#kept + 1] = g
    end
  end
  if not found then
    return fail("Portal not found.")
  end
  graph.gates = kept
  writeGraph(graph)
  reloadPortals()
  uiMsg("Portal removed", 3)
  return { ok = true }
end

local function removeLocation(levelId)
  levelId = tostring(levelId or "")
  local graph = readGraph()
  if type(graph.locations[levelId]) ~= "table" then
    return fail("Location not found.")
  end
  graph.locations[levelId] = nil
  local kept = {}
  for _, g in ipairs(graph.gates) do
    if type(g) ~= "table" or (g.from_level ~= levelId and g.to_level ~= levelId) then
      kept[#kept + 1] = g
    end
  end
  graph.gates = kept
  writeGraph(graph)
  reloadPortals()
  uiMsg("Location removed: " .. levelId, 3)
  return { ok = true }
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

-- Clock slice. 0.40 setTimeOfDay accepts time, play, and dayLength.
-- dayScale and nightScale are gone. Do not push fog or clouds: setState retriggers the map sky.
local function applyClock(env)
  if not (core_environment and core_environment.setTimeOfDay) then
    return
  end
  if type(env) ~= "table" then
    return
  end
  local clock = {}
  local t = envTime(env)
  if t ~= nil then
    clock.time = t
  end
  if env.play ~= nil then
    clock.play = env.play == true
  end
  local dayLength = tonumber(env.dayLength)
  if dayLength and dayLength > 0 then
    clock.dayLength = dayLength
  end
  if clock.time == nil and clock.play == nil and clock.dayLength == nil then
    return
  end
  pcall(function()
    core_environment.setTimeOfDay(clock)
  end)
  log("I", "alpine_rt", "clock restore time=" .. tostring(clock.time)
    .. " play=" .. tostring(clock.play)
    .. " dayLength=" .. tostring(clock.dayLength))
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

-- Coupled trailers are other vehicles. Node ids are the coupler cids from this config.
carry.snapshotTrailers = function(playerId)
  if not playerId or not core_vehicles or type(core_vehicles.attachedCouplers) ~= "table" then
    return nil
  end
  local tags = core_vehicles.vehsCouplerTags or {}
  local out = {}
  local seen = {}
  local function hitchOf(idA, nodeA, idB, nodeB)
    if tags[idA] and tags[idA][nodeA] then
      return idA, nodeA, idB, nodeB, tags[idA][nodeA]
    end
    if tags[idB] and tags[idB][nodeB] then
      return idB, nodeB, idA, nodeA, tags[idB][nodeB]
    end
  end
  local function walk(parentId)
    if #out >= 3 then
      return
    end
    for _, link in ipairs(core_vehicles.attachedCouplers) do
      if type(link) == "table" and link[1] ~= link[2] then
        local hitchId, hitchNode, childId, childNode, tag = hitchOf(link[1], link[3], link[2], link[4])
        if hitchId == parentId and childId and childId ~= playerId and not seen[childId] then
          seen[childId] = true
          local obj = getObjectByID(childId)
          local data = core_vehicle_manager and core_vehicle_manager.getVehicleData and core_vehicle_manager.getVehicleData(childId)
          local config = data and data.config and (jsonClone(data.config) or data.config)
          local model = obj and (obj.jbeam or obj.JBeam)
          if not model and type(config) == "table" then
            model = config.model
          end
          if model then
            out[#out + 1] = {
              model = model,
              config = config,
              parentNode = hitchNode,
              childNode = childNode,
              parentTag = tag,
            }
            log("I", "alpine_rt", "Trailer on the hitch: " .. tostring(model) .. " via " .. tostring(tag))
            walk(childId)
          end
        end
      end
    end
  end
  walk(playerId)
  return out[1] and out or nil
end

carry.tickTrailer = function()
  local job = carry.trailerJob
  if type(job) ~= "table" or not job[1] then
    carry.trailerJob = nil
    return
  end
  if now() < (carry.trailerAt or 0) then
    return
  end
  local idx = carry.trailerIndex or 1
  local row = job[idx]
  if not row then
    carry.trailerJob = nil
    uiMsg("Trailer coupled", 4)
    return
  end
  local parent = playerVehicle()
  if idx > 1 then
    parent = carry.trailerSpawned and getObjectByID(carry.trailerSpawned[idx - 1])
  end
  if not parent or not parent.getID then
    return
  end
  local parentId = parent:getID()
  if not row.spawnedId then
    if not (core_vehicles and core_vehicles.spawnNewVehicle) then
      carry.trailerJob = nil
      return
    end
    local pos = parent:getPosition()
    local rot = parent.getRotation and parent:getRotation() or quat(0, 0, 0, 1)
    local spawned = core_vehicles.spawnNewVehicle(row.model, {
      config = row.config,
      pos = pos,
      rot = rot,
      autoEnterVehicle = false,
      canSpawnAnotherVehicleCheck = false,
      safeSpawn = false,
      vehicleName = "alpine_rt_trailer" .. tostring(idx),
    })
    if type(spawned) == "table" and not spawned.getID and spawned[1] then
      spawned = spawned[1]
    end
    local sid = spawned and spawned.getID and spawned:getID()
    if not sid then
      carry.trailerTries = (carry.trailerTries or 0) + 1
      if carry.trailerTries > 20 then
        log("W", "alpine_rt", "Trailer spawn failed for " .. tostring(row.model))
        carry.trailerJob = nil
      end
      return
    end
    row.spawnedId = sid
    carry.trailerSpawned = carry.trailerSpawned or {}
    carry.trailerSpawned[idx] = sid
    carry.trailerTries = 0
    log("I", "alpine_rt", "Spawned trailer " .. tostring(row.model) .. " id=" .. tostring(sid))
    return
  end
  local offsets = core_vehicles.vehsCouplerOffset
  local parentOff = offsets and offsets[parentId] and offsets[parentId][row.parentNode]
  local childOff = offsets and offsets[row.spawnedId] and offsets[row.spawnedId][row.childNode]
  if not parentOff or not childOff or not (spawn and spawn.placeTrailer) then
    carry.trailerTries = (carry.trailerTries or 0) + 1
    if carry.trailerTries > 40 then
      log("W", "alpine_rt", "Trailer hitch not ready for " .. tostring(row.model))
      carry.trailerIndex = idx + 1
      carry.trailerTries = 0
      carry.trailerAt = now() + 0.2
    end
    return
  end
  spawn.placeTrailer(parentId, parentOff, row.spawnedId, childOff, row.parentTag)
  if type(row.parentTag) == "string" and row.parentTag:match("^[%w_]+$")
    and core_vehicles.couplerTagsOptions and core_vehicles.couplerTagsOptions[row.parentTag] ~= "autoCouple" then
    parent:queueLuaCommand('beamstate.activateAutoCoupling("' .. row.parentTag .. '")')
  end
  log("I", "alpine_rt", "Trailer latched " .. tostring(row.model) .. " via " .. tostring(row.parentTag))
  carry.trailerTries = 0
  carry.trailerIndex = idx + 1
  carry.trailerAt = now() + 0.4
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
  local pos = vec3(p[1], p[2], p[3] + 0.3)
  local t = arrive.tangent or { 1, 0 }
  local rot = yawToQuat(t[1], t[2])
  -- Same 180° the old safeTeleport applied. That search also walks the car off the road
  -- when the arrival box touches a slope, so the portal point is used as-is.
  rot = quat(0, 0, 1, 0) * rot
  if veh.setClusterPosRelRot and veh.getClusterRotationSlow and veh.getRefNodeId then
    local nodeId = veh:getRefNodeId()
    local vehRot = quat(veh:getClusterRotationSlow(nodeId))
    local diffRot = vehRot:inversed() * rot
    veh:setClusterPosRelRot(nodeId, pos.x, pos.y, pos.z, diffRot.x, diffRot.y, diffRot.z, diffRot.w)
    if veh.applyClusterVelocityScaleAdd then
      veh:applyClusterVelocityScaleAdd(nodeId, 0, 0, 0, 0)
    end
    if veh.setOriginalTransform then
      veh:setOriginalTransform(pos.x, pos.y, pos.z, rot.x, rot.y, rot.z, rot.w)
    end
    log("I", "alpine_rt", string.format("Arrive at portal %.1f %.1f %.1f", pos.x, pos.y, pos.z))
    return
  end
  veh:setPositionRotation(pos.x, pos.y, pos.z, rot.x, rot.y, rot.z, rot.w)
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
  local shift = gate.moveDelta or { 0, 0, 0 }
  local sx, sy, sz = shift[1] or 0, shift[2] or 0, shift[3] or 0
  for i = 1, #arc.points - 1 do
    local a = arc.points[i]
    local b = arc.points[i + 1]
    if a and b then
      local ax, ay, az = a[1] + sx, a[2] + sy, a[3] + sz
      local bx, by, bz = b[1] + sx, b[2] + sy, b[3] + sz
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
  local shift = gate.moveDelta or { 0, 0, 0 }
  obj:setPosition(vec3(pts[1][1] + (shift[1] or 0), pts[1][2] + (shift[2] or 0), pts[1][3] + (shift[3] or 0)))
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

local readTodFraction
local gameClock
do
-- BeamNG TimeOfDay.time: 0=noon, 0.25=sunset, 0.5=midnight, 0.75=sunrise.
local function todToHour(t)
  t = tonumber(t)
  if t == nil then
    return 12
  end
  return (t * 24 + 12) % 24
end

readTodFraction = function()
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

gameClock = function(session)
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
end

local function waterStagesPath(level)
  return "/levels/" .. tostring(level) .. "/water_stages.json"
end

local function pickWaterStageName(data, month)
  local stages = (data and data.stages) or {}
  month = tonumber(month)
  if month then
    for name, spec in pairs(stages) do
      local months = spec and spec.months
      if type(months) == "table" then
        for _, m in ipairs(months) do
          if tonumber(m) == month then
            return name
          end
        end
      end
    end
  end
  return (data and data.stage) or "spring"
end

-- One decoded copy per loaded level. false means the file is absent, so a miss
-- is not probed again. Dropped on mission end.
local function cachedWaterStages(level)
  if waterFileLevel == level then
    return waterFileData
  end
  local data = jsonReadFile(waterStagesPath(level))
  if type(data) ~= "table" then
    data = false
  end
  waterFileLevel = level
  waterFileData = data
  return data
end

local function applyWaterStage(name)
  local level = currentLevel()
  if not level then
    return false
  end
  local data = cachedWaterStages(level)
  if type(data) ~= "table" or type(data.objects) ~= "table" then
    return false
  end
  if name == nil then
    local clock = gameClock(readSession())
    name = pickWaterStageName(data, clock.month)
    waterStageMonth = clock.month
  end
  local st = (data.stages or {})[name]
  if type(st) ~= "table" then
    log("W", "alpine_rt", "water stage missing: " .. tostring(name))
    return false
  end
  local dz = tonumber(st.surface_dz_m) or 0
  local ws = tonumber(st.width_scale) or 1
  local ds = tonumber(st.depth_scale) or 1
  local flow = tonumber(st.flow_mps)
  local n = 0
  for _, o in ipairs(data.objects) do
    local obj = scenetree.findObject and scenetree.findObject(o.name)
    if obj and o.class == "River" and type(o.base_nodes) == "table" then
      for i, node in ipairs(o.base_nodes) do
        local idx = i - 1
        pcall(function()
          obj:setNodePosition(idx, vec3(node[1], node[2], node[3] + dz))
          obj:setNodeWidth(idx, math.max(0.25, (tonumber(node[4]) or 4) * ws))
          obj:setNodeDepth(idx, math.max(0.25, (tonumber(node[5]) or 1.2) * ds))
        end)
      end
      if flow then
        pcall(function()
          obj:setField("FlowMagnitudePhysics", 0, tostring(flow))
        end)
      end
      pcall(function()
        if obj.regenerate then
          obj:regenerate()
        end
      end)
      n = n + 1
    elseif obj and o.class == "WaterBlock" and o.base_z then
      pcall(function()
        local p = obj:getPosition()
        obj:setPosition(vec3(p.x, p.y, o.base_z + dz))
      end)
      n = n + 1
    end
  end
  waterStageFor = level .. ":" .. tostring(name)
  waterStageLevel = level
  log("I", "alpine_rt", "water stage " .. tostring(name) .. " objects=" .. tostring(n))
  return n > 0
end

local function ensureWaterStage()
  local level = currentLevel()
  if not level then
    return
  end
  if waterStageLevel == level and waterStageFor then
    return
  end
  local data = cachedWaterStages(level)
  if data == false or type(data) ~= "table" then
    waterStageFor = level .. ":none"
    waterStageLevel = level
    return
  end
  local clock = gameClock(readSession())
  local name = pickWaterStageName(data, clock.month)
  waterStageMonth = clock.month
  local tag = level .. ":" .. tostring(name)
  if waterStageFor == tag then
    waterStageLevel = level
    return
  end
  if not applyWaterStage(name) then
    waterStageFor = tag
    waterStageLevel = level
  end
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

local function liveDayLength()
  if not (core_environment and core_environment.getTimeOfDay) then
    return nil
  end
  local tod = core_environment.getTimeOfDay()
  local n = tod and tonumber(tod.dayLength)
  if n and n > 0 then
    return n
  end
  return nil
end

local function stampWorld(session)
  session = session or {}
  session.world = session.world or {}
  local w = session.world
  local dayLength = liveDayLength()
  if dayLength then
    w.day_length_s = dayLength
    local rate = 86400 / dayLength
    local whole = math.floor(rate + 0.5)
    if math.abs(rate - whole) < 0.05 then
      w.clock_rate = whole
    else
      w.clock_rate = math.floor(rate * 1000 + 0.5) / 1000
    end
  elseif w.day_length_s == nil then
    w.day_length_s = DAY_LENGTH_S
    w.clock_rate = 24
  end
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
    local clock = gameClock(session)
    if waterStageMonth and clock.month ~= waterStageMonth then
      waterStageFor = nil
      log("I", "alpine_rt", "water month " .. tostring(waterStageMonth) .. " -> " .. tostring(clock.month))
    end
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

local gateById

local function pointOf(p)
  if type(p) ~= "table" then
    return nil
  end
  local e, n = tonumber(p[1]), tonumber(p[2])
  if not e or not n then
    return nil
  end
  return { e, n }
end

local function authoredVia(road, aIsLo)
  local spec = road.via_wgs84
  local pts = {}
  if type(spec) == "table" and type(spec.points) == "table" then
    for _, p in ipairs(spec.points) do
      if type(p) == "table" then
        local lat, lon = tonumber(p[1]), tonumber(p[2])
        if lat and lon then
          local e, n = wgs84ToWebMercator(lat, lon)
          if e and n then
            pts[#pts + 1] = { e, n }
          end
        end
      end
    end
    if spec.along and road.a and tostring(spec.along) ~= tostring(road.a) then
      pts = reversePts(pts)
    end
  end
  if not aIsLo then
    pts = reversePts(pts)
  end
  return pts
end

-- Control polyline for a shipped road, ordered from the lexicographic first level to the second.
-- A saved link replaces the authored bends. Endpoints stay the portal marks.
local function builtInEditRoute(road)
  if road.user or not road.a or not road.b then
    return nil
  end
  local ga = gateById(road.a)
  local gb = gateById(road.b)
  local route = road.route_crs
  if not ga or not gb or not ga.from_level or not gb.from_level then
    return nil
  end
  if type(route) ~= "table" or #route < 2 then
    return nil
  end
  local startPt = pointOf(route[1])
  local endPt = pointOf(route[#route])
  if not startPt or not endPt then
    return nil
  end
  local lo, hi = ga.from_level, gb.from_level
  local aIsLo = true
  if lo > hi then
    lo, hi = hi, lo
    aIsLo = false
  end
  local loMark = aIsLo and startPt or endPt
  local hiMark = aIsLo and endPt or startPt
  local via
  local link = linkRecord(lo, hi)
  if link then
    via = copyMercator(link.via)
  else
    via = authoredVia(road, aIsLo)
  end
  local out = { loMark }
  for _, p in ipairs(via) do
    out[#out + 1] = p
  end
  out[#out + 1] = hiMark
  return out, { lo, hi }
end

gateById = function(id)
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
  if gate and gate.discoverable then
    cls = "clear"
  end
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

-- The environment panel shows LevelInfo.fogDensity * 1000. UDW's native clear
-- preset settles at 0.8 and overcast at 2, and that 6 s lerp starts from the
-- map fog, which on these levels is often already around 2. Hold a lower cap
-- across the lerp so a large level does not open in thick fog. Rain and snow
-- keep the preset. A map that is already clearer is left alone.
local FOG_CAP = {
  sun = 0.49 / 1000,
  clouds = 0.99 / 1000,
}
local FOG_CAP_HOLD_S = 12
local fogCapMax = nil
local fogCapUntil = 0

local function levelInfoObj()
  if scenetree and scenetree.theLevelInfo then
    return scenetree.theLevelInfo
  end
  if scenetree and scenetree.findObject then
    local named = scenetree.findObject("theLevelInfo")
    if named then
      return named
    end
  end
  if scenetree and scenetree.findClassObjects then
    local list = scenetree.findClassObjects("LevelInfo")
    if list and list[1] and scenetree.findObject then
      return scenetree.findObject(list[1])
    end
  end
  return nil
end

local function clampLevelFog(maxFog)
  if not maxFog then
    return
  end
  local li = levelInfoObj()
  if not li then
    return
  end
  local have = tonumber(li.fogDensity)
  if not have or have <= maxFog then
    return
  end
  pcall(function()
    li.fogDensity = maxFog
    if li.postApply then
      li:postApply()
    end
  end)
end

local function armFogCap(kind)
  local maxFog = FOG_CAP[kind]
  fogCapMax = maxFog
  fogCapUntil = maxFog and (now() + FOG_CAP_HOLD_S) or 0
  if not maxFog then
    return
  end
  clampLevelFog(maxFog)
  log("I", "alpine_rt", "fog cap " .. tostring(kind) .. " panel<=" .. string.format("%.2f", maxFog * 1000))
end

local function tickFogCap()
  if not fogCapMax or now() > fogCapUntil then
    fogCapMax = nil
    return
  end
  clampLevelFog(fogCapMax)
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
    armFogCap(kind)
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
  armFogCap(kind)
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
    local hiddenRoad = r.discoverable == true or (a and a.discoverable) or (b and b.discoverable)
    if hiddenRoad then
      -- side portals have no overview route
    else
    local mark = r.map_mark
    if type(mark) == "table" and type(mark.crs) == "table" and #mark.crs >= 2 then
      local da = a and mapDensity(a.to_level, clock, seed) or nil
      local db = b and mapDensity(b.to_level, clock, seed) or nil
      local route = type(r.route_crs) == "table" and r.route_crs[1] and r.route_crs or nil
      local ends = r.ends
      local editable = r.user == true
      if not r.user then
        local built, pair = builtInEditRoute(r)
        if built and pair then
          route = built
          ends = pair
          editable = true
        end
      end
      roads[#roads + 1] = {
        id = tostring(r.id or r.a or ""),
        user = r.user == true,
        editable = editable,
        ends = ends,
        mark = mark,
        route = route,
        a = a and { id = tostring(a.id or r.a), to_level = a.to_level, density = da } or nil,
        b = b and { id = tostring(b.id or r.b), to_level = b.to_level, density = db } or nil,
      }
    end
    end
  end
  local gateMarks = {}
  for _, g in ipairs(portals.gates or {}) do
    if g.from_level == level then
      local crs = g.map_mark and g.map_mark.crs
      if g.user then
        crs = userGateMarkCrs(g) or crs
      end
      local hidden = g.discoverable == true
      local found = discoveredPortals[tostring(g.id)] == true
      if type(crs) == "table" and crs[1] and (not hidden or found) then
        gateMarks[#gateMarks + 1] = {
          id = tostring(g.id),
          crs = { tonumber(crs[1]), tonumber(crs[2]) },
          discovered = hidden and found or false,
        }
      end
    end
  end
  local graphNow = readGraph()
  local maps = {}
  local levels = (portals.map and portals.map.levels) or {}
  for id, rec in pairs(levels) do
    local dens = mapDensity(id, clock, seed)
    local wx = (id == level) and hereWeather or classifyWeatherSim(id, t, seed)
    maps[#maps + 1] = {
      id = tostring(id),
      title = levelTitle(id),
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
    gate_marks = gateMarks,
    setup = setupState(),
    view = regionView(graphNow),
    region = regionCatalog(graphNow),
  }
end

do
local function requestPartConditions()
  carry.token = carry.token + 1
  local token = carry.token
  carry.readyDamage = false
  carry.readyFuel = false
  carry.readyOdo = false
  carry.readyCargo = false
  carry.ready = false
  local function publish()
    carry.ready = carry.readyDamage and carry.readyFuel and carry.readyOdo and carry.readyCargo
  end
  local veh = playerVehicle()
  if not veh or not core_vehicleBridge or not core_vehicleBridge.requestValue then
    carry.readyDamage = true
    carry.readyFuel = true
    carry.readyOdo = true
    carry.readyCargo = true
    carry.odometer = false
    carry.cargo = false
    carry.ready = true
    return
  end
  core_vehicleBridge.requestValue(veh, function(res)
    if token ~= carry.token then
      return
    end
    local result = res and res.result
    if type(result) == "table" then
      carry.conditions = result
    else
      carry.conditions = false
    end
    carry.readyDamage = true
    publish()
  end, "getPartConditions")
  core_vehicleBridge.requestValue(veh, function(res)
    if token ~= carry.token then
      return
    end
    local list = res and (res[1] or res.result)
    local fuel = {}
    if type(list) == "table" then
      for _, row in ipairs(list) do
        if type(row) == "table" and type(row.name) == "string" and type(row.currentEnergy) == "number" then
          fuel[#fuel + 1] = { name = row.name, energy = row.currentEnergy }
        end
      end
    end
    carry.fuel = fuel[1] and fuel or false
    carry.readyFuel = true
    publish()
  end, "energyStorage")
  -- Root reading in metres. Part wear stores the same number per part, but a
  -- car with no damage sample used to spawn at 0.
  core_vehicleBridge.requestValue(veh, function(res)
    if token ~= carry.token then
      return
    end
    local value = res and tonumber(res.result)
    carry.odometer = value or false
    carry.readyOdo = true
    publish()
  end, "getRootPartOdometer")
  -- Container fill (bed, tank, bulk). Passenger seats are weight on the dummy
  -- path. Cargo parts chosen in the vehicle config already ride along in that config.
  core_vehicleBridge.requestValue(veh, function(res)
    if token ~= carry.token then
      return
    end
    local list = nil
    if type(res) == "table" then
      if type(res[1]) == "table" then
        list = res[1]
      elseif type(res.result) == "table" then
        list = type(res.result[1]) == "table" and res.result[1] or res.result
      end
    end
    local rows = {}
    if type(list) == "table" then
      for _, entry in ipairs(list) do
        if type(entry) == "table" and entry.id ~= nil then
          local passengersOnly = false
          if type(entry.cargoTypes) == "table" and entry.cargoTypes[1] then
            passengersOnly = true
            for _, kind in ipairs(entry.cargoTypes) do
              if kind ~= "passenger" then
                passengersOnly = false
                break
              end
            end
          end
          local volume = tonumber(entry.targetVolume) or tonumber(entry.currentVolume) or 0
          local density = tonumber(entry.targetDensity) or tonumber(entry.currentDensity) or 1
          if not passengersOnly and volume > 1e-3 then
            rows[#rows + 1] = { id = entry.id, volume = volume, density = density }
          end
        end
      end
    end
    carry.cargo = rows[1] and rows or false
    carry.readyCargo = true
    publish()
  end, "getCargoContainers")
end
carry.request = requestPartConditions
M.onCarrySaved = function()
  carry.beamSaved = true
end
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
  carry.hold = {
    since = now(),
    to_level = gate.to_level,
    vehicle = vehicle,
  }
  carry.beamSaved = false
  carry.request()
  local vehNow = playerVehicle()
  carry.passengers = nil
  if vehNow and gameplay_seatOccupants and gameplay_seatOccupants.getSeats then
    local seated = gameplay_seatOccupants.getSeats(vehNow:getID())
    local dummies = {}
    for _, seat in ipairs(seated or {}) do
      if type(seat) == "table" and seat.occupantType == "dummy" and seat.seatId then
        dummies[#dummies + 1] = { seatId = seat.seatId, weight = seat.weight }
      end
    end
    if dummies[1] then
      carry.passengers = dummies
    end
  end
  carry.trailers = nil
  if vehNow and vehNow.getID and carry.snapshotTrailers then
    carry.trailers = carry.snapshotTrailers(vehNow:getID())
  end
  if vehNow and vehNow.queueLuaCommand then
    vehNow:queueLuaCommand('pcall(function() beamstate.save("settings/alpine_rt/vehicle_carry.json") end) obj:queueGameEngineLua("if extensions.alpinert and extensions.alpinert.onCarrySaved then extensions.alpinert.onCarrySaved() end")')
  else
    carry.beamSaved = true
  end
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
  if arcHomePos.restoreSpawn and setSpawnpoint and setSpawnpoint.setDefaultSP then
    local back = arcHomePos.restoreSpawn
    arcHomePos.restoreSpawn = nil
    if type(back.name) == "string" and back.name ~= "" then
      pcall(setSpawnpoint.setDefaultSP, back.name, back.level)
    end
  end
  local pending = session.pending_restore
  local level = currentLevel()
  if pending.to_level and level and pending.to_level ~= level then
    log("W", "alpine_rt", "pending_restore for " .. tostring(pending.to_level) .. " but on " .. tostring(level))
    restoreArmed = false
    return true
  end
  applyClock(session.settings and session.settings.environment)
  carry.damage = nil
  carry.fuelRestore = nil
  carry.odometerRestore = nil
  carry.cargoRestore = nil
  if session.vehicle and type(session.vehicle.partConditions) == "table" then
    carry.damage = session.vehicle.partConditions
  end
  if session.vehicle and type(session.vehicle.fuel) == "table" then
    carry.fuelRestore = session.vehicle.fuel
  end
  if session.vehicle and tonumber(session.vehicle.odometer) then
    carry.odometerRestore = tonumber(session.vehicle.odometer)
  end
  if session.vehicle and type(session.vehicle.cargo) == "table" then
    carry.cargoRestore = session.vehicle.cargo
  end
  carry.beamLoad = session.vehicle and session.vehicle.beamFile or nil
  carry.arrive = pending.arrive
  carry.passengersRestore = session.vehicle and type(session.vehicle.passengers) == "table" and session.vehicle.passengers or nil
  carry.trailerJob = nil
  carry.trailerWaitReapply = nil
  if session.vehicle and type(session.vehicle.trailers) == "table" and session.vehicle.trailers[1] then
    carry.trailerJob = session.vehicle.trailers
    carry.trailerIndex = 1
    carry.trailerTries = 0
    carry.trailerSpawned = nil
    carry.trailerAt = nil
    carry.trailerWaitReapply = true
  end
  carry.reapplyStart = now()
  carry.reapplyAt = now()
  carry.reapplyShown = nil
  carry.didReplace = nil
  if pending.weather then
    applyForecast(pending.weather)
    session.applied_weather = { level = pending.to_level or level, kind = pending.weather }
  else
    applyUdw(session.udw)
  end
  session.pending_restore = nil
  writeSession(session)
  graceUntil = now() + 28
  dwellGate = nil
  dwellAcc = 0
  dwellNeed = 0
  restoreArmed = false
  restoreTries = 0
  log("I", "alpine_rt", "Spawn left to the game, reapply now")
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
  if currentLevel() then
    worldReady = true
  end
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
  fogCapMax = nil
  fogCapUntil = 0
  trafficSpawnedFor = nil
  trafficWait = 0
  TEST_TRAFFIC._navLevel = nil
  fanRotors = nil
  userBoxIds = {}
  arcHomePos.arriveLevel = nil
  waterStageFor = nil
  waterStageLevel = nil
  waterStageMonth = nil
  waterFileLevel = nil
  waterFileData = nil
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
  -- Lane dashes are DecalRoads named line_* with hiddenInNavi. The navgraph still
  -- treats them as roads, so traffic piles up on the nearest dash. Drop them once
  -- per level, then only spawn when the closest road is the asphalt.
  if TEST_TRAFFIC._navLevel ~= level then
    local changed = 0
    if scenetree and scenetree.findClassObjects then
      for _, name in ipairs(scenetree.findClassObjects("DecalRoad")) do
        local road = scenetree.findObject(name)
        local marking = road and (road.hiddenInNavi or (type(name) == "string" and name:sub(1, 5) == "line_"))
        local drv = road and tonumber(road.drivability)
        if marking and (drv == nil or drv > 0) then
          if road.setField then
            road:setField("drivability", 0, "-1")
          else
            road.drivability = -1
          end
          changed = changed + 1
        end
      end
    end
    if changed > 0 and map.reset then
      local okReset, errReset = pcall(map.reset)
      log("I", "alpine_rt", "navgraph dropped " .. tostring(changed) .. " line markings ok=" .. tostring(okReset) .. " " .. tostring(errReset or ""))
    end
    TEST_TRAFFIC._navLevel = level
  end
  if carry.reapplyAt then
    return
  end
  if map.findClosestRoad and map.getMap then
    local veh = playerVehicle()
    local pos = veh and veh.getPosition and veh:getPosition()
    local n1, n2 = pos and map.findClosestRoad(pos)
    local nodes = n1 and map.getMap().nodes
    local a = nodes and nodes[n1]
    local b = nodes and nodes[n2]
    local radius = math.max(tonumber(a and a.radius) or 0, tonumber(b and b.radius) or 0)
    local link = a and a.links and b and (a.links[n2] or (b.links and b.links[n1]))
    if not n1 or radius < 2 or (link and link.hiddenInNavi) then
      trafficSpawnedFor = level
      log("W", "alpine_rt", "closest road is still a lane marking, radius=" .. tostring(radius) .. ", traffic not spawned")
      uiMsg("Traffic left off, road graph is still the lane markings", 6)
      return
    end
  end
  if not (gameplay_traffic and gameplay_traffic.setupTraffic) and extensions and extensions.load then
    pcall(extensions.load, "gameplay_traffic")
  end
  if not (gameplay_traffic and gameplay_traffic.setupTraffic) then
    trafficSpawnedFor = level
    log("W", "alpine_rt", "gameplay_traffic missing")
    return
  end
  if gameplay_traffic.getState then
    local trafficState = gameplay_traffic.getState()
    if trafficState == "loading" or trafficState == "spawning" or trafficState == "on" then
      trafficSpawnedFor = level
      log("I", "alpine_rt", "traffic already " .. tostring(trafficState) .. ", leaving that spawn alone")
      return
    end
  end
  trafficSpawnedFor = level
  -- 0.40 still takes (amount, {activeAmount}). The pause menu's parking count is a
  -- different path (trafficParkingAmount) and is not part of this test pool.
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
  if carry.hold then
    if (carry.ready and carry.beamSaved) or (now() - carry.hold.since) > 2.0 then
      local cond = nil
      if type(carry.conditions) == "table" then
        cond = jsonClone(carry.conditions) or carry.conditions
      end
      local fuel = nil
      if type(carry.fuel) == "table" then
        fuel = jsonClone(carry.fuel) or carry.fuel
      end
      local session = readSession()
      if session and session.vehicle then
        session.vehicle.partConditions = cond
        session.vehicle.fuel = fuel
        session.vehicle.odometer = tonumber(carry.odometer) or nil
        session.vehicle.cargo = type(carry.cargo) == "table" and (jsonClone(carry.cargo) or carry.cargo) or nil
        session.vehicle.beamFile = carry.beamSaved and true or nil
        session.vehicle.passengers = type(carry.passengers) == "table" and (jsonClone(carry.passengers) or carry.passengers) or nil
        session.vehicle.trailers = type(carry.trailers) == "table" and carry.trailers or nil
        writeSession(session)
      end
      if carry.hold.vehicle then
        carry.hold.vehicle.partConditions = cond
        carry.hold.vehicle.fuel = fuel
      end
      log("I", "alpine_rt", "Carrying vehicle state damage=" .. tostring(cond ~= nil) .. " fuel=" .. tostring(fuel ~= nil) .. " beams=" .. tostring(carry.beamSaved == true) .. " passengers=" .. tostring(type(carry.passengers) == "table" and #carry.passengers or 0) .. " odometer=" .. tostring(carry.odometer) .. " cargo=" .. tostring(type(carry.cargo) == "table" and #carry.cargo or 0) .. " trailers=" .. tostring(type(carry.trailers) == "table" and #carry.trailers or 0))
      switchQueued = {
        to_level = carry.hold.to_level,
        vehicle = carry.hold.vehicle,
      }
      carry.hold = nil
      carry.ready = false
      carry.conditions = nil
      carry.fuel = nil
    end
    return
  end
  if carry.reapplyAt then
    local left = math.ceil(carry.reapplyAt - now())
    if left < 0 then
      left = 0
    end
    if left ~= carry.reapplyShown then
      carry.reapplyShown = left
      if left > 0 then
        uiMsg("Please wait! reapplying settings in " .. tostring(left) .. " s...", 1.2)
      end
    end
    if now() >= carry.reapplyAt then
      local trafficState = gameplay_traffic and gameplay_traffic.getState and gameplay_traffic.getState() or ""
      local trafficBusy = trafficState == "loading" or trafficState == "spawning"
      if trafficBusy and (now() - (carry.reapplyStart or now())) < 20 then
        carry.reapplyAt = now() + 1
        carry.reapplyShown = -1
      else
        local veh = playerVehicle()
        local want = readSession()
        want = want and want.vehicle
        if veh and want and want.model and veh.jbeam ~= want.model and not carry.didReplace and core_vehicles and core_vehicles.replaceVehicle then
          carry.didReplace = true
          core_vehicles.replaceVehicle(want.model, { config = want.config })
          carry.reapplyAt = now() + 2
          carry.reapplyShown = -1
        elseif veh then
          local arrive = carry.arrive
          local nearGate = nil
          if arrive and arrive.pos then
            local px, py = arrive.pos[1], arrive.pos[2]
            local bestD = nil
            for _, g in ipairs(gatesForLevel(currentLevel())) do
              local b = g.box and g.box.pos
              if b then
                local dx, dy = px - b[1], py - b[2]
                local d = dx * dx + dy * dy
                if not bestD or d < bestD then
                  bestD = d
                  nearGate = g
                end
              end
            end
            local box = nearGate and nearGate.box
            -- The gate tangent is not the road. On Imst the box sits ~22 m beside
            -- the asphalt and ~6 m below it, so a 20 m step along that tangent
            -- lands on the slope. Snap to the nearest decal centerline instead.
            if box and box.pos and bestD and bestD < 80 * 80 then
              if not arcHomePos.asphaltNear then
                placeMovedBoxes(currentLevel())
              end
              if arcHomePos.asphaltNear then
                local okRoad, roadArrive = pcall(arcHomePos.asphaltNear, box)
                if okRoad and roadArrive then
                  arrive = roadArrive
                end
              end
            end
          end
          local already = false
          if arrive and arrive.pos and veh.getPosition then
            local vp = veh:getPosition()
            local dx = vp.x - arrive.pos[1]
            local dy = vp.y - arrive.pos[2]
            local dz = vp.z - ((arrive.pos[3] or vp.z) + 0.3)
            already = dx * dx + dy * dy + dz * dz < 4
          end
          if already then
            log("I", "alpine_rt", "Already at the moved arrival, no second teleport")
          else
            teleportToArrive(arrive)
          end
          carry.arriveHold = nil
          if nearGate and playerInGate(nearGate) then
            carry.arriveHold = nearGate.id
            uiMsg("Leave this portal once before it can send you back.", 6)
          end
          if core_vehicleBridge and core_vehicleBridge.executeAction then
            pcall(function()
              local odo = tonumber(carry.odometerRestore) or 0
              -- false, not nil: a nil argument would drop the odometer off the call.
              if type(carry.damage) == "table" or odo > 1 then
                core_vehicleBridge.executeAction(veh, "initPartConditions", type(carry.damage) == "table" and carry.damage or false, odo, 1, 1)
              end
              if type(carry.fuelRestore) == "table" then
                for _, row in ipairs(carry.fuelRestore) do
                  if type(row) == "table" and row.name and row.energy then
                    core_vehicleBridge.executeAction(veh, "setEnergyStorageEnergy", row.name, row.energy)
                  end
                end
              end
              if type(carry.cargoRestore) == "table" then
                local payload = {}
                for _, row in ipairs(carry.cargoRestore) do
                  if type(row) == "table" and row.id ~= nil and type(row.volume) == "number" then
                    local density = row.density
                    if type(density) ~= "number" then
                      density = 1
                    end
                    payload[row.id] = { containerId = row.id, volume = row.volume, density = density }
                  end
                end
                if next(payload) then
                  core_vehicleBridge.executeAction(veh, "setCargoContainers", payload, "updateExplicit")
                end
              end
            end)
          end
          if carry.beamLoad and veh.queueLuaCommand then
            veh:queueLuaCommand('pcall(function() beamstate.load("settings/alpine_rt/vehicle_carry.json") for _, c in pairs(controller.getControllersByType("advancedCouplerControl")) do if (not c.getGroupState or c.getGroupState() ~= "broken") and c.reset then c.reset() end end end)')
          end
          carry.latchUntil = now() + 2
          carry.damage = nil
          carry.fuelRestore = nil
          carry.odometerRestore = nil
          carry.cargoRestore = nil
          carry.beamLoad = nil
          carry.arrive = nil
          carry.reapplyAt = nil
          if carry.trailerWaitReapply then
            carry.trailerWaitReapply = nil
            carry.trailerAt = now() + 0.6
          end
          graceUntil = now() + (tonumber(portals.grace_s) or 8)
          uiMsg("Settings restored", 3)
          log("I", "alpine_rt", "Vehicle settings reapplied once")
        else
          carry.reapplyAt = now() + 1
          carry.reapplyShown = -1
        end
      end
    end
  end
  if carry.latchUntil then
    local veh = playerVehicle()
    if veh and now() < carry.latchUntil then
      if veh.queueLuaCommand then
        veh:queueLuaCommand('pcall(function() for _, c in pairs(controller.getControllersByType("advancedCouplerControl")) do if c.tryAttachGroupImpulse then c.tryAttachGroupImpulse() end end end)')
      end
      if carry.passengersRestore and gameplay_seatOccupants and gameplay_seatOccupants.setDummyOccupant and not carry.reseatOnce then
        carry.reseatOnce = true
        local reseatId = veh.getID and veh:getID() or 0
        local passengers = carry.passengersRestore
        pcall(function()
          for _, seat in ipairs(passengers) do
            if type(seat) == "table" and seat.seatId then
              gameplay_seatOccupants.setDummyOccupant(reseatId, seat.seatId, seat.weight)
            end
          end
        end)
      end
    else
      if veh and carry.passengersRestore and gameplay_seatOccupants and gameplay_seatOccupants.setDummyOccupant then
        local reseatId = veh.getID and veh:getID() or 0
        local passengers = carry.passengersRestore
        pcall(function()
          for _, seat in ipairs(passengers) do
            if type(seat) == "table" and seat.seatId then
              gameplay_seatOccupants.setDummyOccupant(reseatId, seat.seatId, seat.weight)
            end
          end
        end)
      end
      carry.latchUntil = nil
      carry.passengersRestore = nil
      carry.reseatOnce = nil
    end
  end
  if carry.trailerJob and carry.tickTrailer and not carry.trailerWaitReapply and not carry.reapplyAt and not carry.hold then
    carry.tickTrailer()
  end
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
  pcall(ensureWaterStage)
  local okBox, errBox = pcall(syncUserBoxes, level)
  pcall(placeMovedBoxes, level)
  if not okBox and errBox ~= userBoxErr then
    userBoxErr = errBox
    log("E", "alpine_rt", "user box " .. tostring(errBox))
  end
  pcall(drawUserPortals, level)
  if carry.arriveHold then
    local held = nil
    for _, g in ipairs(gatesForLevel(level)) do
      if g.id == carry.arriveHold then
        held = g
        break
      end
    end
    if not held or not playerInGate(held) then
      log("I", "alpine_rt", "Arrival portal left, return allowed")
      carry.arriveHold = nil
    end
  end
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
  if carry.arriveHold and inside.id == carry.arriveHold then
    if inside.user then
      drawGateArc(inside)
    else
      ensureLiveArc(inside)
      drawGateArc(inside)
    end
    dwellGate = nil
    dwellAcc = 0
    dwellNeed = 0
    return
  end
  if freshPortal.id and inside.id == freshPortal.id and now() < freshPortal.untilT then
    if inside.user then
      drawGateArc(inside)
    end
    dwellGate = nil
    dwellAcc = 0
    dwellNeed = 0
    return
  end
  if now() - (carry.requested or 0) > 0.4 then
    carry.requested = now()
    carry.request()
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
  local gid = tostring(inside.id)
  if inside.discoverable and not discoveredPortals[gid] and dwellAcc >= 1 then
    discoveredPortals[gid] = true
    uiMsg("Hidden portal to " .. destName(inside) .. " discovered", 4)
    discoverNoticeUntil = now() + 3.5
    lastMsgS = -1
  end
  if now() >= discoverNoticeUntil and (sec ~= lastMsgS or (paused and dwellMsgHold <= 0 and remain > 0.05)) then
    if paused then
      dwellMsgHold = 0.4
    end
    lastMsgS = sec
    if remain > 0.05 then
      uiMsg(string.format("Travelling to %s — %ds", destName(inside), sec), paused and 0.5 or 1.05)
    end
  end

  if dwellAcc >= need then
    dwellGate = nil
    dwellAcc = 0
    dwellNeed = 0
    hideAllArcs()
    uiMsg("Travelling to " .. destName(inside), 2)
    queueSwitch(inside)
  end
end

M.onExtensionLoaded = onExtensionLoaded
M.onWorldReadyState = onWorldReadyState
M.onClientEndMission = onClientEndMission
M.onClientCustomObjectSpawning = function(mission)
  local ok, err = pcall(placeMovedBoxes, mission)
  if not ok then
    log("E", "alpine_rt", "arrival marker " .. tostring(err))
  end
end
-- After core_weather, so the cap wins over its preset lerp (that hook writes
-- LevelInfo fog on onPreRender for the whole transition).
M.dependencies = { "core_weather" }
M.onPreRender = function()
  tickFogCap()
end
M.onUpdate = onUpdate
M.onSerialize = function()
  return {
    dwellAcc = dwellAcc,
    dwellNeed = dwellNeed,
    dwellId = dwellGate and dwellGate.id or nil,
    graceUntil = graceUntil,
  }
end
M.onDeserialized = function(data)
  loadPortals()
  hideAllArcs()
  if type(data) == "table" then
    dwellAcc = data.dwellAcc or 0
    dwellNeed = data.dwellNeed or 0
    graceUntil = data.graceUntil or 0
  end
end

M.getTrafficMap = getTrafficMap
M.defineLocation = defineLocation
M.placePortal = placePortal
M.placeReturn = placeReturn
M.listLevels = listLevels
M.saveRegion = saveRegion
M.listRegions = listRegions
M.loadRegion = loadRegion
M.setRegionProvider = setRegionProvider
M.redrawRegion = redrawRegion
M.setUserLink = setUserLink
M.onTileDownload = onTileDownload
M.fetchRegionTiles = fetchRegionTiles
M.regionTiles = regionTiles
M.moveUserGate = moveUserGate
M.removeUserGate = removeUserGate
M.removeLocation = removeLocation
M.applyWaterStage = applyWaterStage

return M
