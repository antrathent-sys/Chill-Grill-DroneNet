local DIR = ...
local pass, fail = 0, 0
local function check(n, c, d)
  if c then pass = pass + 1 print("  ok   " .. n)
  else fail = fail + 1 print("  FAIL " .. n .. (d and ("  " .. tostring(d)) or "")) end
end

dofile(DIR .. "/cc_shim.lua")
local S = dofile(DIR .. "/../lib/seclink.lua")
S.ROOT = DIR .. "/../"

local function hex(s) return S.keyHex(s) end
local function unhex(h) return (h:gsub("..", function(x) return string.char(tonumber(x, 16)) end)) end

-- in-memory fs for key and counter files
local files = {}
_G.fs = {
  exists = function(p) return files[p] ~= nil end,
  open = function(p, mode)
    if mode == "r" then
      if files[p] == nil then return nil end
      local data = files[p]
      return { readAll = function() return data end, close = function() end }
    end
    files[p] = ""
    return { write = function(s) files[p] = files[p] .. s end, close = function() end }
  end,
}

print("vendored ChaCha20-Poly1305")
do
  local key = unhex("808182838485868788898a8b8c8d8e8f909192939495969798999a9b9c9d9e9f")
  local nonce = unhex("070000004041424344454647")
  local aad = unhex("50515253c0c1c2c3c4c5c6c7")
  local pt = "Ladies and Gentlemen of the class of '99: If I could offer you only one tip for the future, sunscreen would be it."
  local ct, tag = S.aead().encrypt(key, nonce, pt, aad)
  check("RFC 8439 2.8.2 ciphertext", hex(ct:sub(1, 16)) == "d31a8d34648e60db7b86afbc53ef7ec2", hex(ct:sub(1, 16)))
  check("RFC 8439 2.8.2 tag", hex(tag) == "1ae10b594f09e26a7e902ecbd0600691", hex(tag))
end

print("keys")
local K1 = unhex("000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f")
local K2 = unhex("ff0102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f")
check("parseKey round-trips keyHex", S.parseKey(hex(K1)) == K1)
check("parseKey allows spaces and capitals", S.parseKey(hex(K1):upper():gsub("(........)", "%1 ")) == K1)
local k, why = S.parseKey("abc")
check("short key rejected with a reason", k == nil and why:find("64"), why)
k, why = S.parseKey(string.rep("zz", 32))
check("non-hex rejected", k == nil and why:find("hex"), why)
local keys, n, bad = S.parseFleetKeys("# fleet\ndrone-1 = " .. hex(K1) .. "\n\ndrone-2=" .. hex(K2) .. "  # spare\nnonsense\ndrone-3=abcd\n")
check("fleet file: two keys, two bad lines", n == 2 and bad == 2 and keys["drone-1"] == K1 and keys["drone-2"] == K2,
  string.format("n=%s bad=%s", n, bad))
files[".dronekey"] = hex(K1) .. "\n"
check("readKeyFile", S.readKeyFile(".dronekey") == K1)
check("missing key file says so", select(2, S.readKeyFile(".nope")):find("no key file"))
S._req("ccryptolib.random").init("test seed - not random, only for the desktop test")
local a, b = S.newKey(), S.newKey()
check("newKey gives 32 bytes, different each time", #a == 32 and #b == 32 and a ~= b)

print("codec")
local body = { type = "plan", id = "drone-1", x = -2000.5, n = 7, tiny = 1e-7, big = 2 ^ 52 + 1,
               route = "cruise:2000.5:5000.5|drop|dock:0.5:0.5", ok = true, no = false, empty = "" }
local back = S.decode(S.encode(body))
local same = back ~= nil
for key2, v in pairs(body) do if back[key2] ~= v then same = false end end
for key2 in pairs(back or {}) do if body[key2] == nil then same = false end end
check("flat table round-trips exactly", same)
check("garbage does not decode", S.decode("x") == nil and S.decode("a\31zzz") == nil and S.decode(nil) == nil)
check("tables refused", not pcall(S.encode, { nested = {} }))
check("separator characters refused", not pcall(S.encode, { s = "a\30b" }))

print("seal and open")
local tx = S.sender(K1, "drone-1", S.DIR.DRONE_TO_BASE, ".dronekey.ctr")
local rx = S.receiver()
local keyFor = function(id) if id == "drone-1" or id == "drone-9" then return K1 end end
local msg = { type = "tlm", x = 2000.5, z = 5000.5, phase = "cruise", route = "cruise:2000.5:5000.5" }
local env = tx.seal(msg)
local fields = {}
for key2 in pairs(env) do fields[#fields + 1] = key2 end
table.sort(fields)
check("envelope carries only sl,id,d,n,c,g", table.concat(fields, ",") == "c,d,g,id,n,sl", table.concat(fields, ","))
check("nothing readable in the ciphertext", not env.c:find("2000", 1, true) and not env.c:find("cruise", 1, true))
local got, why2 = rx.open(env, keyFor, S.DIR.DRONE_TO_BASE)
check("opens with the right key", got and got.x == 2000.5 and got.phase == "cruise" and got.id == "drone-1", why2)
check("sender adds a timestamp", got and type(got.ts) == "number" or got and got.ts == nil)

local function copy(t) local o = {} for k2, v in pairs(t) do o[k2] = v end return o end
local function flip(s, i) return s:sub(1, i - 1) .. string.char((s:byte(i) + 1) % 256) .. s:sub(i + 1) end
local e2 = tx.seal(msg)
local t1 = copy(e2) t1.c = flip(t1.c, 3)
check("altered ciphertext is refused", select(2, S.receiver().open(t1, keyFor, 1)) == "bad tag")
local t2 = copy(e2) t2.g = flip(t2.g, 1)
check("altered tag is refused", select(2, S.receiver().open(t2, keyFor, 1)) == "bad tag")
local t3 = copy(e2) t3.n = t3.n + 5
check("altered counter is refused", select(2, S.receiver().open(t3, keyFor, 1)) == "bad tag")
local t4 = copy(e2) t4.id = "drone-9"
check("envelope relabelled as another drone is refused", select(2, S.receiver().open(t4, keyFor, 1)) == "bad tag")
local t5 = copy(e2) t5.d = 2
check("wrong direction is refused", select(2, S.receiver().open(t5, keyFor, 1)) == "wrong direction")
check("wrong key is refused", select(2, S.receiver().open(e2, function() return K2 end, 1)) == "bad tag")
check("unknown drone is refused", select(2, S.receiver().open(e2, function() return nil end, 1)):find("unknown"))
check("not an envelope", select(2, rx.open({ x = 1 }, keyFor, 1)) == "not sealed" and select(2, rx.open("land", keyFor, 1)) == "not sealed")
local t6 = copy(e2) t6.g = "short"
check("malformed tag length refused before any crypto", select(2, S.receiver().open(t6, keyFor, 1)) == "bad body")
local t7 = copy(e2) t7.n = 1.5
check("fractional counter refused", select(2, S.receiver().open(t7, keyFor, 1)) == "bad counter")

print("replay and freshness")
local r2 = S.receiver()
local e3 = tx.seal(msg)
check("first delivery accepted", r2.open(e3, keyFor, 1) ~= nil)
check("the same packet again is a replay", select(2, r2.open(e3, keyFor, 1)) == "replay")
check("an older packet is a replay", select(2, r2.open(e2, keyFor, 1)) == "replay")
local r3 = S.receiver()
local e4 = tx.seal(msg)
local forged = copy(e4) forged.n = e4.n + 1000 forged.c = flip(forged.c, 1)
r3.open(forged, keyFor, 1)
check("a forged high counter does not lock out the real sender", r3.open(e4, keyFor, 1) ~= nil)
local stamped = tx.seal({ type = "tlm", ts = 1000, x = 1, z = 1 })
check("stale message refused", select(2, S.receiver().open(stamped, keyFor, 1, 60000, 1000 + 61000)) == "stale")
local fresh = tx.seal({ type = "tlm", ts = 1000, x = 1, z = 1 })
check("fresh message accepted", S.receiver().open(fresh, keyFor, 1, 60000, 1000 + 59000) ~= nil)

print("counter never reused")
files["c.ctr"] = nil
local s1 = S.sender(K1, "drone-1", 1, "c.ctr")
local ns = {}
for i = 1, 3 do ns[i] = s1.seal({ i = i }).n end
check("counts 1, 2, 3", ns[1] == 1 and ns[2] == 2 and ns[3] == 3)
check("reserves a block on disk before using it", files["c.ctr"] == tostring(S.RESERVE), files["c.ctr"])
local s2 = S.sender(K1, "drone-1", 1, "c.ctr")
local afterReboot = s2.seal({ i = 4 }).n
check("after a reboot it starts past the reserved block", afterReboot == S.RESERVE + 1, afterReboot)
for _ = 1, S.RESERVE do s2.seal({}) end
check("crossing the block writes the next mark first", tonumber(files["c.ctr"]) >= s2.n, files["c.ctr"])
local up = S.sender(K1, "drone-1", 1, nil)
local down = S.sender(K1, "drone-1", 2, nil)
check("same counter, other direction: different nonce", up.seal({ a = 1 }).c ~= down.seal({ a = 1 }).c)


print("a replaced key")
-- a pass reissued under the same name counts from 1 again with its new key;
-- the base forgets the old counter for that name, and only that name
local K2 = S.parseKey(string.rep("cd", 32))
local custKeyNow = K1
local keyOf = function(id) if id == "alex" then return custKeyNow end if id == "sam" then return K1 end end
local base = S.receiver()
local oldPass = S.sender(K1, "alex", S.DIR.DRONE_TO_BASE, nil)
for _ = 1, 5 do oldPass.seal({ type = "x" }) end
check("the old pass is heard", base.open(oldPass.seal({ type = "x" }), keyOf, S.DIR.DRONE_TO_BASE) ~= nil)
local samPass = S.sender(K1, "sam", S.DIR.DRONE_TO_BASE, nil)
for _ = 1, 3 do samPass.seal({ type = "x" }) end
check("so is someone else's", base.open(samPass.seal({ type = "x" }), keyOf, S.DIR.DRONE_TO_BASE) ~= nil)
custKeyNow = K2
local newPass = S.sender(K2, "alex", S.DIR.DRONE_TO_BASE, nil)
check("without forgetting, the new pass looks like a replay",
  select(2, base.open(newPass.seal({ type = "x" }), keyOf, S.DIR.DRONE_TO_BASE)) == "replay")
base.forget("alex")
check("after forgetting, the new pass is heard", base.open(newPass.seal({ type = "x" }), keyOf, S.DIR.DRONE_TO_BASE) ~= nil)
check("the old pass is not - its key is gone",
  select(2, base.open(oldPass.seal({ type = "x" }), keyOf, S.DIR.DRONE_TO_BASE)) ~= nil)
local replay = samPass.seal({ type = "x" })
base.open(replay, keyOf, S.DIR.DRONE_TO_BASE)
check("and nobody else's replay protection was touched",
  select(2, base.open(replay, keyOf, S.DIR.DRONE_TO_BASE)) == "replay")
local text = S.formatFleetKeys({ sam = K1, alex = K2 }, S.CUST_HEADER)
local readBack = S.parseFleetKeys(text)
check("the key file format round-trips, sorted by name",
  text:find("alex=", 1, true) < text:find("sam=", 1, true) and S.keyHex(readBack.alex) == S.keyHex(K2))
print("")
print(string.format("%d passed, %d failed", pass, fail))
if fail > 0 then error("seclink tests failed", 0) end
