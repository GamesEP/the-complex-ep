-- Co-op Downed & Ally Revive tunables (`plans/gdd/systems.md`, `plans/roadmap.md HS-04 / HS-28..HS-30`).
local Config = {}

-- Seconds a standing ally must stay inside the downed player's revive ring to revive them.
Config.ALLY_REVIVE_SECONDS = 5
-- Horizontal proximity radius (studs) around a downed ally to channel revive.
Config.ALLY_REVIVE_RADIUS = 8
-- Fraction of MaxHealth restored upon ally revive (50%).
Config.ALLY_REVIVE_HEALTH_FRACTION = 0.5
-- Brief invulnerability grace period immediately after standing back up.
Config.ALLY_REVIVE_IMMUNITY_SECONDS = 2.0
-- Bonus revive speed per additional standing helper inside the ring beyond the first (1 helper = 1.0x = exact 5 s).
Config.ALLY_REVIVE_EXTRA_HELPER_BONUS = 0.35

return Config
