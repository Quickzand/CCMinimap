-- altitude.lua: shared altitude PID for CCMinimap and Spruce.
--
-- Both projects fly the same Create Aeronautics drone family with the same
-- burner-level (0..15) actuator, and were running near-identical copies of
-- the PID code. This module is the single source of truth so a tuning
-- change or anti-windup fix in one place applies to both.
--
-- Usage:
--
--     local Altitude = dofile("altitude.lua")
--     local pid = { integral = 0, lastTick = nil }
--     ...
--     local desired, saturated = Altitude.tick(pid, currentY, vy, targetY, {
--       HOVER = HOVER_BURNER, MIN_BURNER = MIN_BURNER,
--       KP = LIFT_KP, KI = LIFT_KI, KD = LIFT_KD, I_MAX = 8,
--     })
--     Lift.commandLevel(desired)
--
-- The `pid` table is caller-owned so the integrator state survives across
-- mission switches (or, intentionally, can be reset with Altitude.reset).

local M = {}

local DEFAULTS = {
  HOVER      = 7,
  MIN_BURNER = 0,
  MAX_BURNER = 15,
  KP         = 0.4,
  KI         = 0.05,
  KD         = 1.2,
  I_MAX      = 8,
  DT_CLAMP   = 1.0,
}

-- One PID iteration. Mutates `pid.integral` and `pid.lastTick` in place.
-- Returns:
--   desired   integer burner level in [MIN_BURNER, MAX_BURNER]
--   saturated true when we're commanding MAX_BURNER, vy is nearly zero,
--             and still below target -- the airship has hit its physical
--             ceiling and the integrator can't help. Surface this in UI/logs.
function M.tick(pid, currentAlt, currentVy, targetAlt, gains)
  local g = gains or {}
  local HOVER      = g.HOVER      or DEFAULTS.HOVER
  local MIN_BURNER = g.MIN_BURNER or DEFAULTS.MIN_BURNER
  local MAX_BURNER = g.MAX_BURNER or DEFAULTS.MAX_BURNER
  local KP         = g.KP         or DEFAULTS.KP
  local KI         = g.KI         or DEFAULTS.KI
  local KD         = g.KD         or DEFAULTS.KD
  local I_MAX      = g.I_MAX      or DEFAULTS.I_MAX
  local vy = currentVy or 0

  local err = targetAlt - currentAlt
  local now = os.clock()
  local dt = pid.lastTick and math.min(math.max(0, now - pid.lastTick), DEFAULTS.DT_CLAMP) or 0
  pid.lastTick = now

  local integral = pid.integral or 0
  local raw = HOVER + KP * err + integral - KD * vy

  -- Anti-windup: only accumulate when doing so wouldn't push raw further
  -- into the clamp. Without this the integrator grows unbounded while
  -- saturated and then overshoots wildly when the error sign flips.
  local pushingUpIntoCeiling = (raw >= MAX_BURNER and err > 0)
  local pushingDownIntoFloor = (raw <= MIN_BURNER and err < 0)
  if dt > 0 and not pushingUpIntoCeiling and not pushingDownIntoFloor then
    integral = integral + KI * err * dt
    if integral >  I_MAX then integral =  I_MAX end
    if integral < -I_MAX then integral = -I_MAX end
  end
  pid.integral = integral

  if raw < MIN_BURNER then raw = MIN_BURNER end
  if raw > MAX_BURNER then raw = MAX_BURNER end
  local desired = math.floor(raw + 0.5)

  local saturated = (desired >= MAX_BURNER) and (math.abs(vy) < 0.05) and (err > 3)
  return desired, saturated
end

-- Drop integrator + tick timer. Call on mission change so the new
-- mission doesn't inherit stale integral from the previous one.
function M.reset(pid)
  pid.integral = 0
  pid.lastTick = nil
end

return M
