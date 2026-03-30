local Types     = require(script.Parent.Types)
local Logger    = require(script.Parent.Logger)
local Metrics   = require(script.Parent.Metrics)
local Scheduler = require(script.Parent.Scheduler)

local log = Logger.child("Hooks")

local Hooks = {}

local function depsEqual(a, b)
	if a == nil and b == nil then return true  end
	if a == nil or  b == nil then return false end
	if #a ~= #b              then return false end
	for i, v in ipairs(a) do
		if v ~= b[i] then return false end
	end
	return true
end

function Hooks.useState(initial)
	local value     = initial
	local listeners = {}
	local id        = tostring({}):sub(8)

	Metrics.adjust("hooks.state.active", 1)

	local function notify()
		for _, entry in ipairs(listeners) do
			if entry.active then
				Scheduler.schedule(function()
					pcall(entry.fn, value)
				end, { priority = Scheduler.Priority.NORMAL })
			end
		end
	end

	local function get()
		return value
	end

	local function set(newValueOrFn)
		local newValue
		if type(newValueOrFn) == "function" then
			newValue = newValueOrFn(value)
		else
			newValue = newValueOrFn
		end

		if newValue == value then return end

		local prev = value
		value = newValue

		Metrics.inc("hooks.state.updates", 1)
		log.trace("State updated", { id = id, prev = tostring(prev), next = tostring(newValue) })

		notify()
	end

	local function subscribe(fn)
		assert(type(fn) == "function", "useState.subscribe: fn must be a function")
		local entry = { fn = fn, active = true }
		listeners[#listeners + 1] = entry
		Metrics.adjust("hooks.state.subscribers", 1)

		return {
			disconnect = function()
				entry.active = false
				Metrics.adjust("hooks.state.subscribers", -1)
			end
		}
	end

	local function destroy()
		listeners = {}
		Metrics.adjust("hooks.state.active", -1)
	end

	return get, set, subscribe, destroy
end

function Hooks.useReducer(reducer, initialState)
	assert(type(reducer) == "function", "useReducer: reducer must be a function")

	local get, set, subscribe, destroy = Hooks.useState(initialState)

	local function dispatch(action)
		local current  = get()
		local newState = reducer(current, action)
		set(newState)
		Metrics.inc("hooks.reducer.dispatches", 1)
		log.trace("Reducer dispatch", { action = action.type or tostring(action) })
	end

	return get, dispatch, subscribe, destroy
end

-- useEffect returns an extended handle that exposes depsChanged()
-- so Component._render can check before calling run().
function Hooks.useEffect(fn, deps)
	assert(type(fn) == "function", "useEffect: fn must be a function")

	local lastDeps  = nil
	local cleanupFn = nil
	local destroyed = false

	Metrics.adjust("hooks.effects.active", 1)

	local function runCleanup()
		if cleanupFn then
			local ok, err = pcall(cleanupFn)
			if not ok then
				log.error("useEffect cleanup threw", { error = err })
			end
			cleanupFn = nil
		end
	end

	local function hasDepsChanged()
		if destroyed   then return false end
		if deps == nil then return true  end  -- no dep array: always dirty
		if lastDeps == nil then return true end
		return not depsEqual(deps, lastDeps)
	end

	local function run()
		if destroyed then return end
		if not hasDepsChanged() then return end

		runCleanup()

		lastDeps = deps and { table.unpack(deps) } or nil

		local stopTimer = Metrics.startTimer("hooks.effect.duration_ms")
		local ok, result = pcall(fn)
		stopTimer()

		if not ok then
			log.error("useEffect fn threw", { error = result })
			Metrics.inc("hooks.effects.errors", 1)
			return
		end

		if type(result) == "function" then
			cleanupFn = result
		end

		Metrics.inc("hooks.effects.runs", 1)
	end

	run()

	return {
		run          = run,
		depsChanged  = hasDepsChanged,
		cleanup      = runCleanup,
		updateDeps   = function(newDeps)
			deps = newDeps
			run()
		end,
		destroy      = function()
			if destroyed then return end
			destroyed = true
			runCleanup()
			Metrics.adjust("hooks.effects.active", -1)
		end,
	}
end

function Hooks.useMemo(fn, deps)
	assert(type(fn) == "function", "useMemo: fn must be a function")

	local lastDeps  = nil
	local cached    = nil
	local valid     = false
	local destroyed = false

	Metrics.adjust("hooks.memo.active", 1)

	local function compute()
		if destroyed then return cached end

		if valid and deps ~= nil and depsEqual(deps, lastDeps) then
			Metrics.inc("hooks.memo.hits", 1)
			return cached
		end

		local stopTimer = Metrics.startTimer("hooks.memo.compute_ms")
		local ok, result = pcall(fn)
		stopTimer()

		if not ok then
			log.error("useMemo fn threw", { error = result })
			Metrics.inc("hooks.memo.errors", 1)
			return cached
		end

		cached   = result
		valid    = true
		lastDeps = deps and { table.unpack(deps) } or nil
		Metrics.inc("hooks.memo.misses", 1)

		return cached
	end

	return {
		value      = compute,
		invalidate = function() valid = false end,
		updateDeps = function(newDeps)
			deps = newDeps
		end,
		destroy    = function()
			destroyed = true
			Metrics.adjust("hooks.memo.active", -1)
		end,
	}
end

function Hooks.useCallback(fn, deps)
	assert(type(fn) == "function", "useCallback: fn must be a function")

	local memo = Hooks.useMemo(function() return fn end, deps)

	return {
		call       = function(...) return memo.value()(...) end,
		fn         = function()    return memo.value()      end,
		updateDeps = memo.updateDeps,
		destroy    = memo.destroy,
	}
end

function Hooks.useRef(initial)
	return { current = initial }
end

function Hooks.usePrevious(getterFn)
	local previous = nil
	local current  = getterFn()

	return {
		update = function()
			previous = current
			current  = getterFn()
		end,
		value = function()
			return previous
		end,
	}
end

function Hooks.useDebounce(initial, delay)
	local get, set, subscribe, destroy = Hooks.useState(initial)
	local timer = nil

	local function debouncedSet(value)
		if timer then
			task.cancel(timer)
		end
		timer = task.delay(delay or 0.3, function()
			timer = nil
			set(value)
		end)
	end

	return get, debouncedSet, subscribe, function()
		if timer then task.cancel(timer) end
		destroy()
	end
end

function Hooks.useThrottle(fn, interval)
	assert(type(fn) == "function", "useThrottle: fn must be a function")
	local lastCall = 0
	return function(...)
		local now = tick()
		if now - lastCall >= (interval or 0.1) then
			lastCall = now
			return fn(...)
		end
	end
end

return Hooks

-- useContext: read a context and subscribe to changes.
-- Re-runs the subscriber on every context change.
-- Returns the current value. For reactive updates wire into setState.
function Hooks.useContext(ctx)
	assert(type(ctx) == "table" and type(ctx.use) == "function",
		"useContext: expected a Context created with Context.create()")
	return ctx.use()
end

-- useBinding: thin wrapper around Binding.create for use inside render fns.
function Hooks.useBinding(initialValue)
	local Binding = require(script.Parent.Binding)
	return Binding.create(initialValue)
end
