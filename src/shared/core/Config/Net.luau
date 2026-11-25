-- How hard a client is allowed to talk to the server.
local Config = {}

-- The default meter for a remote a player fires by pressing something. A human pressing a
-- button cannot beat this; a script looping the remote at frame rate is refused and counted.
-- Anything that fires from a *drag* or from a held trigger wants `rate = "custom"` in the
-- contract and its own budget in the handler — a flat per-second number cannot describe a
-- burst, and pretending it can is how a rate limit ends up either useless or in the way.
Config.ACTION_RATE = 12
-- Higher ceiling for mashing Attack to break free from a grabber (10 rapid clicks/taps).
Config.GRAB_ESCAPE_RATE = 20

-- Admins, for the Studio-only or staff-only remotes. An empty list means "Studio only",
-- which is the right default for a repo somebody just cloned.
Config.ADMIN_USER_IDS = {} :: { number }

return Config
