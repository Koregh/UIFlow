-- EventMarkers: prop-key helpers for attaching to Roblox Instance events
-- and property-change signals in the component reconciler.
--
-- Inspired by Roact's Event and Change markers from react-luau.
--
-- Usage in a render patch:
--
--   local Event  = EventMarkers.Event
--   local Change = EventMarkers.Change
--
--   return {
--       [button] = {
--           Text = "Click me",
--           [Event.MouseButton1Click] = function(rbx) print("clicked", rbx) end,
--           [Change.Text]             = function(rbx) print("text is now", rbx.Text) end,
--       }
--   }
--
-- The reconciler (Component / Renderer) checks for these marker keys and
-- wires up / tears down the connections automatically.

local EventMarkers = {}

local EventMeta = {
	__tostring = function(self)
		return string.format("UIEvent(%s)", self.name)
	end,
}

local ChangeMeta = {
	__tostring = function(self)
		return string.format("UIChange(%s)", self.name)
	end,
}

-- Lazily-created event markers (cached per event name).
local _eventCache  = {}
local _changeCache = {}

-- Unique type tags so the reconciler can distinguish markers from plain props.
EventMarkers.TYPE_EVENT  = "UIFlow_HostEvent"
EventMarkers.TYPE_CHANGE = "UIFlow_HostChangeEvent"

EventMarkers.Event = setmetatable({}, {
	__index = function(_, eventName)
		if not _eventCache[eventName] then
			_eventCache[eventName] = setmetatable({
				_type = EventMarkers.TYPE_EVENT,
				name  = eventName,
			}, EventMeta)
		end
		return _eventCache[eventName]
	end,
})

EventMarkers.Change = setmetatable({}, {
	__index = function(_, propertyName)
		if not _changeCache[propertyName] then
			_changeCache[propertyName] = setmetatable({
				_type = EventMarkers.TYPE_CHANGE,
				name  = propertyName,
			}, ChangeMeta)
		end
		return _changeCache[propertyName]
	end,
})

-- Check helpers used by the reconciler.
function EventMarkers.isEvent(key)
	return type(key) == "table" and key._type == EventMarkers.TYPE_EVENT
end

function EventMarkers.isChange(key)
	return type(key) == "table" and key._type == EventMarkers.TYPE_CHANGE
end

return EventMarkers
