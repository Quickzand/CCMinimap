local M = {}

local INCOMPLETE_RETRY_S = {2, 5, 10, 15}
local FRONTIER_RETRY_S = 30
local MIN_BPP = 0.25
local MAX_BPP = 128
local PRELOAD_RETRY_S = 5
local PRELOAD_CACHE_MAX = 24

local function incompleteRetryDelay(attempt)
  local idx = math.min(#INCOMPLETE_RETRY_S, math.max(1, attempt or 1))
  return INCOMPLETE_RETRY_S[idx]
end

local function retryDelay(missing, frontier, attempt)
  if (frontier or 0) > 0 and (missing or 0) == 0 then return FRONTIER_RETRY_S end
  return incompleteRetryDelay(attempt)
end

function M.init(env)
  local state = env.state

  local function clampedBpp(value)
    return math.min(MAX_BPP, math.max(MIN_BPP, value))
  end

  local function frameCenterKey(fetchBpp, fetchLod, mapH, cx, cz)
    return table.concat({
      env.width(),
      mapH,
      fetchBpp,
      fetchLod,
      math.floor(cx * 10) / 10,
      math.floor(cz * 10) / 10,
    }, ":")
  end

  local function fetchFrameData(cx, cz, fetchBpp, fetchLod)
    return env.httpGetJson(env.buildUrl(cx, cz, fetchBpp, fetchLod))
  end

  local function rememberPreloadedFrame(key, data)
    if not data or not data.text then return end
    state.preloadedZoomTiles = state.preloadedZoomTiles or {}
    state.preloadedZoomOrder = state.preloadedZoomOrder or {}
    if not state.preloadedZoomTiles[key] then
      state.preloadedZoomOrder[#state.preloadedZoomOrder + 1] = key
    end
    state.preloadedZoomTiles[key] = data
    while #state.preloadedZoomOrder > PRELOAD_CACHE_MAX do
      local old = table.remove(state.preloadedZoomOrder, 1)
      state.preloadedZoomTiles[old] = nil
    end
  end

  local function takePreloadedFrame(key)
    local cache = state.preloadedZoomTiles
    if not cache then return nil end
    local data = cache[key]
    if not data then return nil end
    cache[key] = nil
    for i, old in ipairs(state.preloadedZoomOrder or {}) do
      if old == key then
        table.remove(state.preloadedZoomOrder, i)
        break
      end
    end
    return data
  end

  local function maybeFetchSidecar()
    if os.clock() < state.sidecarAt then return end
    local interval = state.frontierMode and env.frontierSidecarInterval or env.sidecarInterval
    state.sidecarAt = os.clock() + interval
    local p = env.httpGetJson(env.server .. "/players")
    if p and p.players then state.players = p.players end
    local w = env.httpGetJson(env.server .. "/waypoints")
    if w then
      if env.setWaypoints then env.setWaypoints(w)
      else state.waypoints = w end
    end
    -- /height is ship-only. Pockets receive groundY from ship state broadcasts.
    if not env.isPocket and state.lastPos then
      local url = string.format("%s/height?x=%s&z=%s&r=%d",
        env.server, env.urlencode(state.lastPos.x), env.urlencode(state.lastPos.z), env.groundChunkRadius)
      local h = env.httpGetJson(url)
      if h and type(h.groundMaxY) == "number" then
        state.groundY = h.groundMaxY
        state.groundYMin = h.groundMinY
        state.heightMissingTiles = tonumber(h.missingTiles) or 0
      end
    end
  end

  local function fetchTile(ti, tj, fetchBpp, fetchLod, mapH)
    local now = os.clock()
    local key = env.tileKey(ti, tj)
    local existing = state.tiles[key]
    local tileWB, tileHB = env.tileWorldDim(mapH)
    local cx = (state.tileOriginX or 0) + ti * tileWB
    local cz = (state.tileOriginZ or 0) + tj * tileHB
    local preloadKey = frameCenterKey(fetchBpp, fetchLod, mapH, cx, cz)
    local data, err = takePreloadedFrame(preloadKey)
    if not data then
      data, err = fetchFrameData(cx, cz, fetchBpp, fetchLod)
    end
    if data and data.text
       and state.bpp == fetchBpp and state.lod == fetchLod
       and state.tileW == env.width() and state.tileH == mapH then
      local missing = tonumber(data.missingTiles) or 0
      local frontier = tonumber(data.frontierPixels) or tonumber(data.transparentPixels) or 0
      local complete
      if data.complete ~= nil then
        complete = (data.complete == true) and missing == 0 and frontier == 0
      else
        complete = missing == 0 and frontier == 0
      end
      local attempt = (existing and existing.retryCount or 0) + 1
      state.tiles[key] = {
        text = data.text,
        fg = data.fg,
        bg = data.bg,
        complete = complete,
        missingTiles = missing,
        frontierPixels = frontier,
        totalTiles = tonumber(data.totalTiles) or 0,
        retryCount = complete and 0 or attempt,
        nextRetryAt = complete and nil or (now + retryDelay(missing, frontier, attempt)),
        lastFetchAt = now,
      }
      state.hasMap = true
      return true
    end
    if existing and existing.complete == false then
      local attempt = (existing.retryCount or 0) + 1
      existing.retryCount = attempt
      existing.nextRetryAt = now + retryDelay(existing.missingTiles, existing.frontierPixels, attempt)
      existing.lastFetchAt = now
    end
    if data and data.error then state.lastError = data.error
    elseif err then state.lastError = err end
    return false
  end

  local function maybePreloadZoomCenter(mapH, mcx, mcz)
    local radius = math.floor(tonumber(env.zoomPreloadRadius) or 0)
    if radius <= 0 or not state.hasMap then return end
    if state.zoomLoadingCenter or state.isDragging then return end
    if state.zoomSettledAt and os.clock() < state.zoomSettledAt then return end

    local centerKey = frameCenterKey(state.bpp, state.lod, mapH, mcx, mcz)
    if state.zoomPreloadCenterKey ~= centerKey then
      state.zoomPreloadCenterKey = centerKey
      state.zoomPreloadRetryAt = {}
    else
      state.zoomPreloadRetryAt = state.zoomPreloadRetryAt or {}
    end
    local now = os.clock()
    for dist = 1, radius do
      for _, dir in ipairs({-1, 1}) do
        local fetchBpp = dir < 0 and clampedBpp(state.bpp / (2 ^ dist))
                         or clampedBpp(state.bpp * (2 ^ dist))
        if fetchBpp ~= state.bpp then
          local fetchLod = env.pickLod(fetchBpp)
          local key = frameCenterKey(fetchBpp, fetchLod, mapH, mcx, mcz)
          local hasPreload = state.preloadedZoomTiles and state.preloadedZoomTiles[key]
          if not hasPreload and (state.zoomPreloadRetryAt[key] or 0) <= now then
            local data = fetchFrameData(mcx, mcz, fetchBpp, fetchLod)
            if data and data.text then
              rememberPreloadedFrame(key, data)
            else
              state.zoomPreloadRetryAt[key] = now + PRELOAD_RETRY_S
            end
            return
          end
        end
      end
    end
  end

  local function mapTick()
    maybeFetchSidecar()
    if not env.isPocket then
      local x, y, z = gps.locate(0.5)
      if not x then env.drawError("No GPS lock"); return end
      state.lastPos = { x = x, y = y or 0, z = z }
    end
    if not state.lastPos then
      env.drawError(state.shipId and "Waiting for ship state..." or "Looking for ship...")
      return
    end

    local mapH = env.mapHeight()
    local mcx, mcz = env.mapCenter()
    if state.tileBpp ~= state.bpp or state.tileLod ~= state.lod
       or state.tileW ~= env.width() or state.tileH ~= mapH then
      state.tiles = {}
      state.hasMap = false
      state.tileBpp = state.bpp
      state.tileLod = state.lod
      state.tileW = env.width()
      state.tileH = mapH
      state.tileOriginX = mcx
      state.tileOriginZ = mcz
    end

    local ci, cj = env.tileIndexForWorld(mcx, mcz, mapH)
    local now = os.clock()
    local frontierRetry = (state.heightMissingTiles or 0) > 0

    for k in pairs(state.tiles) do
      local si, sj = k:match("(-?%d+),(-?%d+)")
      si, sj = tonumber(si), tonumber(sj)
      if not si or math.abs(si - ci) > 2 or math.abs(sj - cj) > 2 then
        state.tiles[k] = nil
      end
    end

    local fetchBpp, fetchLod = state.bpp, state.lod
    local function shouldRetryTile(ti, tj)
      local tile = state.tiles[env.tileKey(ti, tj)]
      return tile and tile.complete == false and (tile.nextRetryAt or 0) <= now
    end
    local function tileNeedsAttention(ti, tj)
      local tile = state.tiles[env.tileKey(ti, tj)]
      return not tile or shouldRetryTile(ti, tj)
    end

    if tileNeedsAttention(ci, cj) then
      local centerLoaded = fetchTile(ci, cj, fetchBpp, fetchLod, mapH)
      if centerLoaded then
        state.zoomLoadingCenter = false
        state.loadingFallback = nil
        state.loadingOverlayAt = nil
        state.lastError = nil
      end
      if state.hasMap then env.fullRedraw() end
    end

    local zoomSettling = state.zoomSettledAt and os.clock() < state.zoomSettledAt
    if not zoomSettling then
      local neighborBatches = {
        {{-1, 0}, {1, 0}},
        {{0, -1}, {0, 1}},
        {{-1, -1}, {1, 1}},
        {{1, -1}, {-1, 1}},
      }
      for _, batch in ipairs(neighborBatches) do
        local fetchers = {}
        for _, off in ipairs(batch) do
          local ti, tj = ci + off[1], cj + off[2]
          if tileNeedsAttention(ti, tj) then
            local cti, ctj = ti, tj
            table.insert(fetchers, function() fetchTile(cti, ctj, fetchBpp, fetchLod, mapH) end)
          end
        end
        if #fetchers > 0 then
          parallel.waitForAll(table.unpack(fetchers))
          if state.hasMap then env.fullRedraw() end
        end
      end
    end

    state.frontierMode = frontierRetry
    if state.hasMap then
      state.status = "ok"
      env.fullRedraw()
      maybePreloadZoomCenter(mapH, mcx, mcz)
    elseif state.zoomLoadingCenter and state.loadingFallback then
      env.fullRedraw()
    else
      env.drawError(state.lastError or "Loading map...")
    end
  end

  return {
    mapTick = mapTick,
  }
end

return M
