--- navkiosk: the CINDER NAV registration kiosk's logic (AVIONICS.md). A
-- player registers their own vehicle and walks away with its kit (Alex,
-- 2026-10-02): they sit in the kiosk's seat, which names them, choose the
-- vehicle type and a callsign on the touch screen (lib/kioskui.lua), and the
-- kiosk takes a computer from its stock, writes the unit onto it, and puts it
-- in the chest beside them with two monitors and an ender modem. Their own
-- unit put in the drive can be updated or changed. The same kiosk takes
-- applications to host a traffic centre. The master tower runs it, so no key
-- ever leaves the tower.
--
--   local k = K.new(io)
--   k:tick()        every half second: the seat and the drive
--   k:touch(id)     a button from kioskui's hits
--   k.view          what kioskui draws
--
-- io, supplied by the tower:
--   seated() -> name | nil           who is in the seat (N.seatName)
--   drive() -> info | nil            what is in the drive (N.inspect), nil when empty
--   eject()                          the drive's contents to the chest (or out)
--   find(unit) -> rec | nil          a registry record by unit id, with .reg
--   count(owner) -> n                live registrations in that player's name
--   nextReg() -> "CR-0012"
--   stock() -> n | nil               complete kits in stock; nil: no stock fitted
--   callFree(call, exceptUnit) -> call | nil, why
--   kit(owner, kind, call) -> rec | nil, why       register a unit from stock, hand the kit over
--   refresh(unit, kind, call) -> rec | nil, why    the unit in the drive; kind/call nil: unchanged
--   validCentre(name) -> name | nil
--   apply(owner, name, x, z) -> true | nil, why    an application to host a traffic centre
--   now() -> seconds
-- Pure apart from io; tools/test_nav.lua drives it with a fake.

local K = {}

K.MAX_PER_OWNER = 5     -- units a player can register themselves; more at the tower
K.IDLE = 90             -- s without a touch part-way through: back to the start
K.SEAT_GRACE = 3        -- s the seat may read empty before the session ends
K.DONE_SHOW = 30        -- s the result stays up
K.CALL_MAX = 16
K.TEXT = { callsign = { field = "call", max = 16 }, appname = { field = "text", max = 12 },
           appwhere = { field = "text", max = 15 } }

function K.new(io)
  return setmetatable({ io = io, view = { state = "attract", n = 0 }, touched = 0 }, { __index = K })
end

local function lower(s) return tostring(s or ""):lower() end

function K:go(state, extra)
  self.view = { state = state, who = self.view.who, n = self.view.n }
  for key, v in pairs(extra or {}) do self.view[key] = v end
  self.touched = self.io.now()
  return true
end

-- the welcome: kits in stock, and whatever is in the drive
function K:hello()
  local v, io = self.view, self.io
  v.stock = io.stock()
  local info = io.drive()
  v.drive = nil
  if not info then return end
  if info.kind == "unit" and info.me then
    local rec = io.find(info.me.unit)
    if rec and not rec.revoked then
      if lower(rec.owner) == lower(v.who) then
        return self:go("mine", { unit = { id = rec.unit, reg = rec.reg, call = rec.call, kind = rec.kind } })
      end
      v.drive = "theirs"
      return
    end
    v.drive = "other"
    return
  end
  v.drive = info.kind == "blank" and "other" or info.kind     -- dev, pass, other
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
  end
  if self.view.state == "hello" then self:hello() return true end
  if v.state ~= "done" and v.state ~= "error" and v.state ~= "appdone" and v.state ~= "working"
     and now - self.touched > K.IDLE then
    return self:go("hello")
  end
  if v.state == "mine" and not io.drive() then return self:go("hello") end
  if (v.state == "done" or v.state == "error" or v.state == "appdone") and now - self.touched > K.DONE_SHOW then
    return self:touch("done")
  end
  return false
end

-- typing on the screen's keyboard, into the field the state types into
function K:typing(id)
  local v = self.view
  local t = K.TEXT[v.state]
  local text = v[t.field] or ""
  local ch = id:match("^key:(.)$")
  if ch then
    if #text < t.max and not (ch == " " and (text == "" or text:sub(-1) == " ")) then text = text .. ch end
  elseif id == "del" then
    text = text:sub(1, -2)
  else
    return false
  end
  v[t.field], v.note = text, nil
  return true
end

--- A button. True when the screen should be drawn again.
function K:touch(id)
  local v, io = self.view, self.io
  if not id then return false end
  self.touched = io.now()
  local s = v.state
  if K.TEXT[s] and self:typing(id) then return true end
  if s == "hello" then
    if id == "register" then
      if io.count(v.who) >= K.MAX_PER_OWNER then
        return self:go("error", { msg = { "YOU HAVE " .. K.MAX_PER_OWNER .. " UNITS REGISTERED",
                                          "A CINDER OPERATOR CAN REGISTER MORE" } })
      end
      local stock, whyNot = io.stock()
      if not stock then
        return self:go("error", { msg = { "THIS KIOSK IS NOT SET UP", tostring(whyNot or "") } })
      end
      if stock < 1 then
        return self:go("error", { msg = { "KITS ARE OUT OF STOCK", "CINDER HAS BEEN TOLD - PLEASE COME BACK LATER" } })
      end
      if io.drive() then
        return self:go("error", { msg = { "TAKE YOUR COMPUTER OUT OF THE DRIVE", "THE KIT COMES WITH ONE" } })
      end
      return self:go("type", { mode = "new" })
    end
    if id == "apply" then return self:go("appname", { text = "" }) end
  elseif s == "mine" then
    if id == "cancel" then io.eject() return self:go("hello") end
    if id == "update" then
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
      v.kind, v.call, v.state = kind, v.call or "", "callsign"
      return true
    end
  elseif s == "callsign" then
    if id == "back" then v.state = "type" return true end
    if id == "next" then
      local call, why = io.callFree(v.call, v.mode == "change" and v.unit.id or nil)
      if not call then v.note = why return true end
      v.call = call
      v.reg = v.mode == "change" and v.unit.reg or io.nextReg()
      v.state = "confirm"
      return true
    end
  elseif s == "confirm" then
    if id == "back" then v.state = "callsign" return true end
    if id == "register" then
      local kind, call, mode, unit = v.kind, v.call, v.mode, v.unit
      local rec, why
      if mode == "change" then rec, why = io.refresh(unit.id, kind, call)
      else rec, why = io.kit(v.who, kind, call) end
      if not rec then return self:go("error", { msg = { "COULD NOT MAKE YOUR UNIT", tostring(why) } }) end
      return self:go("done", { reg = rec.reg, call = rec.call, kit = mode ~= "change", updated = mode == "change" })
    end
  elseif s == "appname" then
    if id == "back" then return self:go("hello") end
    if id == "next" then
      local name = io.validCentre(v.text)
      if not name then v.note = "2 TO 12 LETTERS, DIGITS OR DASHES" return true end
      return self:go("appwhere", { appName = name, text = "" })
    end
  elseif s == "appwhere" then
    if id == "back" then return self:go("appname", { text = v.appName }) end
    if id == "next" then
      local x, z = tostring(v.text):match("^(%-?%d+) (%-?%d+)$")
      if not x then v.note = "X, A SPACE, THEN Z" return true end
      return self:go("appconfirm", { appName = v.appName, x = tonumber(x), z = tonumber(z) })
    end
  elseif s == "appconfirm" then
    if id == "back" then return self:go("appwhere", { appName = v.appName, text = v.x .. " " .. v.z }) end
    if id == "send" then
      local ok, why = io.apply(v.who, v.appName, v.x, v.z)
      if not ok then return self:go("error", { msg = { "APPLICATION NOT SENT", tostring(why) } }) end
      return self:go("appdone", { appName = v.appName })
    end
  elseif s == "done" or s == "error" or s == "appdone" then
    if id == "done" then return self:go("hello") end
  end
  return false
end

return K
