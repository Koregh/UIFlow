local UI = require(game.ReplicatedStorage.UIFramework)

--  1. LOGGER

-- Root-level log
UI.Logger.info("Game loaded")

-- Child logger with fixed tag
local log = UI.Logger.child("ShopSystem", { version = "1.2" })
log.info("Shop opened", { player = "Alex", items = 42 })
log.warn("Low inventory", { item = "Sword", remaining = 2 })

-- Set global minimum level
UI.Logger.setLevel(UI.Types.LogLevel.WARN)  

-- Add a custom sink (e.g., send errors to a remote logging endpoint)
UI.Logger.addSink(function(entry)
	if entry.level >= UI.Types.LogLevel.ERROR then
		-- HttpService:PostAsync(endpoint, HttpService:JSONEncode(entry))
		print("[REMOTE LOG]", entry.levelName, entry.message)
	end
end)

-- Query log history
local recentErrors = UI.Logger.queryHistory({ level = UI.Types.LogLevel.ERROR })
print("Errors so far:", #recentErrors)

-- Wrap a function with automatic trace logging
local tracedFn = log.trace_call("initializeInventory", function(playerId)
	-- ... real work ...
	return true
end)
tracedFn("player_123")

--  2. METRICS

-- Counter: fire-and-forget
UI.Metrics.inc("shop.item.purchased", 1, "Items purchased in shop")
UI.Metrics.inc("shop.item.purchased")  -- defaults to +1

-- Gauge: current state
UI.Metrics.set("shop.active_sessions", 5, "Active shop sessions")
UI.Metrics.adjust("shop.active_sessions", 1)   -- += 1
UI.Metrics.adjust("shop.active_sessions", -1)  -- -= 1

-- Histogram: observe a distribution
UI.Metrics.observe("shop.purchase.latency_ms", 42.3, "Purchase latency")
UI.Metrics.observe("shop.purchase.latency_ms", 128)

-- Timer: stopwatch
local stopTimer = UI.Metrics.startTimer("shop.load.duration_ms", "Shop load time")
task.wait(0.5)  -- simulate work
local elapsed = stopTimer()  -- returns ms, records to timing metric
print("Load took:", elapsed, "ms")

-- Wrap function with automatic timing
local timedLoadInventory = UI.Metrics.timed("inventory.load_ms", function(playerId)
	task.wait(0.1)
	return { "sword", "shield" }
end)
timedLoadInventory("player_123")

-- Add a reporter (e.g., print every 60 seconds automatically)
UI.Metrics.setReportInterval(60)
UI.Metrics.addReporter(function(snapshot)
	for name, metric in pairs(snapshot.metrics) do
		if metric.kind == "TIMING" then
			print(name, "avg:", metric.avg_ms, "ms")
		end
	end
end)

-- Manual report
UI.Metrics.report()

-- Get timing summary programmatically
local summary = UI.Metrics.getTimingSummary("shop.load.duration_ms")
if summary then
	print("p99 shop load:", UI.Metrics.percentile("shop.load.duration_ms", 0.99))
end

--  3. SIGNAL BUS 

-- Subscribe (returns handle with .disconnect())
local handle = UI.Bus.on("player:levelUp", function(player, newLevel)
	print(player.Name, "reached level", newLevel)
end)

-- Priority: higher fires first
UI.Bus.on("player:levelUp", function(player, newLevel)
	-- UI update — should fire before sound effects
	print("Updating UI for level", newLevel)
end, { priority = 10 })

UI.Bus.on("player:levelUp", function()
	print("Playing level-up sound")
end, { priority = 5 })

-- Subscribe once
UI.Bus.once("tutorial:complete", function()
	print("Tutorial done — this fires only once")
end)

-- Filter: only fire if condition met
UI.Bus.on("item:dropped", function(item)
	print("RARE ITEM!", item.name)
end, {
	filter = function(item) return item.rarity == "legendary" end
})

-- Emit
UI.Bus.emit("player:levelUp", game.Players.LocalPlayer, 10)

-- Async emit (non-blocking subscriber)
UI.Bus.on("world:save", function()
	task.wait(2)  -- heavy work — won't block emitter
	print("Save complete")
end, { async = true })

-- waitFor (yields current coroutine until signal fires, with timeout)
task.spawn(function()
	local result = UI.Bus.waitFor("shop:itemLoaded", 5)  -- 5s timeout
	if result then
		print("Item loaded:", result)
	else
		print("Timeout waiting for item")
	end
end)

-- Middleware: intercept all emits
UI.Bus.use(function(signal, args)
	-- log all emits to metrics
	UI.Metrics.inc("signal." .. signal .. ".emit")
	return args  -- return modified args or nil to veto
end)

-- Disconnect
handle.disconnect()

-- Introspect
local info = UI.Bus.getChannelInfo("player:levelUp")
print("levelUp fired", info.emitCount, "times, subs:", info.activeSubs)

--  4. COMPONENT 

local myFrame = Instance.new("Frame")  -- normally this comes from the UI hierarchy

-- Full component with all hooks
local shopPanel = UI.Component.new(myFrame, function(state, api)

	-- useEffect with dep tracking: runs only when state.open changes
	api.useEffect(function()
		if state.open then
			print("Panel opened — start background music")
			return function()
				print("Panel closed — stop music (cleanup)")
			end
		end
	end, { state.open })

	-- useMemo: only recomputes when state.items changes
	local sortedItems = api.useMemo(function()
		local sorted = { table.unpack(state.items or {}) }
		table.sort(sorted, function(a, b) return a.price < b.price end)
		return sorted
	end, { state.items })

	-- Listen to external signals (auto-disconnected on unmount)
	api.on("economy:priceUpdate", function(newPrices)
		api.setState({ prices = newPrices })
	end)

	-- Return patch: { [instance] → props }
	-- Only changed props are tweened (reconciler diffs)
	return {
		[myFrame] = {
			BackgroundTransparency = state.open and 0 or 1,
			_duration = 0.3,
			_easing   = UI.Types.Easing.EASE_OUT,
		},
	}
end, {
	initialState  = { open = false, items = {}, prices = {} },
	name          = "ShopPanel",
	onMount       = function(comp)
		print("ShopPanel mounted, id:", comp.id)
	end,
	onUnmount     = function(comp)
		print("ShopPanel unmounted after", comp._renderCount, "renders")
	end,
	onError       = function(err, comp)
		UI.Logger.error("ShopPanel crashed: " .. err)
		-- could show fallback UI here
	end,
})

-- Mount triggers first render (via Scheduler)
shopPanel:mount()

-- setState is BATCHED: two calls in the same frame = ONE render
shopPanel:setState({ open = true })
shopPanel:setState({ items = { { name = "Sword", price = 100 } } })
-- → one render, with both state values merged

-- Read state
local currentState = shopPanel:getState()
print("Panel open:", currentState.open)

-- Force re-render without state change
shopPanel:forceUpdate()

-- Unmount: runs all effect cleanups, disconnects signals
shopPanel:unmount()

-- List all mounted components
local all = UI.Component.getAll()
for _, comp in ipairs(all) do
	print(comp.name, comp._lifecycle, "renders:", comp._renderCount)
end

-- Full debug report
UI.Component.report()

--  5. HOOKS STANDALONE 

-- useState: get, set, subscribe, destroy
local getCoins, setCoins, subCoins, destroyCoins = UI.Hooks.useState(0)

-- Functional update (like React's setState(prev => prev + 1))
setCoins(function(prev) return prev + 100 end)
setCoins(500)

-- Subscribe to changes
local sub = subCoins(function(newValue)
	print("Coins changed to:", newValue)
	-- update UI label
end)
sub.disconnect()  -- unsubscribe

-- useReducer
local function coinsReducer(state, action)
	if action.type == "ADD"   then return state + action.amount end
	if action.type == "RESET" then return 0 end
	return state
end

local getState, dispatch, _, destroyReducer = UI.Hooks.useReducer(coinsReducer, 0)
dispatch({ type = "ADD",   amount = 100 })
dispatch({ type = "ADD",   amount = 50  })
dispatch({ type = "RESET" })
print("Coins after reducer:", getState())
destroyReducer()

-- useEffect standalone
local effect = UI.Hooks.useEffect(function()
	print("Effect ran!")
	return function() print("Cleanup ran!") end
end, { "someValue" })

effect.updateDeps({ "newValue" })  -- triggers re-run + cleanup
effect.destroy()                   -- cleanup + teardown

-- useMemo
local memo = UI.Hooks.useMemo(function()
	return math.random(1, 100)  -- expensive computation
end, { "dep1" })

print("Memoized:", memo.value())  -- computes
print("Memoized:", memo.value())  -- returns cache (deps unchanged)
memo.invalidate()
print("Memoized:", memo.value())  -- recomputes
memo.destroy()

-- useDebounce
local getDebouncedSearch, setSearch = UI.Hooks.useDebounce("", 0.5)
setSearch("ro")   -- → no immediate update
setSearch("rob")  -- → resets 0.5s timer
setSearch("robl") -- → resets 0.5s timer; after 0.5s getDebouncedSearch() = "robl"

-- useThrottle
local throttledSave = UI.Hooks.useThrottle(function()
	print("Saving...")
end, 1.0)  -- at most once per second

-- useRef (mutable box, no re-render on change)
local ref = UI.Hooks.useRef(nil)
ref.current = myFrame  -- assign without triggering renders

--  6. RENDERER 

-- Simple tween
local handle = UI.Renderer.animate(myFrame, {
	Size     = UDim2.new(0.5, 0, 0.5, 0),
	Position = UDim2.new(0.25, 0, 0.25, 0),
}, {
	duration = 0.4,
	easing   = UI.Types.Easing.BACK_OUT,
})

-- Chain
handle:andThen(function()
	print("Animation done!")
end)

-- Cancel
handle:cancel()

-- Sequence (chainable, serial by default)
UI.Renderer.sequence()
	:add(myFrame, { Size = UDim2.new(0, 0, 0, 0)   }, { duration = 0.2 })
	:wait(0.1)
	:add(myFrame, { Size = UDim2.new(0.5, 0, 0.5, 0) }, { duration = 0.4, easing = UI.Types.Easing.BOUNCE })
	:call(function() UI.Bus.emit("animation:complete") end)
	:play(function() print("Sequence done!") end)

-- Open/close
UI.Renderer.open(myFrame, {
	fromPos    = UDim2.new(0.5, 0, 1.2, 0),
	toPos      = UDim2.new(0.5, 0, 0.5, 0),
	duration   = 0.4,
	fade       = true,
	signal     = "ui:shopOpened",
})

UI.Renderer.close(myFrame, {
	toPos    = UDim2.new(0.5, 0, 1.2, 0),
	duration = 0.3,
	fade     = true,
})

-- Loop
local loopId = UI.Renderer.loop(myFrame, {
	{ goals = { Rotation = 10 },  duration = 0.5, easing = UI.Types.Easing.SINE_IO },
	{ goals = { Rotation = -10 }, duration = 0.5, easing = UI.Types.Easing.SINE_IO },
}, { pingpong = false, onCycle = function(n) print("Cycle", n) end })

task.wait(3)
UI.Renderer.stopLoop(loopId)

--  7. PRESETS 

-- Enter animations
UI.Presets.bounceIn(myFrame, { duration = 0.45 })
UI.Presets.slideIn(myFrame, "bottom", { duration = 0.4 })
UI.Presets.slideOut(myFrame, "top")
UI.Presets.fadeIn(myFrame, { duration = 0.3 })
UI.Presets.fadeOut(myFrame)
UI.Presets.wipeIn(myFrame)

-- Feedback
UI.Presets.shake(myFrame, { strength = 8, count = 6 })
UI.Presets.pop(myFrame, { factor = 1.15 })
UI.Presets.flash(myFrame, { color = Color3.fromRGB(255, 80, 80) })

-- Looping (returns loopId)
local pulseId = UI.Presets.pulse(myFrame, { scale = 1.1, duration = 0.8 })
local floatId = UI.Presets.float(myFrame, { amount = 8,  duration = 1.5 })
local spinId  = UI.Presets.spin(myFrame,  { duration = 2 })

UI.Renderer.stopLoop(pulseId)
UI.Renderer.stopLoop(floatId)
UI.Renderer.stopLoop(spinId)

--  8. UTILS — formatting and typewriter

-- Number formatting
print(UI.Utils.Number.format(1500000, "comma"))      -- "1,500,000"
print(UI.Utils.Number.format(1500000, "short"))      -- "1.5M"
print(UI.Utils.Number.format(1500, "compact"))       -- "1.5k"
print(UI.Utils.Number.format(0.425, "percent"))      -- "42.5%"
print(UI.Utils.Number.format(42, "ordinal"))         -- "42nd"
print(UI.Utils.Number.format(9999, "currency", {
	symbol = "R$", groupSep = ".", decimalSep = ","  -- "R$ 9.999,00"
}))

-- Text formatting
local msg = UI.Utils.Text.format("Olá {player.name}, você tem {coins} moedas!", {
	player = { name = "Alex" },
	coins  = UI.Utils.Number.format(15000, "comma"),
})
print(msg)  -- "Olá Alex, você tem 15,000 moedas!"

-- With fallback: {missing|fallback}
print(UI.Utils.Text.format("Level: {level|???}", {}))  -- "Level: ???"

-- Truncate
print(UI.Utils.Text.truncate("This is a very long string", 15))  -- "This is a very…"

-- Plural
print(UI.Utils.Text.plural(1, "item"))    -- "1 item"
print(UI.Utils.Text.plural(3, "item"))    -- "3 items"

-- Typewriter
local label = Instance.new("TextLabel")
local tw = UI.Utils.Typewriter.write(label, "Bem-vindo ao jogo!", {
	speed      = 0.04,
	richText   = true,
	onChar     = function(char, idx) end,
	onComplete = function(lbl) print("Done!", lbl.Text) end,
	signal     = "ui:typeComplete",
})

-- Control
tw.pause()
task.wait(1)
tw.resume()
tw.skip()     -- jump to end immediately
-- tw.cancel()  -- clear and stop

-- Color utilities
UI.Utils.Color.set(myFrame, Color3.fromRGB(255, 100, 50), { duration = 0.3 })

local red   = UI.Utils.Color.fromHex("#FF5733")
local light = UI.Utils.Color.adjust(red, 1.5)  -- 50% brighter

-- Debris
UI.Utils.Debris.add(myFrame, 5, {
	tween = {
		goals = { BackgroundTransparency = 1 },
		opts  = { duration = 0.5 },
	},
	onExpire = function(inst) print("Destroyed:", inst.Name) end,
	signal   = "ui:debrisExpired",
})

--  ══════════════════════════════════════════════════════════
--  9. SCHEDULER — direct task control
--  ══════════════════════════════════════════════════════════

-- Schedule with priority
UI.Scheduler.schedule(function()
	print("IMMEDIATE task — runs this frame")
end, { priority = UI.Scheduler.Priority.IMMEDIATE })

UI.Scheduler.schedule(function()
	print("NORMAL task — runs next batch")
end)

-- Delayed
UI.Scheduler.scheduleAfter(2, function()
	print("Runs after 2 seconds")
end)

-- Cancellable
local taskHandle = UI.Scheduler.schedule(function()
	print("This might not run")
end, { priority = UI.Scheduler.Priority.LOW })

taskHandle.cancel()

-- Batch: multiple fns collapse into one flush
local batch = UI.Scheduler.batch()
batch.add(function() print("batch 1") end)
batch.add(function() print("batch 2") end)
batch.add(function() print("batch 3") end)
-- → all three run in a single scheduled task, next frame

--  ══════════════════════════════════════════════════════════
--  10. DEBUG PANEL (Studio only)
--  ══════════════════════════════════════════════════════════

-- In Studio console:
--   UIFramework.debug()
-- Prints: metrics report + component tree + signal channels + log history

-- Programmatic
UI.Logger.getHistory(20)  -- last 20 log entries
UI.Bus.getDeadLetters()   -- signals emitted with no subscribers
UI.Metrics.snapshot()     -- full metrics snapshot table
UI.Component.getAll()     -- all mounted components
UI.Scheduler.pendingCount()  -- tasks in queue
