local RunService = game:GetService("RunService")

local Types        = require(script.Types)
local Logger       = require(script.Logger)
local Metrics      = require(script.Metrics)
local SignalBus    = require(script.SignalBus)
local Scheduler    = require(script.Scheduler)
local Renderer     = require(script.Renderer)
local Hooks        = require(script.Hooks)
local Component    = require(script.Component)
local Presets      = require(script.Presets)
local Utils        = require(script.Utils)
local Context      = require(script.Context)
local Binding      = require(script.Binding)
local Memo         = require(script.Memo)
local EventMarkers = require(script.EventMarkers)

local UIFramework = {
	Types        = Types,
	Logger       = Logger,
	Metrics      = Metrics,
	Bus          = SignalBus,
	Scheduler    = Scheduler,
	Renderer     = Renderer,
	Hooks        = Hooks,
	Component    = Component,
	Presets      = Presets,
	Utils        = Utils,
	Context      = Context,
	Binding      = Binding,
	Memo         = Memo,
	Event        = EventMarkers.Event,
	Change       = EventMarkers.Change,
	VERSION      = "3.0.0",
}

-- Renderer shortcuts
UIFramework.open     = Renderer.open
UIFramework.close    = Renderer.close
UIFramework.toggle   = Renderer.toggle
UIFramework.animate  = Renderer.animate
UIFramework.loop     = Renderer.loop
UIFramework.stopLoop = Renderer.stopLoop

-- SignalBus shortcuts
UIFramework.on      = function(...) return SignalBus.on(...) end
UIFramework.once    = function(...) return SignalBus.once(...) end
UIFramework.emit    = function(...) return SignalBus.emit(...) end
UIFramework.waitFor = function(...) return SignalBus.waitFor(...) end

-- Component shortcut
UIFramework.mount = function(frame, renderFn, opts)
	local comp = Component.new(frame, renderFn, opts)
	comp:mount()
	return comp
end

-- Hooks shortcuts
UIFramework.useState    = Hooks.useState
UIFramework.useEffect   = Hooks.useEffect
UIFramework.useMemo     = Hooks.useMemo
UIFramework.useReducer  = Hooks.useReducer
UIFramework.useRef      = Hooks.useRef
UIFramework.useContext  = Hooks.useContext
UIFramework.useBinding  = Hooks.useBinding
UIFramework.useDebounce = Hooks.useDebounce
UIFramework.useThrottle = Hooks.useThrottle

-- Context shortcut
UIFramework.createContext = Context.create

-- Binding shortcuts
UIFramework.createBinding = Binding.create
UIFramework.joinBindings  = Binding.join
UIFramework.linkBinding   = Binding.link

-- Memo shortcuts
UIFramework.memo       = Memo.wrap
UIFramework.forwardRef = Memo.forwardRef

-- Utils shortcuts
UIFramework.formatNumber = Utils.Number.format
UIFramework.formatText   = Utils.Text.format
UIFramework.typewrite    = Utils.Typewriter.write
UIFramework.debris       = Utils.Debris.add

local _heartbeatConn = RunService.Heartbeat:Connect(function(dt)
	Metrics._tick(dt)
	if Scheduler.pendingCount() > 0 then
		Scheduler._flushPriority(Scheduler.Priority.IDLE)
	end
end)

local log = Logger.child("UIFramework")
log.info("UIFramework initialized", {
	version     = UIFramework.VERSION,
	environment = RunService:IsServer() and "server" or "client",
})

if RunService:IsStudio() then
	function UIFramework.debug()
		print("\n")
		Metrics.report()
		Component.report()
		print("\n[SignalBus Channels]")
		for _, ch in ipairs(SignalBus.getAllChannels()) do
			print(string.format("  %-30s emits=%-5d subs=%d", ch.name, ch.emitCount, ch.activeSubs))
		end
		print("\n[Scheduler Pending]", Scheduler.pendingCount(), "tasks")
		print("\n[Logger History] last 10:")
		for _, entry in ipairs(Logger.getHistory(10)) do
			print(string.format("  [%s] [%s] %s", entry.levelName, entry.tag or "-", entry.message))
		end
	end

	_G.UIFramework = UIFramework
end

game:BindToClose(function()
	log.info("UIFramework shutting down")
	Component.unmountAll()
	Renderer.stopAllLoops()
	_heartbeatConn:Disconnect()
	Metrics.flush()
	log.info("UIFramework shutdown complete")
end)

return UIFramework
