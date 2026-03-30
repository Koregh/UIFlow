local Types = {}

Types.LifecycleState = {
	IDLE       = "IDLE",
	MOUNTING   = "MOUNTING",
	MOUNTED    = "MOUNTED",
	UPDATING   = "UPDATING",
	UNMOUNTING = "UNMOUNTING",
	UNMOUNTED  = "UNMOUNTED",
	ERROR      = "ERROR",
}

Types.Easing = {
	LINEAR   = { style = Enum.EasingStyle.Linear,  dir = Enum.EasingDirection.In    },
	EASE_IN  = { style = Enum.EasingStyle.Quart,   dir = Enum.EasingDirection.In    },
	EASE_OUT = { style = Enum.EasingStyle.Quart,   dir = Enum.EasingDirection.Out   },
	EASE_IO  = { style = Enum.EasingStyle.Quart,   dir = Enum.EasingDirection.InOut },
	BACK_OUT = { style = Enum.EasingStyle.Back,    dir = Enum.EasingDirection.Out   },
	ELASTIC  = { style = Enum.EasingStyle.Elastic, dir = Enum.EasingDirection.Out   },
	BOUNCE   = { style = Enum.EasingStyle.Bounce,  dir = Enum.EasingDirection.Out   },
	SINE_IO  = { style = Enum.EasingStyle.Sine,    dir = Enum.EasingDirection.InOut },
	SPRING   = { style = Enum.EasingStyle.Back,    dir = Enum.EasingDirection.Out   },
}

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

Types.MetricKind = {
	COUNTER   = "COUNTER",
	GAUGE     = "GAUGE",
	HISTOGRAM = "HISTOGRAM",
	TIMING    = "TIMING",
}

return Types

-- Binding type marker (used by reconciler to detect binding props)
Types.BINDING_MARKER = "UIFlow_Binding"

-- Component options contract (v3)
--[[
  Component.new(frame, renderFn, opts)

  opts = {
    initialState  = table,
    name          = string,
    ref           = { current = any },   -- forwardRef target
    errorBoundary = Component,
    onMount       = fn(comp),
    onUnmount     = fn(comp),
    onError       = fn(err, comp),
  }

  renderFn(state, api) → patch
  renderFn(state, ref, api) → patch   (when wrapped with Memo.forwardRef)

  api = {
    setState(patch),
    getState() → table,
    useEffect(fn, deps),
    useMemo(fn, deps),
    useRef(initial) → { current },
    useBinding(initial) → (Binding, updater),
    useContext(ctx) → value,
    provideContext(ctx, value) → cleanup,
    emit(signal, ...),
    on(signal, callback) → handle,
  }

  Patch table supports:
    [Instance] = {
      -- plain props:
      Text = "hello",
      Size = UDim2.new(...),

      -- animation meta:
      _duration   = 0.3,
      _easing     = Types.Easing.BACK_OUT,
      _delay      = 0,
      _onComplete = fn,

      -- event/change markers:
      [Event.MouseButton1Click] = function(rbx, ...) end,
      [Change.Text]             = function(rbx) end,

      -- binding links (zero re-render updates):
      Size = myBinding,
    }
--]]
