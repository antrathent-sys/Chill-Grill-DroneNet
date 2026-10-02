--- navkiosk: the CINDER NAV registration kiosk's logic (AVIONICS.md). A
-- player registers their own vehicle (Alex, 2026-10-02): they sit in the
-- kiosk's seat, which names them, put their unit's computer in the drive, and
-- the touch screen (lib/kioskui.lua) takes them through vehicle type, callsign
-- and confirm. The master tower runs it beside everything else, so the keys
-- never leave the tower.
--
--   local k = K.new(io)
--   k:tick()        every half second: the seat and the drive
--   k:touch(id)     a button from kioskui's hits
--   k.view          what kioskui draws
--
-- io, supplied by the tower:
--   seated() -> name | nil      who is in the seat (lib/nav.lua N.seatName)
--   drive() -> info | nil       what is in the drive (N.inspect), nil when empty
--   eject()
--   find(unit) -> rec | nil     a registry record by unit id
--   count(owner) -> n           live registrations in that player's name
--   nextReg() -> "CR-0012"      what a new unit would be
--   validCall(s) -> call | nil
--   register(owner, kind, call) -> rec | nil, why
--   refresh(unit, kind, call) -> rec | nil, why     kind/call nil: unchanged
--   now() -> seconds
-- Pure apart from io; tools/test_nav.lua drives it with a fake.

local K = {}

K.MAX_PER_OWNER = 5     -- registrations a player can make for themselves; more at the tower
K.IDLE = 90             -- s without a touch part-way through: back to the start
K.SEAT_GRACE = 3        -- s the seat may read empty before the session ends
K.DONE_SHOW = 30        -- s the result stays up
K.CALL_MAX = 16

function K.new(io)
  local k = setmetatable({ io = io, view = { state = "attract", n = 0 }, touched = 0 }, { __index = K })
  return k
end

local function lower(s) return tostring(s or ""):lower() end

function K:go(state, extra)
  local who = self.view.who
  self.view = { state = state, who = who, n = self.view.n }
  for key, v in pairs(extra or {}) do self.view[key] = v end
  self.touched = self.io.now()
  return true
end

-- what is in the drive, for someone seated: a new unit to make, one of
-- theirs, or a reason not to touch it
function K:lookAtDrive()
  local v, io = self.view, self.io
  local info = io.drive()
  if not info then v.drive = nil return false end
  if info.kind == "unit" and info.me then
    local rec = io.find(info.me.unit)
    if rec and not rec.revoked then
      if lower(rec.owner) == lower(v.who) then
        return self:go("mine", { unit = { id = rec.unit, reg = rec.reg, call = rec.call, kind = rec.kind } })
      end
      v.drive = "theirs"
      return false
    end
    info = { kind = "blank" }       -- revoked or unknown here: made afresh
  end
  if info.kind == "blank" then
    if io.count(v.who) >= K.MAX_PER_OWNER then
      return self:go("error", { msg = { "YOU HAVE " .. K.MAX_PER_OWNER .. " UNITS REGISTERED",
                                        "A CINDER OPERATOR CAN REGISTER MORE" } })
    end
    return self:go("type", { mode = "new" })
  end
  v.drive = info.kind               -- dev, pass, other
  return false
end

--- The seat and the drive. True when the screen should be drawn again.
function K:tick()
  local v, io = self.view, self.io
  local now = io.now()
  v.n = (v.n or 0) + 1
  local who = io.seated()
  if not who then
    if v.state == "attract" then return false end
    self.emptySince = self.emptySince or now
    if now - self.emptySince > K.SEAT_GRACE then
      self.emptySince = nil
      self.view = { state = "attract", n = v.n }
      return true
    end
    return false
  end
  self.emptySince = nil
  if v.state == "attract" or lower(who) ~= lower(v.who) then
    self.view = { state = "hello", who = who, n = v.n }
    self.touched = now
    return self:lookAtDrive() or true
  end
  if v.state == "hello" then return self:lookAtDrive() or true end
  if v.state == "type" or v.state == "callsign" or v.state == "confirm" or v.state == "mine" then
    if not io.drive() or now - self.touched > K.IDLE then return self:go("hello") end
  end
  if (v.state == "done" or v.state == "error") and now - self.touched > K.DONE_SHOW then return self:touch("done") end
  return v.state == "hello"
end

--- A button. True when the screen should be drawn again.
function K:touch(id)
  local v, io = self.view, self.io
  if not id then return false end
  self.touched = io.now()
  local s = v.state
  if s == "hello" then
    if id == "cancel" then io.eject() return self:go("hello") end
  elseif s == "mine" then
    if id == "cancel" then io.eject() return self:go("hello") end
    if id == "update" then
      self:go("working", { frac = 0.5 })
      local rec, why = io.refresh(v.unit.id)
      if not rec then return self:go("error", { msg = { "COULD NOT UPDATE IT", tostring(why) } }) end
      return self:go("done", { reg = rec.reg, call = rec.call, updated = true })
    end
    if id == "change" then
      return self:go("type", { mode = "change", unit = v.unit, kind = v.unit.kind, call = v.unit.call })
    end
  elseif s == "type" then
    if id == "back" then
      if v.mode == "change" then return self:go("mine", { unit = v.unit }) end
      return self:go("hello")
    end
    local kind = id:match("^kind:(%a+)$")
    if kind then
      v.kind = kind
      v.call = v.call or ""
      v.state = "callsign"
      return true
    end
  elseif s == "callsign" then
    local ch = id:match("^key:(.)$")
    if ch then
      if #v.call < K.CALL_MAX and not (ch == " " and (v.call == "" or v.call:sub(-1) == " ")) then
        v.call = v.call .. ch
      end
      return true
    end
    if id == "del" then v.call = v.call:sub(1, -2) return true end
    if id == "back" then v.state = "type" return true end
    if id == "next" then
      local call = io.validCall(v.call)
      if not call then return false end
      v.call = call
      v.reg = v.mode == "change" and v.unit.reg or io.nextReg()
      v.state = "confirm"
      return true
    end
  elseif s == "confirm" then
    if id == "back" then v.state = "callsign" return true end
    if id == "register" then
      local kind, call, mode, unit = v.kind, v.call, v.mode, v.unit
      self:go("working", { frac = 0.5 })
      local rec, why
      if mode == "change" then rec, why = io.refresh(unit.id, kind, call)
      else rec, why = io.register(self.view.who, kind, call) end
      if not rec then return self:go("error", { msg = { "COULD NOT WRITE YOUR UNIT", tostring(why) } }) end
      return self:go("done", { reg = rec.reg, call = rec.call })
    end
  elseif s == "done" or s == "error" then
    if id == "done" then
      if s == "done" then io.eject() end
      return self:go("hello")
    end
  end
  return false
end

return K
