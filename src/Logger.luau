local Types   = require(script.Parent.Parent.core.Types)
local HttpSvc = game:GetService("HttpService")

local Logger = {}
Logger.__index = Logger

--  DEFAULTS
local DEFAULT_LEVEL   = Types.LogLevel.DEBUG
local RING_BUFFER_MAX = 500  -- last N log entries kept in memory

--  ANSI-style color tags for Roblox output 
local LEVEL_PREFIX = {
	[Types.LogLevel.TRACE] = "[TRACE]",
	[Types.LogLevel.DEBUG] = "[DEBUG]",
	[Types.LogLevel.INFO]  = "[ INFO]",
	[Types.LogLevel.WARN]  = "[ WARN]",
	[Types.LogLevel.ERROR] = "[ERROR]",
	[Types.LogLevel.FATAL] = "[FATAL]",
}

-- Which native Roblox output fn maps to which level
local LEVEL_OUTPUT = {
	[Types.LogLevel.TRACE] = print,
	[Types.LogLevel.DEBUG] = print,
	[Types.LogLevel.INFO]  = print,
	[Types.LogLevel.WARN]  = warn,
	[Types.LogLevel.ERROR] = warn,
	[Types.LogLevel.FATAL] = error,
}

--  INTERNAL SINGLETON STATE
local _minLevel   = DEFAULT_LEVEL
local _tagFilters = {}   -- set of tag strings; empty = allow all
local _sinks      = {}   -- array of sink fns: (entry) → void
local _history    = {}   -- ring buffer
local _historyIdx = 0
local _enabled    = true

--  HELPERS
local function uid8()
	return HttpSvc:GenerateGUID(false):sub(1, 8)
end

local function timestamp()
	return tick()
end

local function formatMessage(level, tag, msg, ctx)
	local prefix = LEVEL_PREFIX[level] or "[?????]"
	local tagStr = tag and ("[" .. tag .. "] ") or ""
	local ctxStr = ""
	if ctx then
		local parts = {}
		for k, v in pairs(ctx) do
			parts[#parts + 1] = k .. "=" .. tostring(v)
		end
		if #parts > 0 then
			ctxStr = " {" .. table.concat(parts, ", ") .. "}"
		end
	end
	return string.format("%.4f %s %s%s%s", timestamp(), prefix, tagStr, tostring(msg), ctxStr)
end

local function pushHistory(entry)
	_historyIdx = (_historyIdx % RING_BUFFER_MAX) + 1
	_history[_historyIdx] = entry
end

--  CORE LOG FUNCTION
local function log(level, tag, msg, ctx)
	if not _enabled then return end
	if level < _minLevel then return end

	-- tag filter: if any filter set, tag must be in it
	if next(_tagFilters) ~= nil then
		if not tag or not _tagFilters[tag] then return end
	end

	local entry = {
		id        = uid8(),
		level     = level,
		levelName = Types.LogLevelName[level],
		tag       = tag,
		message   = tostring(msg),
		context   = ctx,
		timestamp = timestamp(),
	}

	pushHistory(entry)

	local formatted = formatMessage(level, tag, msg, ctx)

	-- route to native output
	local outputFn = LEVEL_OUTPUT[level] or print
	if level == Types.LogLevel.FATAL then
		-- non-crashing fatal: use error but pcall-safe for sink delivery
		pcall(function()
			for _, sink in ipairs(_sinks) do
				pcall(sink, entry)
			end
		end)
		outputFn("[UIFramework FATAL] " .. formatted, 2)
		return
	end

	outputFn("[UIFramework] " .. formatted)

	-- dispatch to all registered sinks
	for _, sink in ipairs(_sinks) do
		pcall(sink, entry)  -- isolated: a bad sink never kills the logger
	end
end

--- Set minimum log level. Entries below this are silently dropped.
function Logger.setLevel(level)
	assert(type(level) == "number", "Logger.setLevel: level must be a number from Types.LogLevel")
	_minLevel = level
end

function Logger.getLevel()
	return _minLevel
end

--- Add a tag to the allowlist. If any tags are allowed, only those pass.
function Logger.allowTag(tag)
	_tagFilters[tag] = true
end

--- Remove a tag from the allowlist.
function Logger.denyTag(tag)
	_tagFilters[tag] = nil
end

--- Clear all tag filters (allow everything).
function Logger.clearTagFilters()
	_tagFilters = {}
end

--- Register a sink function. Receives every log entry table.
--- Returns a handle with :remove()
function Logger.addSink(fn)
	assert(type(fn) == "function", "Logger.addSink: sink must be a function")
	local sink = { fn = fn, active = true }
	_sinks[#_sinks + 1] = fn
	return {
		remove = function()
			for i, s in ipairs(_sinks) do
				if s == fn then
					table.remove(_sinks, i)
					break
				end
			end
		end
	}
end

--- Enable or disable the logger entirely.
function Logger.setEnabled(v)
	_enabled = v
end

--- Return a copy of the ring buffer (newest-first).
function Logger.getHistory(maxEntries)
	local out = {}
	local count = math.min(maxEntries or RING_BUFFER_MAX, #_history)
	-- walk backwards from current index
	for i = 1, count do
		local idx = ((_historyIdx - i - 1) % RING_BUFFER_MAX) + 1
		if _history[idx] then
			out[#out + 1] = _history[idx]
		end
	end
	return out
end

--- Filter history by level and/or tag.
function Logger.queryHistory(opts)
	opts = opts or {}
	local all = Logger.getHistory()
	local out = {}
	for _, entry in ipairs(all) do
		local levelOk = not opts.level or entry.level >= opts.level
		local tagOk   = not opts.tag   or entry.tag == opts.tag
		if levelOk and tagOk then
			out[#out + 1] = entry
		end
	end
	return out
end

--- Create a child logger with a fixed tag and optional extra context.
--- Useful for per-module / per-component loggers.
function Logger.child(tag, baseCtx)
	local child = {}

	local function merged(ctx)
		if not baseCtx then return ctx end
		local m = {}
		for k, v in pairs(baseCtx) do m[k] = v end
		if ctx then
			for k, v in pairs(ctx) do m[k] = v end
		end
		return m
	end

	function child.trace(msg, ctx) log(Types.LogLevel.TRACE, tag, msg, merged(ctx)) end
	function child.debug(msg, ctx) log(Types.LogLevel.DEBUG, tag, msg, merged(ctx)) end
	function child.info (msg, ctx) log(Types.LogLevel.INFO,  tag, msg, merged(ctx)) end
	function child.warn (msg, ctx) log(Types.LogLevel.WARN,  tag, msg, merged(ctx)) end
	function child.error(msg, ctx) log(Types.LogLevel.ERROR, tag, msg, merged(ctx)) end
	function child.fatal(msg, ctx) log(Types.LogLevel.FATAL, tag, msg, merged(ctx)) end

	--- Wrap a function: logs entry/exit + duration + errors.
	function child.trace_call(name, fn)
		return function(...)
			child.trace("→ " .. name .. " called")
			local t0 = tick()
			local ok, result = pcall(fn, ...)
			local dt = tick() - t0
			if ok then
				child.trace("← " .. name .. " returned", { duration_ms = math.floor(dt * 1000) })
			else
				child.error("✗ " .. name .. " threw: " .. tostring(result), { duration_ms = math.floor(dt * 1000) })
			end
			if not ok then error(result, 2) end
			return result
		end
	end

	return child
end

-- Root-level convenience methods
function Logger.trace(msg, ctx) log(Types.LogLevel.TRACE, nil, msg, ctx) end
function Logger.debug(msg, ctx) log(Types.LogLevel.DEBUG, nil, msg, ctx) end
function Logger.info (msg, ctx) log(Types.LogLevel.INFO,  nil, msg, ctx) end
function Logger.warn (msg, ctx) log(Types.LogLevel.WARN,  nil, msg, ctx) end
function Logger.error(msg, ctx) log(Types.LogLevel.ERROR, nil, msg, ctx) end
function Logger.fatal(msg, ctx) log(Types.LogLevel.FATAL, nil, msg, ctx) end

return Logger
