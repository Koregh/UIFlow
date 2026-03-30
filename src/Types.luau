local Types = {}

--  COMPONENT LIFECYCLE STATES
Types.LifecycleState = {
	IDLE       = "IDLE",
	MOUNTING   = "MOUNTING",
	MOUNTED    = "MOUNTED",
	UPDATING   = "UPDATING",
	UNMOUNTING = "UNMOUNTING",
	UNMOUNTED  = "UNMOUNTED",
	ERROR      = "ERROR",
}

--  ANIMATION EASING PRESETS
Types.Easing = {
	LINEAR   = { style = Enum.EasingStyle.Linear,   dir = Enum.EasingDirection.In    },
	EASE_IN  = { style = Enum.EasingStyle.Quart,    dir = Enum.EasingDirection.In    },
	EASE_OUT = { style = Enum.EasingStyle.Quart,    dir = Enum.EasingDirection.Out   },
	EASE_IO  = { style = Enum.EasingStyle.Quart,    dir = Enum.EasingDirection.InOut },
	BACK_OUT = { style = Enum.EasingStyle.Back,     dir = Enum.EasingDirection.Out   },
	ELASTIC  = { style = Enum.EasingStyle.Elastic,  dir = Enum.EasingDirection.Out   },
	BOUNCE   = { style = Enum.EasingStyle.Bounce,   dir = Enum.EasingDirection.Out   },
	SINE_IO  = { style = Enum.EasingStyle.Sine,     dir = Enum.EasingDirection.InOut },
	SPRING   = { style = Enum.EasingStyle.Back,     dir = Enum.EasingDirection.Out   },
}

--  LOG LEVELS  (ordered severity)
Types.LogLevel = {
	TRACE = 0,
	DEBUG = 1,
	INFO  = 2,
	WARN  = 3,
	ERROR = 4,
	FATAL = 5,
}

Types.LogLevelName = {
	[0] = "TRACE",
	[1] = "DEBUG",
	[2] = "INFO",
	[3] = "WARN",
	[4] = "ERROR",
	[5] = "FATAL",
}

--  METRIC KINDS
Types.MetricKind = {
	COUNTER   = "COUNTER",    -- monotonically increasing (renders, signal fires)
	GAUGE     = "GAUGE",      -- point-in-time value (mounted components, active loops)
	HISTOGRAM = "HISTOGRAM",  -- distribution (tween durations, render times)
	TIMING    = "TIMING",     -- start/stop stopwatch
}

--  SIGNAL SUBSCRIPTION CONTRACT
-- { Disconnect: () → void, id: string }

--  TWEEN HANDLE CONTRACT
-- { cancel: () → void, andThen: (fn) → self, tween: Tween }

--  COMPONENT CONTRACT
--[[
  {
    id         : string,
    frame      : Instance,
    state      : table,
    lifecycle  : LifecycleState,
    setState   : (patch: table) → void,
    getState   : () → table,
    unmount    : () → void,
    forceUpdate: () → void,
  }
--]]

--  EFFECT RECORD CONTRACT
--[[
  {
    deps    : table | nil,
    cleanup : () → void | nil,
    lastDeps: table | nil,
  }
--]]

--  OPEN / CLOSE OPTS CONTRACT
--[[
  {
    duration    : number?,
    style       : Enum.EasingStyle?,
    direction   : Enum.EasingDirection?,
    delay       : number?,
    fromSize    : UDim2?,
    toSize      : UDim2?,
    fromPos     : UDim2?,
    toPos       : UDim2?,
    fade        : boolean?,  -- default true
    fadeFrom    : number?,
    fadeTo      : number?,
    onComplete  : (Instance) → void?,
    signal      : string?,
  }
--]]

--  TYPEWRITER HANDLE CONTRACT
--[[
  {
    skip    : () → void,
    cancel  : () → void,
    pause   : () → void,
    resume  : () → void,
    isDone  : () → boolean,
  }
--]]

return Types
