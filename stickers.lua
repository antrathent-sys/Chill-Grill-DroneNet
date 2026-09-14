-- stickers: find the Create Stickers this computer can reach and show what CC
-- can do with them. Nothing moves unless you name a sticker and answer y.
--
--   stickers                 list them: extended, attached, methods, how wired
--   stickers all             the same, plus every other peripheral and its methods
--   stickers watch           refresh twice a second until Ctrl+T (dock, press a
--                            payload against one, and watch what it reports)
--   stickers save            the `all` listing to stickers.txt, pushed to the
--                            repo as data/stickers.txt
--   stickers test <name>     extend it, read isAttachedToBlock for 3 s, retract it
--   stickers extend <name>   extend it and leave it extended
--   stickers retract <name>  retract it
--
-- Create 6 gives the Sticker a peripheral of type "Create_Sticker":
-- isExtended(), isAttachedToBlock(), extend(), retract(), toggle(). The last
-- three return true only when the state actually changed. No events.
--
-- What an extended sticker DOES on a drone comes from Sable, not Create:
-- pressed flush (1/16 block, within 30 deg) against another physics object it
-- welds the two together, and against an ordinary world block it welds the
-- craft to the WORLD. Retracting removes the weld. So extend only on the
-- ground or docked, never in flight; and retracting drops whatever it holds.
-- isAttachedToBlock is Create's own check and may not see a block that belongs
-- to a different physics object - this tool is partly here to find that out.

local args = { ... }
local cmd, target = args[1], args[2]
local TYPE = "Create_Sticker"
local SIDES = { top = true, bottom = true, left = true, right = true, front = true, back = true }
local WARN = "An extended sticker flush against a block welds this craft to it " ..
             "(to the WORLD if it is an ordinary block). On the ground or docked only."

local lines = {}
local function say(s)
  lines[#lines + 1] = s
  print(s)
end

local function isSticker(name)
  if peripheral.hasType then
    local ok, yes = pcall(peripheral.hasType, name, TYPE)
    if ok and yes ~= nil then return yes end
  end
  for _, t in ipairs({ peripheral.getType(name) }) do
    if t == TYPE then return true end
  end
  return false
end

local function call(name, method)
  local ok, v = pcall(peripheral.call, name, method)
  if not ok then return "error: " .. tostring(v) end
  return v
end

local function yn(v)
  if v == true then return "yes" elseif v == false then return "no" end
  return tostring(v)
end

local function where(name)
  if SIDES[name] then return "touching the computer, " .. name .. " side" end
  return "on the wired network"
end

local function methodsOf(name)
  local ok, ms = pcall(peripheral.getMethods, name)
  if not (ok and type(ms) == "table") then return {} end
  table.sort(ms)
  return ms
end

local function stickers()
  local list = {}
  for _, n in ipairs(peripheral.getNames()) do
    if isSticker(n) then list[#list + 1] = n end
  end
  table.sort(list)
  return list
end

local function listing(all)
  local list = stickers()
  say(string.format("stickers: %d found (type %s)", #list, TYPE))
  if #list == 0 then
    say("  none - a sticker must touch this computer, or carry a wired modem")
    say("  cabled to it with the modem switched on (right-click: red ring)")
  end
  for _, n in ipairs(list) do
    say(string.format("  %-18s extended %-3s attached %-3s %s", n, yn(call(n, "isExtended")),
      yn(call(n, "isAttachedToBlock")), where(n)))
    say("    methods: " .. table.concat(methodsOf(n), ", "))
  end
  if all then
    say("")
    say("other peripherals:")
    for _, n in ipairs(peripheral.getNames()) do
      if not isSticker(n) then
        local ms = methodsOf(n)
        say(string.format("  %-18s %s", n, table.concat({ peripheral.getType(n) }, "/")))
        say("    " .. (#ms > 0 and table.concat(ms, ", ") or "(no methods)"))
      end
    end
  end
  return list
end

local function confirm(question)
  write(question .. " [y/N] ")
  local a = read()
  return type(a) == "string" and a:lower():sub(1, 1) == "y"
end

local function need(name)
  if not name then error("usage: stickers " .. cmd .. " <name>   (run stickers to list the names)", 0) end
  if not peripheral.isPresent(name) or not isSticker(name) then
    error(name .. " is not a sticker on this computer (run stickers to list them)", 0)
  end
end

if cmd == nil or cmd == "all" then
  listing(cmd == "all")
  print("")
  print("stickers test <name> to watch one work")

elseif cmd == "watch" then
  while true do
    term.clear()
    term.setCursorPos(1, 1)
    listing(false)
    print("")
    print("refreshing - Ctrl+T stops")
    sleep(0.5)
  end

elseif cmd == "save" then
  listing(true)
  local f = fs.open("stickers.txt", "w")
  f.write(table.concat(lines, "\n") .. "\n")
  f.close()
  print("")
  print("written to stickers.txt (" .. #lines .. " lines)")
  if fs.exists("upload.lua") and http then
    print("pushing to the repo as data/stickers.txt ...")
    local ok, err = pcall(function()
      if shell then return shell.run("upload", "sync", "stickers.txt", "data/stickers.txt") end
      return os.run({}, "upload.lua", "sync", "stickers.txt", "data/stickers.txt")
    end)
    if not ok then print("push failed: " .. tostring(err)) end
  else
    print("no upload.lua or no http - copy stickers.txt off manually")
  end

elseif cmd == "test" then
  need(target)
  if call(target, "isExtended") == true then
    print(target .. " is already extended - it may be holding something. Not touching it.")
    print("stickers retract " .. target .. " first if you mean to.")
    return
  end
  print(WARN)
  if not confirm("extend " .. target .. " for 3 s, then retract it?") then
    print("nothing changed")
    return
  end
  print("extend() -> " .. yn(call(target, "extend")))
  local attached, last = false, nil
  for i = 1, 12 do
    sleep(0.25)
    local ext, att = call(target, "isExtended"), call(target, "isAttachedToBlock")
    if att == true then attached = true end
    local s = "extended " .. yn(ext) .. ", attached " .. yn(att)
    if s ~= last then
      print(string.format("  %.2f s  %s", i * 0.25, s))
      last = s
    end
  end
  print("retract() -> " .. yn(call(target, "retract")))
  sleep(0.25)
  print("now extended " .. yn(call(target, "isExtended")))
  if attached then
    print("it reported a block in front of it")
  else
    print("it never reported a block: nothing flush in front of it, or (against a")
    print("physics object) Create's check cannot see it - so note whether the craft")
    print("or the payload was actually held while it was out")
  end

elseif cmd == "extend" or cmd == "retract" then
  need(target)
  if cmd == "extend" then
    print(WARN)
  else
    print("Retracting releases whatever this sticker is holding.")
  end
  if not confirm(cmd .. " " .. target .. "?") then
    print("nothing changed")
    return
  end
  print(cmd .. "() -> " .. yn(call(target, cmd)) .. "  (yes = it changed)")
  sleep(0.25)
  print("now extended " .. yn(call(target, "isExtended")) .. ", attached " .. yn(call(target, "isAttachedToBlock")))

else
  print("usage: stickers [all | watch | save | test <name> | extend <name> | retract <name>]")
end
