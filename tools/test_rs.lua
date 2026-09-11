local DIR = ...
local pass, fail = 0, 0
local function check(n, c, d)
  if c then pass = pass + 1 print("  ok   " .. n)
  else fail = fail + 1 print("  FAIL " .. n .. (d and ("  " .. tostring(d)) or "")) end
end

-- ---------- stubs ----------
local sides = { "top", "bottom", "left", "right", "front", "back" }
local out, relayOut = {}, {}
_G.redstone = {
  setOutput = function(s, on) out[s] = on and true or false end,
  getOutput = function(s) return out[s] or false end,
  getSides = function() return sides end,
}
local modems = { wired_modem_0 = false, wireless_modem_1 = true }   -- name -> isWireless
_G.peripheral = {
  getNames = function()
    local t = {} for k in pairs(modems) do t[#t + 1] = k end
    table.sort(t) t[#t + 1] = "redstone_relay_0" return t
  end,
  getType = function(n) return n == "redstone_relay_0" and "redstone_relay" or "modem" end,
  call = function(n, m, ...)
    if n == "redstone_relay_0" and m == "setOutput" then
      local side, on = ... relayOut[side] = on and true or false return true
    end
    if m == "isWireless" then return modems[n] end
    error("no such peripheral " .. tostring(n), 0)
  end,
}
local sent, openedOn = {}, nil
local inbox = {}
_G.rednet = {
  open = function(name) openedOn = name end,
  broadcast = function(msg, proto) sent[#sent + 1] = { msg = msg, proto = proto } end,
  receive = function(proto, timeout)
    local m = table.remove(inbox, 1)
    if not m then return nil end
    return 7, m, proto
  end,
}
local T = 100
os.clock = function() return T end

local rs = dofile(DIR .. "/../lib/rs.lua")

-- ---------- local sides ----------
print("a plain string is a side of this computer")
check("set high", rs.set("back", true) and out.back == true)
check("set low", rs.set("back", false) and out.back == false)
check("describe", rs.describe("back") == "local back", rs.describe("back"))

-- ---------- relay ----------
print("a relay target goes through peripheral.call")
check("relay high", rs.set({ relay = "redstone_relay_0", side = "back" }, true) and relayOut.back == true)
local ok, err = rs.set({ relay = "nope_0", side = "back" }, true)
check("missing relay reports, does not throw", ok == false and err:find("nope_0"), err)

-- ---------- slave ----------
print("a slave target is broadcast on the wired modem")
check("nothing sent yet", #sent == 0)
check("slave set returns ok", rs.set({ slave = "drone-rs", side = "back" }, true))
check("prefers the WIRED modem", openedOn == "wired_modem_0", openedOn)
check("one broadcast", #sent == 1 and sent[1].proto == "drone-rs", #sent)
check("carries side and state", sent[1].msg.side == "back" and sent[1].msg.on == true)
check("did not touch a local side", out.back == false)

print("an unheard slave is reported, not assumed good")
local bad = rs.check()
check("never reported", #bad == 1 and bad[1]:find("never"), bad[1])

print("a heartbeat clears it")
inbox[#inbox + 1] = { state = { back = true }, id = 7 }
rs.poll()
check("no complaints", #rs.check() == 0, rs.check()[1])

print("a slave holding the wrong state is caught")
inbox[#inbox + 1] = { state = { back = false }, id = 7 }
rs.poll()
bad = rs.check()
check("mismatch reported", #bad == 1 and bad[1]:find("wanted true"), bad[1])

print("a slave that goes quiet is caught")
inbox[#inbox + 1] = { state = { back = true }, id = 7 }
rs.poll()
check("clean while fresh", #rs.check() == 0)
T = T + rs.STALE + 1
bad = rs.check()
check("stale reported", #bad == 1 and bad[1]:find("silent"), bad[1])

-- ---------- clear ----------
print("clear drops everything except the docking connector")
out.top, out.left = true, true
rs.clear({ slave = "drone-rs", side = "back" })
check("local sides dropped", out.top == false and out.left == false)
check("clear broadcast with the exception", sent[#sent].msg.cmd == "clear" and sent[#sent].msg.except == "back")
out.top, out.bottom = true, true
rs.clear("bottom")
check("local keep is honoured", out.top == false and out.bottom == true)

print("")
print(string.format("%d passed, %d failed", pass, fail))
if fail > 0 then error("test failures", 0) end
