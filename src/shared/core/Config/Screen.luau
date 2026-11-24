-- The reference viewport, the compact thresholds, and the touch controls' geometry.
local Config = {}

-- Every panel is laid out in pixels against one reference viewport, and ScreenMetrics shrinks
-- the whole HUD with a single UIScale rather than having each panel measure itself. So the
-- offsets scattered through the UI are *design* units: what a thing would be on a 1280x720
-- screen. Above that the scale is capped at 1 — a 4K monitor gets more room, not bigger buttons.
Config.UI_REFERENCE = Vector2.new(1280, 720)
-- Floor rather than shrinking forever: past this a button is smaller than a fingertip, and the
-- answer to a screen that small is the compact layout below, not more shrinking.
Config.UI_MIN_SCALE = 0.55
-- Quantised so dragging a window edge does not re-lay-out on every frame it passes through.
Config.UI_SCALE_STEP = 0.05
-- Below either of these the HUD restructures instead of only shrinking: docks collapse to a
-- drawer, rings become grids, side columns move out of the thumbstick's corner. Sized to put
-- phones on one side and tablets on the other.
Config.UI_COMPACT_WIDTH = 900
Config.UI_COMPACT_HEIGHT = 500

-- The strip along the bottom that on-screen controls own. `ScreenMetrics.band` and
-- `.reserved` are computed from these, and panels keep out of what they describe — so if this
-- game draws its own thumbstick, these are the numbers to change, and if it uses Roblox's,
-- they are what keeps a card off the top of it.
Config.THUMBSTICK_RADIUS = 74
Config.TOUCH_BUTTON = 78
Config.TOUCH_MARGIN = 26

return Config
