-- sha256.lua: pure-Lua SHA-256 (FIPS 180-4). Uses bit32 and string.byte/char
-- only, so it works on the Cobalt Lua that CC:Tweaked ships. A typical
-- password hashes in well under a millisecond; no caching needed at call
-- sites.
--
-- Used by [[ccminimap]] to hash the control password before writing it to
-- the ship's disk. Same hash on disk works for the future challenge-response
-- upgrade (authVersion=2), so the migration to v2 won't require re-pairing.

local band, bor, bxor, bnot = bit32.band, bit32.bor, bit32.bxor, bit32.bnot
local rrotate, lshift, rshift = bit32.rrotate, bit32.lshift, bit32.rshift

local K = {
  0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
  0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
  0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
  0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
  0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
  0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
  0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
  0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
}

local function be32(s, i)
  local b1, b2, b3, b4 = s:byte(i, i + 3)
  return bor(lshift(b1, 24), lshift(b2, 16), lshift(b3, 8), b4)
end

local function chr32(v)
  return string.char(
    band(rshift(v, 24), 0xFF),
    band(rshift(v, 16), 0xFF),
    band(rshift(v, 8), 0xFF),
    band(v, 0xFF))
end

local function hash(msg)
  local bitlen = #msg * 8
  msg = msg .. "\128"
  while (#msg % 64) ~= 56 do msg = msg .. "\0" end
  -- 64-bit big-endian length suffix; password-sized inputs fit in 32 bits
  -- so the high word is always 0.
  msg = msg .. "\0\0\0\0" .. chr32(bitlen)

  local h0, h1, h2, h3 = 0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a
  local h4, h5, h6, h7 = 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19

  for chunk = 1, #msg, 64 do
    local w = {}
    for i = 0, 15 do w[i + 1] = be32(msg, chunk + i * 4) end
    for i = 17, 64 do
      local x = w[i - 15]
      local y = w[i - 2]
      local s0 = bxor(rrotate(x, 7), rrotate(x, 18), rshift(x, 3))
      local s1 = bxor(rrotate(y, 17), rrotate(y, 19), rshift(y, 10))
      w[i] = band(w[i - 16] + s0 + w[i - 7] + s1, 0xFFFFFFFF)
    end

    local a, b, c, d, e, f, g, h = h0, h1, h2, h3, h4, h5, h6, h7
    for i = 1, 64 do
      local S1 = bxor(rrotate(e, 6), rrotate(e, 11), rrotate(e, 25))
      local ch = bxor(band(e, f), band(bnot(e), g))
      local t1 = h + S1 + ch + K[i] + w[i]
      local S0 = bxor(rrotate(a, 2), rrotate(a, 13), rrotate(a, 22))
      local mj = bxor(band(a, b), band(a, c), band(b, c))
      local t2 = S0 + mj
      h = g; g = f; f = e
      e = band(d + t1, 0xFFFFFFFF)
      d = c; c = b; b = a
      a = band(t1 + t2, 0xFFFFFFFF)
    end

    h0 = band(h0 + a, 0xFFFFFFFF); h1 = band(h1 + b, 0xFFFFFFFF)
    h2 = band(h2 + c, 0xFFFFFFFF); h3 = band(h3 + d, 0xFFFFFFFF)
    h4 = band(h4 + e, 0xFFFFFFFF); h5 = band(h5 + f, 0xFFFFFFFF)
    h6 = band(h6 + g, 0xFFFFFFFF); h7 = band(h7 + h, 0xFFFFFFFF)
  end

  return string.format("%08x%08x%08x%08x%08x%08x%08x%08x",
    h0, h1, h2, h3, h4, h5, h6, h7)
end

return { hash = hash }
