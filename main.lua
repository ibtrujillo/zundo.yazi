--- @since 26.9.1

local P = require("zeppelin")

local M = {}

local function notify(content, level)
	ya.notify({ title = "zundo", content = content, level = level or "info", timeout = 5 })
end

function M.parse_dates(stdout)
	local dates = {}
	for path, date in (stdout or ""):gmatch("([^\n]+):DeletionDate=([^\n]*)") do
		dates[path] = date
	end
	return dates
end

function M.last_batch(tops, dates)
	local latest
	for _, ent in ipairs(tops) do
		local d = dates[ent.top]
		if d and (not latest or d > latest) then
			latest = d
		end
	end
	local batch = {}
	for _, ent in ipairs(tops) do
		if latest and dates[ent.top] == latest then
			batch[#batch + 1] = ent
		end
	end
	return batch
end

local function target_of(ent)
	return tostring(ent.original)
end

-- "free": nothing at target; "merge": dir onto dir; "conflict": file replaced after approval;
-- "blocked": non-dir onto an existing dir, never deleted (a dir is not overwritten wholesale)
local function classify(ent, env)
	local cha = env.cha(target_of(ent))
	if not cha then
		return "free"
	end
	if cha.is_dir and ent.is_dir then
		return "merge"
	end
	if cha.is_dir then
		return "blocked"
	end
	return "conflict"
end

function M.find_blocked(ent, env, out)
	out = out or {}
	local kind = classify(ent, env)
	if kind == "blocked" then
		out[#out + 1] = ent
	elseif kind == "merge" then
		for _, child in ipairs(env.children(ent) or {}) do
			M.find_blocked(child, env, out)
		end
	end
	return out
end

function M.find_conflicts(ent, env, out)
	out = out or {}
	local kind = classify(ent, env)
	if kind == "conflict" then
		out[#out + 1] = ent
	elseif kind == "merge" then
		for _, child in ipairs(env.children(ent) or {}) do
			M.find_conflicts(child, env, out)
		end
	end
	return out
end

-- stats: { restored, skipped, failed, first_err }; returns true when ent is fully handled
function M.apply(ent, env, approved, stats)
	local kind = classify(ent, env)
	if kind == "merge" then
		local kids, err = env.children(ent)
		if not kids then
			stats.failed = stats.failed + 1
			stats.first_err = stats.first_err or err
			return false
		end
		local done = true
		for _, child in ipairs(kids) do
			done = M.apply(child, env, approved, stats) and done
		end
		if not done then
			return false
		end
		local ok, rm_err = env.remove_trash_dir(ent)
		if not ok then
			stats.failed = stats.failed + 1
			stats.first_err = stats.first_err or rm_err
			return false
		end
		return true
	end

	if kind == "blocked" then
		stats.failed = stats.failed + 1
		stats.first_err = stats.first_err or ("refuses to replace directory " .. target_of(ent))
		return false
	end

	if kind == "conflict" then
		if not approved[target_of(ent)] then
			stats.skipped = stats.skipped + 1
			return false
		end
		local ok, err = env.remove_existing(target_of(ent))
		if not ok then
			stats.failed = stats.failed + 1
			stats.first_err = stats.first_err or err
			return false
		end
	end

	local ok, err = env.restore(ent)
	if ok then
		stats.restored = stats.restored + 1
		return true
	end
	stats.failed = stats.failed + 1
	stats.first_err = stats.first_err or err
	return false
end

-- fs.trash.list/restore/remove consume the TrashEntry they receive; fs.trash.entry(ent) clones it, so reopen from that
local function snapshot(ent)
	return {
		entry = ent,
		original = tostring(ent.original),
		name = tostring(ent.name),
		is_dir = ent.lcha.is_dir,
		is_link = ent.lcha.is_link,
	}
end

local function reopen(node)
	return fs.trash.entry(node.entry)
end

local function real_env()
	return {
		cha = function(path)
			return fs.cha(Url(path), false)
		end,
		children = function(node)
			local list, err = fs.trash.list(reopen(node))
			if not list then
				return nil, err
			end
			local kids = {}
			for i, child in ipairs(list) do
				kids[i] = snapshot(child)
			end
			return kids
		end,
		restore = function(node)
			return fs.trash.restore { reopen(node) }
		end,
		remove_trash_dir = function(node)
			return fs.trash.remove("dir", reopen(node))
		end,
		remove_existing = function(path)
			local cha = fs.cha(Url(path), false)
			return fs.remove(cha.is_dir and "dir_all" or "file", Url(path))
		end,
	}
end

local function describe(ents, env)
	local shown = {}
	for i, ent in ipairs(ents) do
		local cha = env.cha(target_of(ent))
		shown[i] = { original = ent.original, is_dir = cha ~= nil and cha.is_dir, is_link = cha ~= nil and cha.is_link }
	end
	return shown
end

local function as_items(ents)
	local items = {}
	for i, e in ipairs(ents) do
		items[i] = { path = tostring(e.original), dir = e.is_dir, link = e.is_link }
	end
	return items
end

function M:entry()
	local tops, err = fs.trash.list()
	if not tops then
		return notify("cannot list trash: " .. tostring(err), "error")
	end

	local batch = {}
	if #tops > 0 then
		local out = Command("grep"):arg({ "-H", "^DeletionDate=", table.unpack(M.tops_paths(tops)) }):stdout(Command.PIPED):stderr(Command.NULL):output()
		batch = M.last_batch(tops, M.parse_dates(out and out.stdout))
		for i, ent in ipairs(batch) do
			batch[i] = snapshot(ent)
		end
	end
	if #batch == 0 then
		return notify("nothing to restore", "warn")
	end

	if not P.confirm_list(as_items(batch), string.format("Restore %d deleted item(s)?", #batch)) then
		return
	end

	local env = real_env()
	local blocked = {}
	for _, ent in ipairs(batch) do
		M.find_blocked(ent, env, blocked)
	end
	if #blocked > 0 then
		local title = string.format("%d item(s) refuse to replace a directory. Restore the rest?", #blocked)
		if not P.confirm_list(as_items(describe(blocked, env)), title) then
			return notify("cancelled, nothing restored", "warn")
		end
	end

	local conflicts = {}
	for _, ent in ipairs(batch) do
		M.find_conflicts(ent, env, conflicts)
	end

	local approved = {}
	if #conflicts > 0 then
		local shown = describe(conflicts, env)
		local files = 0
		for _, item in ipairs(shown) do
			if not item.is_link then
				files = files + 1
			end
		end
		local title = files > 0 and string.format("Overwrite %d existing item(s)? Files will be PERMANENTLY deleted.", #shown)
			or string.format("Replace %d symlink(s)? Only the links change; their targets are untouched.", #shown)
		local yes = P.confirm_list(as_items(shown), title)
		if yes then
			for _, ent in ipairs(conflicts) do
				approved[target_of(ent)] = true
			end
		end
	end

	local stats = { restored = 0, skipped = 0, failed = 0 }
	for _, ent in ipairs(batch) do
		M.apply(ent, env, approved, stats)
	end

	if stats.restored > 0 then
		ya.emit("refresh", {})
	end
	local msg = string.format("restored %d, skipped %d, failed %d", stats.restored, stats.skipped, stats.failed)
	if stats.failed > 0 then
		return notify(msg .. ": " .. tostring(stats.first_err), "error")
	end
	notify(msg)
end

function M.tops_paths(tops)
	local paths = {}
	for i, ent in ipairs(tops) do
		paths[i] = ent.top
	end
	return paths
end

return M
