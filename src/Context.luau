-- Allows passing values through the component tree without prop drilling.
--
-- Usage:
--   local ThemeContext = Context.create({ primary = Color3.new(1,1,1) })
--
--   -- Provider (parent component):
--   local cleanup = ThemeContext.provide({ primary = Color3.new(0,0,1) })
--   -- ... mount children ...
--   cleanup()   -- restore previous value on unmount
--
--   -- Consumer (any descendant):
--   local theme = ThemeContext.use()

local Logger  = require(script.Parent.Logger)
local Metrics = require(script.Parent.Metrics)

local log = Logger.child("Context")

local Context = {}

function Context.create(defaultValue)
	local ctx = {
		_current  = defaultValue,
		_stack    = {},
		_subs     = {},
	}

	-- Push a new value onto the context stack. Returns a cleanup function
	-- that pops it and notifies subscribers. Call this from a parent
	-- component's mount/useEffect, and return the cleanup.
	function ctx.provide(value)
		local stack = ctx._stack
		stack[#stack + 1] = ctx._current
		ctx._current = value

		-- notify subscribers
		for _, fn in ipairs(ctx._subs) do
			pcall(fn, value)
		end

		Metrics.inc("context.provide", 1)
		log.trace("Context provided", { depth = #stack })

		return function()
			ctx._current = stack[#stack]
			stack[#stack] = nil

			for _, fn in ipairs(ctx._subs) do
				pcall(fn, ctx._current)
			end

			log.trace("Context restored", { depth = #stack })
		end
	end

	-- Read the current context value.
	function ctx.use()
		return ctx._current
	end

	-- Subscribe to context changes. Returns a disconnect handle.
	function ctx.subscribe(fn)
		assert(type(fn) == "function", "Context.subscribe: fn must be a function")
		ctx._subs[#ctx._subs + 1] = fn
		Metrics.adjust("context.subscribers", 1)

		return {
			disconnect = function()
				for i, s in ipairs(ctx._subs) do
					if s == fn then
						table.remove(ctx._subs, i)
						Metrics.adjust("context.subscribers", -1)
						break
					end
				end
			end
		}
	end

	-- useContext: subscribe AND get current value. Integrates with Hooks.useState
	-- so the caller re-renders on context change.
	-- Returns: get, unsubscribe
	function ctx.useContext()
		local sub = ctx.subscribe(function() end)
		return ctx._current, sub.disconnect
	end

	return ctx
end

return Context
