-- Fault reporting: what a report costs, how much of it is kept, and where it lands.
local Config = {}

-- The ring buffer lives in its own DataStore so a diagnostics bug can never touch a profile.
-- One key per server — a live server owns its key outright, so flushing is a plain SetAsync
-- with no cross-server contention and no read-modify-write to lose a race in.
Config.DIAG_STORE = "Diagnostics"
Config.DIAG_KEY_PREFIX = "server_"
-- Newest wins. A server that faults thousands of times keeps the first of each distinct cause
-- and the most recent tail, which is what you want at 3am: what broke first, and what it was
-- doing by the end.
Config.DIAG_MAX_ENTRIES = 400
-- A DataStore key holds 4 MB; this is nowhere near it, and the cap is about staying readable.
Config.DIAG_MAX_DETAIL = 300

-- DataStore writes are throttled per key, so the sink batches. A fault storm is one write
-- every FLUSH_SECONDS however loud it gets, and the counts inside carry the volume.
Config.DIAG_FLUSH_SECONDS = 20
-- Written straight away when a server has this many unflushed entries, so a crash loop that
-- kills the server inside one flush window still leaves its evidence behind.
Config.DIAG_FLUSH_AT = 40

-- A fault that repeats sixty times a second must not print sixty lines a second, and must not
-- print once and then hide forever — the one-shot warning is exactly what let the editable-asset
-- budget go unnoticed for months. So the console gets a line on these occurrence counts, and on
-- every DIAG_REPEAT_EVERY after the last of them, each carrying the running total.
Config.DIAG_REPEAT_STEPS = { 1, 2, 5, 20, 100, 500 }
Config.DIAG_REPEAT_EVERY = 2500

-- Client faults ride a remote to reach the DataStore. Batched on the client and metered here:
-- a client cannot be trusted to be quiet, and this channel writes to persistent storage.
Config.DIAG_CLIENT_FLUSH_SECONDS = 10
-- Distinct causes in one report. A client with more broken than this is having a bad enough
-- time that the first eight say why.
Config.DIAG_CLIENT_BATCH = 8
Config.DIAG_CLIENT_RATE = 1

return Config
