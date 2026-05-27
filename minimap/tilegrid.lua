local M = {}

function M.init(env)
  local state = env.state
  local monitor = env.monitor
  local width = env.width
  local mapCenter = env.mapCenter
  local decodeTextRow = env.decodeTextRow
  local SUB_W = env.subW
  local SUB_H = env.subH

  local EMPTY_PACKED = string.char(0x40)
  local EMPTY_FG = "f"
  local EMPTY_BG = "f"

  local api = {}

  function api.tileKey(i, j)
    return i .. "," .. j
  end

  function api.tileWorldDim(mapH, grid)
    local bpp = (grid and grid.bpp) or state.bpp
    local bX = bpp * SUB_W
    local bY = bpp * SUB_H
    local w = width()
    return w * bX, mapH * bY, bX, bY
  end

  -- Cells in tile (i, j) have centres at (origin + i*tileWB) + (c - width/2)*bX
  -- for c in [1, width]. Shift by half a cell so tile boundaries align with
  -- the half-cell-offset cell grid.
  function api.tileIndexForWorld(wx, wz, mapH, grid)
    local tileWB, tileHB, bX, bY = api.tileWorldDim(mapH, grid)
    local ox = (grid and grid.tileOriginX) or state.tileOriginX or 0
    local oz = (grid and grid.tileOriginZ) or state.tileOriginZ or 0
    return math.floor((wx - ox + (tileWB - bX) / 2) / tileWB),
           math.floor((wz - oz + (tileHB - bY) / 2) / tileHB)
  end

  function api.snapshot()
    if not state.hasMap then return nil end
    return {
      tiles = state.tiles,
      bpp = state.tileBpp or state.bpp,
      lod = state.tileLod or state.lod,
      tileW = state.tileW,
      tileH = state.tileH,
      tileOriginX = state.tileOriginX,
      tileOriginZ = state.tileOriginZ,
    }
  end

  -- Returns (packed_byte, fg_char, bg_char) for the cell at screen (col, row),
  -- or nil if the relevant tile isn't loaded yet.
  function api.getCell(col, row, mapH, mcx, mcz, grid)
    local bpp = (grid and grid.bpp) or state.bpp
    local tiles = (grid and grid.tiles) or state.tiles
    local bX = bpp * SUB_W
    local bY = bpp * SUB_H
    local w = width()
    local tileWB = w * bX
    local tileHB = mapH * bY
    local wx = mcx + (col - w / 2) * bX
    local wz = mcz + (row - mapH / 2) * bY
    local ox = (grid and grid.tileOriginX) or state.tileOriginX or 0
    local oz = (grid and grid.tileOriginZ) or state.tileOriginZ or 0
    local ti = math.floor((wx - ox + (tileWB - bX) / 2) / tileWB)
    local tj = math.floor((wz - oz + (tileHB - bY) / 2) / tileHB)
    local tile = tiles[api.tileKey(ti, tj)]
    if not tile then return nil end
    local tc = math.floor((wx - ox - ti * tileWB) / bX + w / 2 + 0.5)
    local tr = math.floor((wz - oz - tj * tileHB) / bY + mapH / 2 + 0.5)
    local row_text = tile.text[tr]
    if not row_text or tc < 1 or tc > #row_text then return nil end
    return string.byte(row_text, tc), tile.fg[tr]:sub(tc, tc), tile.bg[tr]:sub(tc, tc)
  end

  function api.drawCachedMap(mapH, grid)
    if not state.lastPos then return end
    if grid then
      if not grid.tiles then return end
    elseif not state.hasMap then
      return
    end
    local mcx, mcz = mapCenter()
    local bpp = (grid and grid.bpp) or state.bpp
    local tiles = (grid and grid.tiles) or state.tiles
    local bX = bpp * SUB_W
    local bY = bpp * SUB_H
    local w = width()
    local tileWB = w * bX
    local tileHB = mapH * bY
    local halfDxX = (tileWB - bX) / 2
    local halfDxY = (tileHB - bY) / 2
    local ox = (grid and grid.tileOriginX) or state.tileOriginX or 0
    local oz = (grid and grid.tileOriginZ) or state.tileOriginZ or 0
    for r = 1, mapH do
      local wz = mcz + (r - mapH / 2) * bY
      local tj = math.floor((wz - oz + halfDxY) / tileHB)
      local tr = math.floor((wz - oz - tj * tileHB) / bY + mapH / 2 + 0.5)
      local textRow, fgRow, bgRow = {}, {}, {}
      for c = 1, w do
        local wx = mcx + (c - w / 2) * bX
        local ti = math.floor((wx - ox + halfDxX) / tileWB)
        local tile = tiles[api.tileKey(ti, tj)]
        local row_text = tile and tile.text[tr]
        if row_text then
          local tc = math.floor((wx - ox - ti * tileWB) / bX + w / 2 + 0.5)
          if tc >= 1 and tc <= #row_text then
            textRow[c] = row_text:sub(tc, tc)
            fgRow[c] = tile.fg[tr]:sub(tc, tc)
            bgRow[c] = tile.bg[tr]:sub(tc, tc)
          else
            textRow[c], fgRow[c], bgRow[c] = EMPTY_PACKED, EMPTY_FG, EMPTY_BG
          end
        else
          textRow[c], fgRow[c], bgRow[c] = EMPTY_PACKED, EMPTY_FG, EMPTY_BG
        end
      end
      monitor.setCursorPos(1, r)
      monitor.blit(decodeTextRow(table.concat(textRow)),
                   table.concat(fgRow), table.concat(bgRow))
    end
  end

  return api
end

return M
