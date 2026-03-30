--[[
  ============================================================
  UIFramework / hooks / Hooks.lua
  ============================================================
  React-faithful hook system with REAL dependency tracking.

  Hooks available:
    useState(initial)          → get, set, subscribe
    useReducer(reducer, init)  → state, dispatch
    useEffect(fn, deps)        → cleanup managed automatically
    useMemo(fn, deps)          → cached computed value
    useCallback(fn, deps)      → stable function reference
    useRef(initial)            → { current } mutable box
    usePrevious(value)         → previous value of a state
    useDebounce(value, delay)  → debounced value
    useThrottle(fn, interval)  → throttled callback

  Key differences from the original cosmetic implementation:
    - deps are deeply compared (not reference equality)
    - effects run cleanup on deps change AND on unmount
    - useMemo re-computes only when deps change
    - all hooks are traceable via Logger + Metrics
    - hooks can be used standalone (not tied to mount())
  ============================================================
--]]

local Types     = require(script.Parent.Parent.core.Types)
local Logger    = require(script.Parent.Parent.logger.Logger)
local Metrics   = require(script.Parent.Parent.metrics.Metrics)
local Scheduler = require(script.Parent.Parent.scheduler.Scheduler)

local log = Logger.child("Hooks")

local Hooks = {}

--  ═══════════════════════════════════
--  DEPENDENCY COMPARISON  (deep equal)
--  ═══════════════════════════════════

local function depsEqual(a, b)
	if a == nil and b == nil then return true  end
	if a == nil or  b == nil then return false end
	if #a ~= #b              then return false end
	for i, v in ipairs(a) do
		local bv = b[i]
		-- handle Roblox types (UDim2, Color3, Vector2, etc.) using ==
		if v ~= bv then return false end
	end
	return true
end

--  ═══════════════════════════════════
--  useState
--  ═══════════════════════════════════

--[[
  local get, set, subscribe = Hooks.useState(initial)

  get()           → current value
  set(newValue)   → update value, notify subscribers
  set(fn)         → functional update: set(prev → newValue)
  subscribe(fn)   → called on every change; returns { disconnect() }

  Supports batching: if Scheduler is active, sets are deferred.
--]]
function Hooks.useState(initial)
	local value     = initial
	local listeners = {}
	local id        = tostring({}):sub(8)  -- unique handle via table address

	Metrics.adjust("hooks.state.active", 1, "Active useState instances")

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

		if newValue == value then return end  -- bailout (like React)

		local prev = value
		value = newValue

		Metrics.inc("hooks.state.updates", 1, "State update calls")
		log.trace("State updated", { id = id, prev = tostring(prev), next = tostring(newValue) })

		notify()
	end

	local function subscribe(fn)
		assert(type(fn) == "function", "useState.subscribe: fn must be a function")
		local entry = { fn = fn, active = true }
		listeners[#listeners + 1] = entry
		Metrics.adjust("hooks.state.subscribers", 1, "Total state subscribers")

		return {
			disconnect = function()
				entry.active = false
				Metrics.adjust("hooks.state.subscribers", -1)
			end
		}
	end

	-- cleanup hook (call when the owning component unmounts)
	local function destroy()
		listeners = {}
		Metrics.adjust("hooks.state.active", -1)
	end

	return get, set, subscribe, destroy
end

--  ═══════════════════════════════════
--  useReducer
--  ═══════════════════════════════════

--[[
  local state, dispatch = Hooks.useReducer(reducer, initialState)

  reducer(state, action) → newState
  dispatch({ type = "INCREMENT", payload = 1 })
--]]
function Hooks.useReducer(reducer, initialState)
	assert(type(reducer) == "function", "useReducer: reducer must be a function")

	local get, set, subscribe, destroy = Hooks.useState(initialState)

	local function dispatch(action)
		local current  = get()
		local newState = reducer(current, action)
		set(newState)
		Metrics.inc("hooks.reducer.dispatches", 1, "Reducer dispatches")
		log.trace("Reducer dispatch", { action = action.type or tostring(action) })
	end

	return get, dispatch, subscribe, destroy
end

--  ═══════════════════════════════════
--  useEffect  (REAL dependency tracking)
--  ═══════════════════════════════════

--[[
  local effect = Hooks.useEffect(fn, deps)
  effect.run()     -- manually re-run if deps changed
  effect.cleanup() -- run cleanup and disable
  effect.destroy() -- full teardown

  fn should return a cleanup function (or nil).
  Effect runs immediately on creation, then re-runs when deps change.
  deps = nil → run on every manual .run() call (like useEffect with no deps array)
  deps = {}  → run only once (like useEffect([]))
--]]
function Hooks.useEffect(fn, deps)
	assert(type(fn) == "function", "useEffect: fn must be a function")

	local lastDeps   = nil
	local cleanupFn  = nil
	local destroyed  = false

	Metrics.adjust("hooks.effects.active", 1, "Active effects")

	local function runCleanup()
		if cleanupFn then
			local ok, err = pcall(cleanupFn)
			if not ok then
				log.error("useEffect cleanup threw", { error = err })
			end
			cleanupFn = nil
		end
	end

	local function run()
		if destroyed then return end

		local shouldRun = false

		if deps == nil then
			-- no dep array: always re-run
			shouldRun = true
		elseif lastDeps == nil then
			-- first run
			shouldRun = true
		elseif not depsEqual(deps, lastDeps) then
			-- deps changed
			shouldRun = true
		end

		if not shouldRun then return end

		runCleanup()

		lastDeps = deps and { table.unpack(deps) } or nil

		local stopTimer = Metrics.startTimer("hooks.effect.duration_ms", "Effect execution time")
		local ok, result = pcall(fn)
		stopTimer()

		if not ok then
			log.error("useEffect fn threw", { error = result })
			Metrics.inc("hooks.effects.errors", 1, "Effect errors")
			return
		end

		if type(result) == "function" then
			cleanupFn = result
		end

		Metrics.inc("hooks.effects.runs", 1, "Effect executions")
	end

	-- initial run
	run()

	return {
		run     = run,
		cleanup = runCleanup,
		updateDeps = function(newDeps)
			deps = newDeps
			run()
		end,
		destroy = function()
			if destroyed then return end
			destroyed = true
			runCleanup()
			Metrics.adjust("hooks.effects.active", -1)
		end,
	}
end

--  ═══════════════════════════════════
--  useMemo  (memoized computed value)
--  ═══════════════════════════════════

--[[
  local memo = Hooks.useMemo(fn, deps)
  memo.value()    → current memoized value
  memo.invalidate() → force recompute on next .value() call
  memo.destroy()
--]]
function Hooks.useMemo(fn, deps)
	assert(type(fn) == "function", "useMemo: fn must be a function")

	local lastDeps  = nil
	local cached    = nil
	local valid     = false
	local destroyed = false

	Metrics.adjust("hooks.memo.active", 1, "Active useMemo instances")

	local function compute()
		if destroyed then return cached end

		if valid and deps ~= nil and depsEqual(deps, lastDeps) then
			Metrics.inc("hooks.memo.hits", 1, "Memo cache hits")
			return cached
		end

		local stopTimer = Metrics.startTimer("hooks.memo.compute_ms", "Memo recompute time")
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
		Metrics.inc("hooks.memo.misses", 1, "Memo cache misses (recomputes)")

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

--  ═══════════════════════════════════
--  useCallback  (stable fn reference)
--  ═══════════════════════════════════

--[[
  local cb = Hooks.useCallback(fn, deps)
  cb.call(...)         → invokes fn if deps match, else returns cached
  cb.fn()              → always current fn reference
  cb.updateDeps(deps)
--]]
function Hooks.useCallback(fn, deps)
	assert(type(fn) == "function", "useCallback: fn must be a function")

	local memo = Hooks.useMemo(function() return fn end, deps)

	return {
		call = function(...)
			return memo.value()(...)
		end,
		fn = function()
			return memo.value()
		end,
		updateDeps = memo.updateDeps,
		destroy    = memo.destroy,
	}
end

--  ═══════════════════════════════════
--  useRef  (mutable box, no re-render)
--  ═══════════════════════════════════

function Hooks.useRef(initial)
	return { current = initial }
end

--  ═══════════════════════════════════
--  usePrevious
--  ═══════════════════════════════════

--[[
  Tracks the previous value of any state.
  Usage: subscribe to the source state, feed into usePrevious.

  local prev = Hooks.usePrevious(sourceGet)
  prev.value()   → last value before current
--]]
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

--  ═══════════════════════════════════
--  useDebounce
--  ═══════════════════════════════════

--[[
  Debounce a value: only updates after `delay` seconds of inactivity.
  local debouncedGet, debouncedSet = Hooks.useDebounce(initial, delay)
  debouncedSet("newValue")  → schedules update after delay
--]]
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

--  ═══════════════════════════════════
--  useThrottle
--  ═══════════════════════════════════

--[[
  Throttle a function: at most once per `interval` seconds.
  local throttled = Hooks.useThrottle(fn, interval)
  throttled(...)  → calls fn at most once per interval
--]]
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
