--- store: a site's stock, counted straight off its silos by CC (Alex,
-- 2026-10-03: "a live catalogue that customers can see our stock of").
--
-- Every inventory on the site's wired network that `store setup` marks as
-- stock is read with list() - one call a vault, however big it is - and
-- summed by item. No reference chest and no Stock Ticker: what is in stock
-- IS the catalogue. Items with data of their own - an enchanted book's
-- enchantments, a potion - are told apart by the hash list() gives, so each
-- is its own entry under its own name.
--
-- The store computer (store.lua, label store-<site>) sends its count to the
-- base sealed, in pages: a sealed message holds 8 KB, and a site holds
-- hundreds of kinds of item. The base keeps each site's last full count
-- (stock.txt) and adds them up: customers see one stock, the base knows
-- which site has what.
--
-- Pure: inventories come in as list() tables, the base's side is tables and
-- text, so tools/test_store.lua runs all of it on the desktop.

local St = {}

St.EVERY = 60              -- seconds between counts on the store computer
St.PAGE_BYTES = 6000       -- item text in one sealed page (seclink allows 8 KB)
St.MAX_PAGES = 200
St.LABEL_MAX = 60

local function num(v) return type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge end

--- An item's key: its id, and the hash of its own data when it has any.
function St.keyOf(it)
  if type(it) ~= "table" or type(it.name) ~= "string" then return nil end
  local h = it.nbt or it.components
  if type(h) == "string" and h ~= "" then return it.name .. "#" .. h end
  return it.name
end

--- A site from its store's name: store-chi counts for CHI.
function St.siteOf(id)
  local s = type(id) == "string" and id:match("^store%-([%w_%-]+)$")
  return s and s:upper() or nil
end

--- Sum the stock inventories. lists: inventory name -> its list() (or nil
-- when it could not be read). Returns key -> { count, inv, slot } - the
-- first place each item was seen, to read its name from - the problems, and
-- how many stacks were counted.
function St.count(lists, order)
  local totals, problems, stacks = {}, {}, 0
  for _, inv in ipairs(order) do
    local list = lists[inv]
    if type(list) ~= "table" then
      problems[#problems + 1] = inv .. ": cannot be read"
    else
      for slot, it in pairs(list) do
        local k = St.keyOf(it)
        if k and num(it.count) and it.count > 0 then
          local t = totals[k]
          if not t then t = { count = 0, inv = inv, slot = slot } totals[k] = t end
          t.count = t.count + it.count
          stacks = stacks + 1
        end
      end
    end
  end
  return totals, problems, stacks
end

--- What a person calls an item, from getItemDetail: its display name, and
-- an enchanted book's enchantments after it.
function St.label(d)
  if type(d) ~= "table" then return nil end
  local s = tostring(d.displayName or d.name or "?")
  local extra = {}
  if type(d.enchantments) == "table" then
    for _, e in ipairs(d.enchantments) do
      if type(e) == "table" and e.displayName then extra[#extra + 1] = tostring(e.displayName) end
    end
  end
  if #extra > 0 then s = s .. " (" .. table.concat(extra, ", ") .. ")" end
  return (s:gsub("[\t\n\r]", " ")):sub(1, St.LABEL_MAX)
end

--- The count as pages of "key<TAB>count<TAB>label" lines, each under
-- St.PAGE_BYTES: { { rep, page, pages, items }, ... }. Always at least one
-- page, so an empty site still says it is empty.
function St.pages(rep, totals, names)
  local keys = {}
  for k in pairs(totals) do keys[#keys + 1] = k end
  table.sort(keys)
  local texts, cur, size = {}, {}, 0
  for _, k in ipairs(keys) do
    local line = k .. "\t" .. math.floor(totals[k].count) .. "\t" .. tostring(names and names[k] or "")
    if size + #line + 1 > St.PAGE_BYTES and #cur > 0 then
      texts[#texts + 1] = table.concat(cur, "\n")
      cur, size = {}, 0
    end
    cur[#cur + 1] = line
    size = size + #line + 1
  end
  if #cur > 0 or #texts == 0 then texts[#texts + 1] = table.concat(cur, "\n") end
  local out = {}
  for i, t in ipairs(texts) do
    out[i] = { type = "stock.page", rep = rep, page = i, pages = #texts, items = t }
  end
  return out
end

--- A page's fields as the base receives them: true, or false and why.
function St.checkPage(m)
  if type(m) ~= "table" then return false, "not a table" end
  if not num(m.rep) then return false, "no count number" end
  if not (num(m.page) and num(m.pages) and m.page == math.floor(m.page) and m.pages == math.floor(m.pages)
          and m.page >= 1 and m.page <= m.pages and m.pages <= St.MAX_PAGES) then
    return false, "bad page"
  end
  if type(m.items) ~= "string" or #m.items > 7000 then return false, "bad items" end
  return true
end

--- One page's items: key -> { count, label }, or nil and why.
function St.parseItems(text)
  local out = {}
  for line in (tostring(text or "") .. "\n"):gmatch("([^\n]*)\n") do
    if line ~= "" then
      local k, c, l = line:match("^([^\t]+)\t(%d+)\t([^\t]*)$")
      if not k then return nil, "bad line: " .. line:sub(1, 40) end
      out[k] = { count = tonumber(c), label = l ~= "" and l or nil }
    end
  end
  return out
end

--- The base's side: a fresh state, { sites = { SITE = { at, rep, items } },
-- partial = { SITE = a count still arriving } }.
function St.new() return { sites = {}, partial = {} } end

--- One page in. Returns true and the site when it completes a count (which
-- then replaces that site's last one whole), false while pages are still to
-- come, nil and why when it is refused.
function St.take(st, from, m, now)
  local site = St.siteOf(from)
  if not site then return nil, "not a store: " .. tostring(from) end
  local ok, why = St.checkPage(m)
  if not ok then return nil, why end
  local p = st.partial[site]
  if not p or p.rep ~= m.rep or p.pages ~= m.pages then
    p = { rep = m.rep, pages = m.pages, got = {}, n = 0, items = {} }
    st.partial[site] = p
  end
  if not p.got[m.page] then
    local items, bad = St.parseItems(m.items)
    if not items then return nil, bad end
    for k, v in pairs(items) do p.items[k] = v end
    p.got[m.page] = true
    p.n = p.n + 1
  end
  if p.n < p.pages then return false end
  st.sites[site] = { at = now, rep = m.rep, items = p.items }
  st.partial[site] = nil
  return true, site
end

--- Every site added up, as customers see it: { { key, label, count, sites =
-- { SITE = count } } }, by name. A key's name is whichever site gave one.
function St.merge(st)
  local by = {}
  for site, s in pairs(st.sites or {}) do
    for k, v in pairs(s.items or {}) do
      local e = by[k]
      if not e then e = { key = k, count = 0, sites = {} } by[k] = e end
      e.count = e.count + v.count
      e.sites[site] = v.count
      e.label = e.label or v.label
    end
  end
  local out = {}
  for _, e in pairs(by) do
    e.label = e.label or e.key
    out[#out + 1] = e
  end
  table.sort(out, function(a, b)
    if a.label ~= b.label then return a.label < b.label end
    return a.key < b.key
  end)
  return out
end

--- The base's file: one line a site ("@ SITE at rep"), one line an item
-- ("SITE key count label"), tab-separated, so anything can read it.
function St.serialise(st)
  local lines, sites = {}, {}
  for site in pairs(st.sites or {}) do sites[#sites + 1] = site end
  table.sort(sites)
  for _, site in ipairs(sites) do
    local s = st.sites[site]
    lines[#lines + 1] = table.concat({ "@", site, string.format("%d", s.at or 0), string.format("%d", s.rep or 0) }, "\t")
    local keys = {}
    for k in pairs(s.items) do keys[#keys + 1] = k end
    table.sort(keys)
    for _, k in ipairs(keys) do
      local v = s.items[k]
      lines[#lines + 1] = table.concat({ site, k, string.format("%d", v.count), v.label or "" }, "\t")
    end
  end
  return table.concat(lines, "\n") .. (#lines > 0 and "\n" or "")
end
function St.load(text)
  local st = St.new()
  for line in (tostring(text or "") .. "\n"):gmatch("([^\n]*)\n") do
    local site, at, rep = line:match("^@\t([^\t]+)\t(%-?%d+)\t(%-?%d+)$")
    if site then
      st.sites[site] = { at = tonumber(at), rep = tonumber(rep), items = {} }
    else
      local s, k, c, l = line:match("^([^\t@][^\t]*)\t([^\t]+)\t(%d+)\t([^\t]*)$")
      if s and st.sites[s] then st.sites[s].items[k] = { count = tonumber(c), label = l ~= "" and l or nil } end
    end
  end
  return st
end

--- 12345678 as "12,345,678".
function St.commas(n)
  local s = tostring(math.floor(n or 0))
  local out = s:reverse():gsub("(%d%d%d)", "%1,"):reverse()
  return (out:gsub("^,", ""))
end

return St
