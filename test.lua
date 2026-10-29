local covered = {}
debug.sethook(function(_, line)
  if debug.getinfo(2, "S").source == "@main.lua" then
    covered[line] = true
  end
end, "l")

package.preload.zeppelin = function() return dofile("../zeppelin.yazi/main.lua") end
local P = dofile("main.lua")

-- yazi API stub. Contracts from yazi v26.9.1 source (yazi-fs/src/trash, entry.rs):
--   fs.trash.list/restore/remove take ownership of a TrashEntry; reusing one raises.
--   fs.trash.entry(entry) clones it; any other argument raises.
local function die(msg)
  error(msg, 3)
end

local Entry = {}
Entry.__index = function(e, k)
  if rawget(e, "_taken") then
    die("userdata has been destructed")
  end
  return rawget(e, "_node")[k]
end

local function new_entry(node)
  return setmetatable({ _node = node }, Entry)
end

local function take(e)
  if getmetatable(e) ~= Entry then
    die("expected TrashEntry")
  end
  if rawget(e, "_taken") then
    die("userdata has been destructed")
  end
  rawset(e, "_taken", true)
  return rawget(e, "_node")
end

local function node(o)
  local n = { top = o.top, date = o.date, original = o.original, name = o.original:match("[^/]+$"), is_dir = o.is_dir or false, kids = {} }
  n.cha = { is_dir = n.is_dir }
  n.lcha = { is_dir = n.is_dir and not o.link }
  for _, k in ipairs(o.kids or {}) do
    k.parent = n
    n.kids[#n.kids + 1] = k
  end
  return n
end

local W

local function unlink(n)
  local list = n.parent and n.parent.kids or W.trash
  for i, x in ipairs(list) do
    if x == n then
      table.remove(list, i)
      return
    end
  end
end

local function place(n)
  W.disk[n.original] = { is_dir = n.is_dir }
  for _, k in ipairs(n.kids) do
    place(k)
  end
end

local function reset(spec)
  W = {
    trash = spec.trash or {},
    disk = {},
    asked = {},
    notes = {},
    emits = 0,
    removed = {},
    trash_removed = {},
    commands = 0,
    icon_calls = 0,
    answers = spec.answers or {},
    fail_restore = spec.fail_restore or {},
    fail_remove = spec.fail_remove or {},
    list_error = spec.list_error,
    fail_list = spec.fail_list or {},
    fail_trash_remove = spec.fail_trash_remove or {},
  }
  for path, d in pairs(spec.disk or {}) do
    W.disk[path] = { is_dir = d.is_dir, marker = d.marker, link = d.link }
  end
end

local function run_entry(spec)
  reset(spec)
  P:entry()
  return W
end

local function obj(t)
  return setmetatable(t, { __index = {
    align = function(s) return s end,
    style = function(s) return s end,
  } })
end

local function line_text(l)
  if l.text then
    return l.text
  end
  local parts = {}
  for _, p in ipairs(l.parts) do
    parts[#parts + 1] = p.text
  end
  return table.concat(parts)
end

local function run_again(answers)
  W.answers = answers
  W.notes = {}
  P:entry()
  return W
end

local function status(w)
  local n = w.notes[#w.notes]
  return n and n.content, n and n.level
end

fs = {
  cha = function(url)
    local d = W.disk[url.path]
    if d then
      return { is_dir = d.is_dir, is_link = d.link }
    end
  end,
  remove = function(kind, url)
    if W.fail_remove[url.path] then
      return false, "denied " .. url.path
    end
    W.removed[#W.removed + 1] = kind .. ":" .. url.path
    for p in pairs(W.disk) do
      if p == url.path or p:sub(1, #url.path + 1) == url.path .. "/" then
        W.disk[p] = nil
      end
    end
    return true
  end,
  trash = {
    list = function(arg)
      if arg == nil and W.list_error then
        return nil, W.list_error
      end
      if arg == nil then
        local out = {}
        for i, n in ipairs(W.trash) do
          out[i] = new_entry(n)
        end
        return out
      end
      local n = take(arg)
      if not n.lcha.is_dir then
        return nil, "trash item is not a directory"
      end
      if W.fail_list[n.original] then
        return nil, "list failed for " .. n.original
      end
      local out = {}
      for i, k in ipairs(n.kids) do
        out[i] = new_entry(k)
      end
      return out
    end,
    entry = function(e)
      if getmetatable(e) ~= Entry or rawget(e, "_taken") then
        die("fs.trash.entry: expected live TrashEntry")
      end
      return new_entry(rawget(e, "_node"))
    end,
    restore = function(list)
      for _, e in ipairs(list) do
        local n = take(e)
        if W.fail_restore[n.original] or W.disk[n.original] then
          return false, "restore target already exists: " .. n.original
        end
        place(n)
        unlink(n)
      end
      return true
    end,
    remove = function(kind, e)
      local n = take(e)
      if W.fail_trash_remove[n.original] then
        return false, "trash remove failed for " .. n.original
      end
      W.trash_removed[#W.trash_removed + 1] = n.original
      unlink(n)
      return true
    end,
  },
}

Command = setmetatable({ PIPED = 1, NULL = 2 }, { __call = function(_, name)
  local c = { name = name }
  function c:arg(a)
    self.args = a
    return self
  end
  function c:stdout()
    return self
  end
  function c:stderr()
    return self
  end
  function c:output()
    W.commands = W.commands + 1
    if self.name ~= "grep" then
      die("unexpected command " .. self.name)
    end
    local a = self.args
    if a[1] ~= "-H" or a[2] ~= "^DeletionDate=" then
      die("unexpected grep args")
    end
    if #a < 3 then
      die("grep without files would read stdin")
    end
    local out = {}
    for i = 3, #a do
      for _, n in ipairs(W.trash) do
        if n.top == a[i] then
          out[#out + 1] = a[i] .. ":DeletionDate=" .. n.date .. "\n"
        end
      end
    end
    return { stdout = table.concat(out), status = { success = true } }
  end
  return c
end })

ya = {
  notify = function(t)
    W.notes[#W.notes + 1] = t
  end,
  emit = function()
    W.emits = W.emits + 1
  end,
  confirm = function(o)
    W.asked[#W.asked + 1] = o
    local a = table.remove(W.answers, 1)
    if a == nil then
      die("unexpected confirm: " .. o.title)
    end
    return a
  end,
}

ui = {
  Align = { LEFT = 0 },
  Span = function(s)
    return obj { text = s }
  end,
  Line = function(x)
    if type(x) == "string" then
      return obj { text = x }
    end
    return obj { parts = x }
  end,
  Text = function(lines)
    return obj { lines = lines }
  end,
}

th = {
  icon = {
    match = function(_, file)
      W.icon_calls = W.icon_calls + 1
      local m = file.cha.mode
      return { text = m == tonumber("120777", 8) and "L" or m == tonumber("40700", 8) and "D" or "F", style = "S" }
    end,
  },
}
File = function(t)
  return t
end
Url = function(p)
  return { path = p }
end
Cha = function(t)
  return t
end

local function fake_env(targets)
  local env = { restored = {}, removed = {}, trash_dirs_removed = {}, fail = {}, remove_fail = {} }
  function env.cha(path)
    return targets[path]
  end
  function env.children(ent)
    return ent.kids or {}
  end
  function env.restore(ent)
    local path = tostring(ent.original)
    if env.fail[path] then
      return false, "boom " .. path
    end
    env.restored[#env.restored + 1] = path
    targets[path] = { is_dir = ent.is_dir }
    return true
  end
  function env.remove_trash_dir(ent)
    env.trash_dirs_removed[#env.trash_dirs_removed + 1] = tostring(ent.original)
    return true
  end
  function env.remove_existing(path)
    if env.remove_fail[path] then
      return false, "denied " .. path
    end
    env.removed[#env.removed + 1] = path
    for k in pairs(targets) do
      if k == path or k:sub(1, #path + 1) == path .. "/" then
        targets[k] = nil
      end
    end
    return true
  end
  return env
end

local function file(path)
  return { original = path, is_dir = false }
end

local function dir(path, kids)
  return { original = path, is_dir = true, kids = kids or {} }
end

local function run(ent, targets, approved)
  local env = fake_env(targets)
  local stats = { restored = 0, skipped = 0, failed = 0 }
  local conflicts = P.find_conflicts(ent, env)
  local ok = P.apply(ent, env, approved or {}, stats)
  return { env = env, stats = stats, conflicts = conflicts, ok = ok, targets = targets }
end

local function eq(a, b, msg)
  if a ~= b then
    error(string.format("%s: expected %s, got %s", msg, tostring(b), tostring(a)), 2)
  end
end

local function has(list, v)
  for _, x in ipairs(list) do
    if x == v then return true end
  end
  return false
end

-- 1 free file: restored, no conflicts
do
  local r = run(file("/o/a"), {})
  eq(#r.conflicts, 0, "free: conflicts")
  eq(r.stats.restored, 1, "free: restored")
  eq(r.ok, true, "free: ok")
end

-- 2 file conflict, not approved: skipped, existing kept
do
  local r = run(file("/o/a"), { ["/o/a"] = { is_dir = false } })
  eq(#r.conflicts, 1, "file conflict: count")
  eq(r.stats.skipped, 1, "file conflict unapproved: skipped")
  eq(#r.env.restored, 0, "file conflict unapproved: no restore")
  eq(#r.env.removed, 0, "file conflict unapproved: no remove")
  eq(r.ok, false, "file conflict unapproved: not ok")
end

-- 3 file conflict, approved: existing removed, restored
do
  local r = run(file("/o/a"), { ["/o/a"] = { is_dir = false } }, { ["/o/a"] = true })
  eq(r.env.removed[1], "/o/a", "file approved: removed")
  eq(r.env.restored[1], "/o/a", "file approved: restored")
  eq(r.ok, true, "file approved: ok")
end

-- 4 dir merge, no conflicts: extra existing file kept, trash dir removed
do
  local ent = dir("/o/d", { file("/o/d/a"), file("/o/d/b") })
  local r = run(ent, { ["/o/d"] = { is_dir = true }, ["/o/d/x"] = { is_dir = false } })
  eq(#r.conflicts, 0, "merge clean: conflicts")
  eq(r.stats.restored, 2, "merge clean: restored children")
  eq(r.env.trash_dirs_removed[1], "/o/d", "merge clean: trash dir removed")
  eq(#r.env.removed, 0, "merge clean: nothing deleted")
  eq(r.targets["/o/d/x"] ~= nil, true, "merge clean: extra file kept")
end

-- 5 dir merge, child conflict not approved: other child restored, conflict kept, trash dir kept
do
  local ent = dir("/o/d", { file("/o/d/a"), file("/o/d/b") })
  local r = run(ent, { ["/o/d"] = { is_dir = true }, ["/o/d/b"] = { is_dir = false } })
  eq(#r.conflicts, 1, "merge partial: one conflict")
  eq(r.conflicts[1].original, "/o/d/b", "merge partial: conflict path")
  eq(r.stats.restored, 1, "merge partial: a restored")
  eq(r.stats.skipped, 1, "merge partial: b skipped")
  eq(#r.env.trash_dirs_removed, 0, "merge partial: trash dir kept")
  eq(r.ok, false, "merge partial: not ok")
end

-- 6 dir merge, child conflict approved: overwritten only that child, extra file kept
do
  local ent = dir("/o/d", { file("/o/d/a"), file("/o/d/b") })
  local targets = { ["/o/d"] = { is_dir = true }, ["/o/d/b"] = { is_dir = false }, ["/o/d/x"] = { is_dir = false } }
  local r = run(ent, targets, { ["/o/d/b"] = true })
  eq(r.env.removed[1], "/o/d/b", "merge approved: only b removed")
  eq(#r.env.removed, 1, "merge approved: single removal")
  eq(targets["/o/d/x"] ~= nil, true, "merge approved: extra kept")
  eq(r.env.trash_dirs_removed[1], "/o/d", "merge approved: trash dir removed")
end

-- 7 dir in trash, file at target: type mismatch is a conflict, approved replaces
do
  local ent = dir("/o/d", { file("/o/d/a") })
  local targets = { ["/o/d"] = { is_dir = false } }
  local r = run(ent, targets)
  eq(#r.conflicts, 1, "type mismatch: conflict")
  eq(r.conflicts[1].original, "/o/d", "type mismatch: conflict is the dir")
  local r2 = run(dir("/o/d", { file("/o/d/a") }), { ["/o/d"] = { is_dir = false } }, { ["/o/d"] = true })
  eq(r2.env.removed[1], "/o/d", "type mismatch approved: file removed")
  eq(r2.env.restored[1], "/o/d", "type mismatch approved: dir restored")
end

-- 8 nested merge recurses
do
  local ent = dir("/o/d", { dir("/o/d/sub", { file("/o/d/sub/x") }) })
  local targets = { ["/o/d"] = { is_dir = true }, ["/o/d/sub"] = { is_dir = true }, ["/o/d/sub/x"] = { is_dir = false } }
  local r = run(ent, targets, { ["/o/d/sub/x"] = true })
  eq(r.env.removed[1], "/o/d/sub/x", "nested: conflict deep")
  eq(r.stats.restored, 1, "nested: restored deep file")
  eq(#r.env.trash_dirs_removed, 2, "nested: both trash dirs removed")
end

-- 9 empty trash dir onto existing dir: just removes trash shell
do
  local r = run(dir("/o/d", {}), { ["/o/d"] = { is_dir = true } })
  eq(#r.conflicts, 0, "empty merge: no conflicts")
  eq(r.env.trash_dirs_removed[1], "/o/d", "empty merge: trash shell removed")
  eq(r.ok, true, "empty merge: ok")
end

-- 10 restore failure: counted, trash dir kept, not ok
do
  local ent = dir("/o/d", { file("/o/d/a") })
  local env_targets = { ["/o/d"] = { is_dir = true } }
  local env = fake_env(env_targets)
  env.fail["/o/d/a"] = true
  local stats = { restored = 0, skipped = 0, failed = 0 }
  local ok = P.apply(ent, env, {}, stats)
  eq(stats.failed, 1, "restore fail: failed count")
  eq(stats.first_err, "boom /o/d/a", "restore fail: first error")
  eq(#env.trash_dirs_removed, 0, "restore fail: trash dir kept")
  eq(ok, false, "restore fail: not ok")
end

-- 11 remove_existing fails: restore not attempted
do
  local env = fake_env({ ["/o/a"] = { is_dir = false } })
  env.remove_fail["/o/a"] = true
  local stats = { restored = 0, skipped = 0, failed = 0 }
  P.apply(file("/o/a"), env, { ["/o/a"] = true }, stats)
  eq(stats.failed, 1, "remove fail: failed")
  eq(#env.restored, 0, "remove fail: no restore")
end

-- 12 parse_dates: colon in path, empty input
do
  local d = P.parse_dates("/t/a:b.trashinfo:DeletionDate=2026-10-18T10:00:00\n/t/c.trashinfo:DeletionDate=2026-10-18T09:00:00\n")
  eq(d["/t/a:b.trashinfo"], "2026-10-18T10:00:00", "dates: colon path")
  eq(d["/t/c.trashinfo"], "2026-10-18T09:00:00", "dates: plain path")
  eq(next(P.parse_dates("")), nil, "dates: empty")
end

-- 13 last_batch: latest timestamp only, tops without date ignored
do
  local tops = { { top = "/i/1" }, { top = "/i/2" }, { top = "/i/3" }, { top = "/i/4" } }
  local dates = { ["/i/1"] = "2026-10-18T09:00:00", ["/i/2"] = "2026-10-18T10:00:00", ["/i/3"] = "2026-10-18T10:00:00" }
  local b = P.last_batch(tops, dates)
  eq(#b, 2, "batch: size")
  eq(b[1].top, "/i/2", "batch: first")
  eq(b[2].top, "/i/3", "batch: second")
  eq(#P.last_batch(tops, {}), 0, "batch: no dates")
end

-- 14 find_conflicts: merge with multiple conflicts at different depths
do
  local ent = dir("/o/d", { file("/o/d/a"), dir("/o/d/s", { file("/o/d/s/b") }) })
  local targets = { ["/o/d"] = { is_dir = true }, ["/o/d/a"] = { is_dir = false }, ["/o/d/s"] = { is_dir = true }, ["/o/d/s/b"] = { is_dir = false } }
  local c = P.find_conflicts(ent, fake_env(targets))
  eq(#c, 2, "multi: count")
  eq(has({ c[1].original, c[2].original }, "/o/d/a") and has({ c[1].original, c[2].original }, "/o/d/s/b"), true, "multi: paths")
end

-- 15 approved set keyed by exact path: other paths untouched
do
  local ent = dir("/o/d", { file("/o/d/a"), file("/o/d/b") })
  local targets = { ["/o/d"] = { is_dir = true }, ["/o/d/a"] = { is_dir = false }, ["/o/d/b"] = { is_dir = false } }
  local r = run(ent, targets, { ["/o/d/a"] = true })
  eq(r.env.removed[1], "/o/d/a", "approve one: a removed")
  eq(#r.env.removed, 1, "approve one: b not removed")
  eq(r.stats.skipped, 1, "approve one: b skipped")
end

local cases = {}
local function case(name, fn)
  cases[#cases + 1] = { name = name, fn = fn }
 end

local function T(info, date, o)
  o.top = info
  o.date = date
  return node(o)
end

local DATE = "2026-10-18T10:00:00"

case("free file, yes", function()
  local w = run_entry { trash = { T("/i/1", DATE, { original = "/o/a" }) }, answers = { true } }
  eq(w.disk["/o/a"].is_dir, false, "disk")
  eq(#w.trash, 0, "trash emptied")
  eq(w.asked[1].title, "Restore 1 deleted item(s)?", "title")
  eq(select(1, status(w)), "restored 1, skipped 0, failed 0", "summary")
  eq(w.emits, 1, "refresh")
end)

case("cancel restore does nothing", function()
  local w = run_entry { trash = { T("/i/1", DATE, { original = "/o/a" }) }, answers = { false } }
  eq(w.disk["/o/a"], nil, "disk")
  eq(#w.trash, 1, "trash kept")
  eq(#w.notes, 0, "no notice")
  eq(w.emits, 0, "no refresh")
end)

case("empty trash: warn, no grep", function()
  local w = run_entry { trash = {} }
  local content, level = status(w)
  eq(content, "nothing to restore", "content")
  eq(level, "warn", "level")
  eq(#w.asked, 0, "no confirm")
  eq(w.commands, 0, "grep not spawned")
end)

case("free dir with children", function()
  local w = run_entry {
    trash = { T("/i/d", DATE, { original = "/o/d", is_dir = true, kids = { node { original = "/o/d/a" }, node { original = "/o/d/b" } } }) },
    answers = { true },
  }
  eq(w.disk["/o/d"].is_dir, true, "dir")
  eq(w.disk["/o/d/a"] ~= nil, true, "child a")
  eq(w.disk["/o/d/b"] ~= nil, true, "child b")
  eq(#w.trash, 0, "trash emptied")
end)

case("dir merge onto existing dir keeps extra file (evidence/1 case)", function()
  local w = run_entry {
    disk = { ["/o/d"] = { is_dir = true }, ["/o/d/x"] = { is_dir = false, marker = "keep" } },
    trash = { T("/i/d", DATE, { original = "/o/d", is_dir = true, kids = { node { original = "/o/d/a" }, node { original = "/o/d/b" } } }) },
    answers = { true },
  }
  eq(#w.asked, 1, "no overwrite prompt")
  eq(w.disk["/o/d/x"].marker, "keep", "extra kept")
  eq(w.disk["/o/d/a"] ~= nil and w.disk["/o/d/b"] ~= nil, true, "children restored")
  eq(#w.removed, 0, "nothing deleted")
  eq(w.trash_removed[1], "/o/d", "trash shell removed")
  eq(#w.trash, 0, "trash emptied")
  eq(select(1, status(w)), "restored 2, skipped 0, failed 0", "summary")
end)

case("dir merge: 3 files existing, 4 in trash, overlap a+b: only overlap asked", function()
  local w = run_entry {
    disk = { ["/o/d"] = { is_dir = true }, ["/o/d/a"] = { is_dir = false, marker = "old-a" }, ["/o/d/b"] = { is_dir = false }, ["/o/d/c"] = { is_dir = false, marker = "keep-c" } },
    trash = { T("/i/d", DATE, { original = "/o/d", is_dir = true, kids = { node { original = "/o/d/a" }, node { original = "/o/d/b" }, node { original = "/o/d/d" }, node { original = "/o/d/e" } } }) },
    answers = { true, false },
  }
  eq(#w.asked, 2, "restore + overwrite prompt")
  eq(#w.asked[2].body.lines, 2, "only a and b listed")
  eq(w.disk["/o/d/a"].marker, "old-a", "declined: a kept")
  eq(w.disk["/o/d/c"].marker, "keep-c", "c never touched")
  eq(w.disk["/o/d/d"] ~= nil and w.disk["/o/d/e"] ~= nil, true, "non-overlap d,e restored")
  eq(#w.removed, 0, "nothing deleted")
  eq(#w.trash, 1, "trash dir kept (a,b still inside)")
  eq(select(1, status(w)), "restored 2, skipped 2, failed 0", "summary")
end)

case("dir merge: 3 files existing, 4 in trash, overlap a+b: yes replaces only a,b", function()
  local w = run_entry {
    disk = { ["/o/d"] = { is_dir = true }, ["/o/d/a"] = { is_dir = false, marker = "old-a" }, ["/o/d/b"] = { is_dir = false }, ["/o/d/c"] = { is_dir = false, marker = "keep-c" } },
    trash = { T("/i/d", DATE, { original = "/o/d", is_dir = true, kids = { node { original = "/o/d/a" }, node { original = "/o/d/b" }, node { original = "/o/d/d" }, node { original = "/o/d/e" } } }) },
    answers = { true, true },
  }
  eq(w.disk["/o/d/a"].marker, nil, "a replaced")
  eq(w.disk["/o/d/c"].marker, "keep-c", "c kept")
  eq(#w.trash, 0, "trash emptied")
  eq(select(1, status(w)), "restored 4, skipped 0, failed 0", "summary")
end)

case("file conflict, overwrite yes", function()
  local w = run_entry {
    disk = { ["/o/a"] = { is_dir = false, marker = "old" } },
    trash = { T("/i/1", DATE, { original = "/o/a" }) },
    answers = { true, true },
  }
  eq(#w.asked, 2, "two prompts")
  eq(w.asked[2].title:find("PERMANENTLY") ~= nil, true, "permanent warning")
  eq(w.removed[1], "file:/o/a", "removed")
  eq(w.disk["/o/a"].marker, nil, "replaced")
  eq(select(1, status(w)), "restored 1, skipped 0, failed 0", "summary")
end)

case("file conflict, overwrite no", function()
  local w = run_entry {
    disk = { ["/o/a"] = { is_dir = false, marker = "old" } },
    trash = { T("/i/1", DATE, { original = "/o/a" }) },
    answers = { true, false },
  }
  eq(w.disk["/o/a"].marker, "old", "untouched")
  eq(#w.removed, 0, "nothing removed")
  eq(#w.trash, 1, "stays in trash")
  eq(select(1, status(w)), "restored 0, skipped 1, failed 0", "summary")
  eq(w.emits, 0, "no refresh when nothing restored")
end)

case("dir in trash over file: overwrite yes", function()
  local w = run_entry {
    disk = { ["/o/d"] = { is_dir = false, marker = "old" } },
    trash = { T("/i/d", DATE, { original = "/o/d", is_dir = true, kids = { node { original = "/o/d/a" } } }) },
    answers = { true, true },
  }
  eq(w.removed[1], "file:/o/d", "file removed")
  eq(w.disk["/o/d"].is_dir, true, "dir restored")
  eq(w.disk["/o/d/a"] ~= nil, true, "child restored")
end)

case("nested merge, deep conflict declined keeps trash dirs", function()
  local w = run_entry {
    disk = { ["/o/d"] = { is_dir = true }, ["/o/d/s"] = { is_dir = true }, ["/o/d/s/b"] = { is_dir = false, marker = "old" } },
    trash = { T("/i/d", DATE, { original = "/o/d", is_dir = true, kids = {
      node { original = "/o/d/a" },
      node { original = "/o/d/s", is_dir = true, kids = { node { original = "/o/d/s/b" } } },
    } }) },
    answers = { true, false },
  }
  eq(w.asked[2].title:find("Overwrite 1") ~= nil, true, "one conflict")
  eq(w.disk["/o/d/s/b"].marker, "old", "b untouched")
  eq(w.disk["/o/d/a"] ~= nil, true, "a restored")
  eq(#w.trash, 1, "top dir kept")
  eq(#w.trash_removed, 0, "no trash shells removed")
  eq(select(1, status(w)), "restored 1, skipped 1, failed 0", "summary")
end)

case("restore failure is reported as error", function()
  local w = run_entry {
    trash = { T("/i/1", DATE, { original = "/o/a" }) },
    answers = { true },
    fail_restore = { ["/o/a"] = true },
  }
  local content, level = status(w)
  eq(level, "error", "level")
  eq(content:find("failed 1") ~= nil, true, "count")
  eq(content:find("restore target already exists") ~= nil, true, "reason")
  eq(#w.trash, 1, "stays in trash")
end)

case("latest batch picked, colon in name, multiple dates", function()
  local w = run_entry {
    trash = {
      T("/i/x:1", "2026-10-18T09:00:00", { original = "/o/x" }),
      T("/i/y", "2026-10-18T10:00:00", { original = "/o/y" }),
      T("/i/z", "2026-10-18T10:00:00", { original = "/o/z" }),
    },
    answers = { true },
  }
  eq(w.asked[1].title, "Restore 2 deleted item(s)?", "batch size")
  eq(w.disk["/o/x"], nil, "older untouched")
  eq(w.disk["/o/y"] ~= nil and w.disk["/o/z"] ~= nil, true, "latest restored")
  eq(#w.trash, 1, "older still trashed")
end)

case("long confirm list truncates and shows icons for shown rows", function()
  local trash = {}
  for i = 1, 13 do
    trash[i] = T("/i/" .. i, DATE, { original = "/o/f" .. i })
  end
  local w = run_entry { trash = trash, answers = { true } }
  local body = w.asked[1].body.lines
  eq(#body, 11, "lines")
  eq(line_text(body[11]), "  \u{2026} 3 more", "more line")
  eq(w.icon_calls, 10, "icons only for shown rows")
  eq(#w.trash, 0, "all 13 restored")
end)

case("overwrite removal fails: reported, nothing restored", function()
  local w = run_entry {
    disk = { ["/o/a"] = { is_dir = false, marker = "old" } },
    trash = { T("/i/1", DATE, { original = "/o/a" }) },
    answers = { true, true },
    fail_remove = { ["/o/a"] = true },
  }
  local content, level = status(w)
  eq(level, "error", "level")
  eq(content:find("failed 1") ~= nil and content:find("denied") ~= nil, true, "summary")
  eq(w.disk["/o/a"].marker, "old", "untouched")
  eq(#w.trash, 1, "stays in trash")
end)

case("trash listing error is reported", function()
  local w = run_entry { list_error = "no trash dir" }
  local content, level = status(w)
  eq(level, "error", "level")
  eq(content, "cannot list trash: no trash dir", "content")
  eq(#w.asked, 0, "no confirm")
end)

case("repeated undo walks back batch by batch", function()
  local w = run_entry {
    trash = {
      T("/i/a", "2026-10-18T09:00:00", { original = "/o/a" }),
      T("/i/b", "2026-10-18T10:00:00", { original = "/o/b" }),
    },
    answers = { true },
  }
  eq(w.disk["/o/b"] ~= nil and w.disk["/o/a"] == nil, true, "first u takes latest")
  run_again { true }
  eq(w.disk["/o/a"] ~= nil, true, "second u takes the next one")
  eq(#w.trash, 0, "trash emptied")
  run_again {}
  eq(select(1, status(w)), "nothing to restore", "third u says nothing left")
end)

case("overwrite prompt shows the existing target's icon, not the trash entry's", function()
  local w = run_entry {
    disk = { ["/o/a"] = { is_dir = false, marker = "keep" } },
    trash = { T("/i/1", DATE, { original = "/o/a", is_dir = true }) },
    answers = { true, false },
  }
  eq(line_text(w.asked[2].body.lines[1]):find("F /o/a", 1, true) ~= nil, true, "file icon on overwrite")
  eq(line_text(w.asked[1].body.lines[1]):find("D /o/a", 1, true) ~= nil, true, "dir icon on restore")
end)

case("symlink in trash over existing dir: refused, dir never deleted", function()
  local w = run_entry {
    disk = { ["/o/d"] = { is_dir = true }, ["/o/d/x"] = { is_dir = false, marker = "keep" } },
    trash = { T("/i/d", DATE, { original = "/o/d", is_dir = true, link = true }) },
    answers = { true, true },
  }
  eq(#w.asked, 2, "restore + blocked prompt only, no overwrite prompt")
  eq(#w.removed, 0, "nothing deleted")
  eq(w.disk["/o/d/x"].marker, "keep", "dir contents untouched")
  eq(#w.trash, 1, "symlink kept in trash")
  eq(select(1, status(w)):find("restored 0, skipped 0, failed 1", 1, true) ~= nil, true, "summary")
  eq(w.emits, 0, "no refresh")
end)

case("blocked prompt declined: nothing restored, cause shown", function()
  local w = run_entry {
    disk = { ["/o/a"] = { is_dir = true }, ["/o/a/x"] = { is_dir = false } },
    trash = { T("/i/1", DATE, { original = "/o/a" }) },
    answers = { true, false },
  }
  eq(#w.trash, 1, "stays in trash")
  eq(w.disk["/o/a/x"] ~= nil, true, "dir kept")
  eq(#w.removed, 0, "nothing removed")
  eq(line_text(w.asked[2].body.lines[1]):find("D /o/a", 1, true) ~= nil, true, "blocked item listed with dir icon")
  eq(status(w), "cancelled, nothing restored", "status")
end)

case("symlink conflict says replace, not permanent delete", function()
  local w = run_entry {
    disk = { ["/o/a"] = { is_dir = false, link = true } },
    trash = { T("/i/1", DATE, { original = "/o/a" }) },
    answers = { true, true },
  }
  eq(w.asked[2].title, "Replace 1 symlink(s)? Only the links change; their targets are untouched.", "title")
end)

case("file conflict still says permanently deleted", function()
  local w = run_entry {
    disk = { ["/o/a"] = { is_dir = false } },
    trash = { T("/i/1", DATE, { original = "/o/a" }) },
    answers = { true, false },
  }
  eq(w.asked[2].title, "Overwrite 1 existing item(s)? Files will be PERMANENTLY deleted.", "title")
end)

case("symlink on disk shows link icon in overwrite prompt", function()
  local w = run_entry {
    disk = { ["/o/a"] = { is_dir = false, link = true } },
    trash = { T("/i/1", DATE, { original = "/o/a", is_dir = true }) },
    answers = { true, true },
  }
  eq(line_text(w.asked[2].body.lines[1]):find("L /o/a", 1, true) ~= nil, true, "link icon")
  eq(w.disk["/o/a"] ~= nil and w.disk["/o/a"].is_dir, true, "link replaced by dir")
end)

case("file in trash over existing dir: refused even when overwrite is yes", function()
  local w = run_entry {
    disk = { ["/o/a"] = { is_dir = true }, ["/o/a/x"] = { is_dir = false } },
    trash = { T("/i/1", DATE, { original = "/o/a" }) },
    answers = { true, true },
  }
  eq(#w.asked, 2, "restore + blocked prompt only, no overwrite prompt")
  eq(#w.removed, 0, "dir not removed")
  eq(w.disk["/o/a/x"] ~= nil, true, "dir contents kept")
  eq(status(w):find("refuses to replace directory /o/a", 1, true) ~= nil, true, "reason")
end)

case("trash dir that cannot be listed is reported, not treated as empty", function()
  local w = run_entry {
    disk = { ["/o/d"] = { is_dir = true } },
    trash = { T("/i/d", DATE, { original = "/o/d", is_dir = true, kids = { node { original = "/o/d/a" } } }) },
    answers = { true },
    fail_list = { ["/o/d"] = true },
  }
  local content, level = status(w)
  eq(level, "error", "level")
  eq(content:find("list failed") ~= nil, true, "reason")
  eq(#w.trash, 1, "kept in trash")
end)

case("trash shell that cannot be removed is reported (stuck batch surfaces)", function()
  local w = run_entry {
    disk = { ["/o/d"] = { is_dir = true } },
    trash = { T("/i/d", DATE, { original = "/o/d", is_dir = true }) },
    answers = { true },
    fail_trash_remove = { ["/o/d"] = true },
  }
  local content, level = status(w)
  eq(level, "error", "level")
  eq(content:find("trash remove failed") ~= nil, true, "reason")
end)

local failures = 0
for _, c in ipairs(cases) do
  local ok, err = pcall(c.fn)
  if not ok then
    failures = failures + 1
    print("FAIL " .. c.name .. ": " .. tostring(err))
  end
end

debug.sethook()
local total, hit, missing = 0, 0, {}
local n = 0
for line in io.lines("main.lua") do
  n = n + 1
  local t = line:match("^%s*(.-)%s*$")
  local code = t ~= "" and not t:match("^%-%-") and not t:match("^[%]%)}]*,?$") and not t:match("^end[%)]?,?$") and t ~= "else" and t ~= "return M" and t ~= "local M = {}" and not t:match("function%s*[%w_.:]*%(.*%)$")
  if code then
    total = total + 1
    if covered[n] then
      hit = hit + 1
    else
      missing[#missing + 1] = n
    end
  end
end
local pct = 100 * hit / total
print(string.format("main.lua coverage: %d/%d lines (%.0f%%)", hit, total, pct))
if #missing > 0 then
  print("uncovered: " .. table.concat(missing, ","))
end

assert(failures == 0, failures .. " scenario(s) failed")
assert(pct >= 90, "coverage below 90%")
print("zundo: ok")
