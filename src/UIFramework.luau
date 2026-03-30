--[[
  ════════════════════════════════════════════════════════════
  UIFramework  —  init.lua  (root module)
  ════════════════════════════════════════════════════════════
  
  ARCHITECTURE OVERVIEW
  ─────────────────────
  
  ┌─────────────────────────────────────────────────────┐
  │                   UIFramework (facade)               │
  │   Single public surface — consumers require this    │
  └────────────┬────────────────────────────────────────┘
               │
    ┌──────────▼──────────────────────────────────────┐
    │  Scheduler  (batched priority task queue)        │
    │  - Prevents multiple renders per frame           │
    │  - Frame budget enforcement                      │
    └──────────┬──────────────────────────────────────┘
               │
    ┌──────────▼──────────────────────────────────────┐
    │  SignalBus  (decoupled pub/sub communication)    │
    │  - Components never reference each other         │
    │  - Middleware, priority, waitFor, dead letters   │
    └──────────┬──────────────────────────────────────┘
               │
    ┌──────────▼──────────────────────────────────────┐
    │  Component  (fiber + reconciler)                 │
    │  - Full lifecycle: mount → update → unmount      │
    │  - Batched setState (one render per frame)       │
    │  - Error boundaries                              │
    └──────────┬──────────────────────────────────────┘
               │
    ┌──────────▼──────────────────────────────────────┐
    │  Renderer  (tween engine + loop manager)         │
    │  - Sequence/parallel animation pipeline          │
    │  - Diff-based property patching (reconciler)     │
    └─────────────────────────────────────────────────┘
    
    Cross-cutting:
      Logger   — structured, leveled, tagged, with ring buffer
      Metrics  — counters, gauges, histograms, timers, reporters
      Hooks    — useState, useEffect, useMemo, useRef (real deps)
      Utils    — number/text formatting, typewriter, color, debris
      Presets  — named animation presets
      Types    — shared contracts (no deps)

  DESIGN PRINCIPLES
  ─────────────────
    S — each module has ONE reason to change
    O — extend via sinks/reporters/middleware, not by editing core
    L — AnimationHandle and ComponentHandle are substitutable
    I — consumers only import what they need (not a monolith)
    D — all modules depend on Types, not on each other directly

  USAGE EXAMPLE
  ─────────────
  local UI = require(path.to.UIFramework)

  -- configure
  UI.Logger.setLevel(UI.Types.LogLevel.DEBUG)
  UI.Metrics.setReportInterval(30)

  -- create a component
  local comp = UI.Component.new(myFrame, function(state, api)
    api.useEffect(function()
      print("mounted!")
      return function() print("cleanup") end
    end, {})
    return {
      [myFrame.Title] = {
        TextColor3 = state.active and Color3.new(1,1,0) or Color3.new(1,1,1),
        _duration  = 0.3,
      }
    }
  end, { initialState = { active = false } })

  comp:mount()
  comp:setState({ active = true })
  comp:unmount()

  -- signals
  UI.Bus.on("player:died", function(player) ... end)
  UI.Bus.emit("player:died", player)

  -- animations
  UI.Renderer.animate(frame, { Size = UDim2.new(1,0,1,0) }, { duration = 0.5 })
  UI.Presets.bounceIn(frame)
  UI.Presets.shake(frame, { strength = 10 })
  
  -- hooks standalone
  local get, set, sub = UI.Hooks.useState(0)
  set(42)
  sub(function(v) print("changed to", v) end)
  ════════════════════════════════════════════════════════════
--]]

local RunService = game:GetService("RunService")

-- ── Core modules (load order matters — no circular deps) ──────────────────
local Types     = require(script.core.Types)
local Logger    = require(script.logger.Logger)
local Metrics   = require(script.metrics.Metrics)
local SignalBus = require(script.signals.SignalBus)
local Scheduler = require(script.scheduler.Scheduler)
local Renderer  = require(script.renderer.Renderer)
local Hooks     = require(script.hooks.Hooks)
local Component = require(script.core.Component)
local Presets   = require(script.presets.Presets)
local Utils     = require(script.utils.Utils)

-- ── FRAMEWORK ROOT ────────────────────────────────────────────────────────

local UIFramework = {
	-- Namespaced modules (consumers can also require individually)
	Types     = Types,
	Logger    = Logger,
	Metrics   = Metrics,
	Bus       = SignalBus,
	Scheduler = Scheduler,
	Renderer  = Renderer,
	Hooks     = Hooks,
	Component = Component,
	Presets   = Presets,
	Utils     = Utils,

	-- Version
	VERSION   = "2.0.0",
}

-- ── CONVENIENCE ALIASES  (backward-compatible with original UIController) ─

--- Open a frame with animation.
UIFramework.open     = Renderer.open
UIFramework.close    = Renderer.close
UIFramework.toggle   = Renderer.toggle

--- Generic animate.
UIFramework.animate  = Renderer.animate

--- Loop animate.
UIFramework.loop     = Renderer.loop
UIFramework.stopLoop = Renderer.stopLoop

--- Signal bus shortcuts.
UIFramework.on       = function(...) return SignalBus.on(...) end
UIFramework.once     = function(...) return SignalBus.once(...) end
UIFramework.emit     = function(...) return SignalBus.emit(...) end
UIFramework.waitFor  = function(...) return SignalBus.waitFor(...) end

--- Component factory shortcut.
UIFramework.mount    = function(frame, renderFn, opts)
	local comp = Component.new(frame, renderFn, opts)
	comp:mount()
	return comp
end

--- Hooks shortcuts.
UIFramework.useState    = Hooks.useState
UIFramework.useEffect   = Hooks.useEffect
UIFramework.useMemo     = Hooks.useMemo
UIFramework.useReducer  = Hooks.useReducer
UIFramework.useRef      = Hooks.useRef

--- Formatting shortcuts.
UIFramework.formatNumber = Utils.Number.format
UIFramework.formatText   = Utils.Text.format

--- Typewriter shortcut.
UIFramework.typewrite    = Utils.Typewriter.write

--- Debris shortcut.
UIFramework.debris       = Utils.Debris.add

-- ── RUNSERVICE INTEGRATION ────────────────────────────────────────────────
-- Heartbeat drives: Metrics auto-reporting, Scheduler idle lane

local _heartbeatConn = RunService.Heartbeat:Connect(function(dt)
	-- Metrics tick (auto-flush to reporters if interval set)
	Metrics._tick(dt)

	-- Flush any remaining idle-priority tasks
	if Scheduler.pendingCount() > 0 then
		Scheduler._flushPriority(Scheduler.Priority.IDLE)
	end
end)

-- ── FRAMEWORK INITIALIZATION LOG ─────────────────────────────────────────

local log = Logger.child("UIFramework")

log.info("UIFramework initialized", {
	version    = UIFramework.VERSION,
	environment = RunService:IsServer() and "server" or "client",
})

-- ── GLOBAL DEBUG COMMANDS  (Studio only) ─────────────────────────────────

if RunService:IsStudio() then
	-- UIFramework.debug() prints a full runtime report
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

	-- hook into global for quick Studio console access
	_G.UIFramework = UIFramework
end

-- ── TEARDOWN (optional cleanup on game close) ─────────────────────────────

game:BindToClose(function()
	log.info("UIFramework shutting down")
	Component.unmountAll()
	Renderer.stopAllLoops()
	_heartbeatConn:Disconnect()
	Metrics.flush()
	log.info("UIFramework shutdown complete")
end)

return UIFramework
