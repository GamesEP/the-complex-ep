--!strict
--[[
	Pure rules for combat sound effects: which cue a combo hit plays, which Roblox asset id wins
	between an uploaded custom file and its Studio fallback, and how pitch varies across combo
	steps and rapid horde combat.

	Kept pure so `make test` validates every cue in Config.SFX without needing Studio.
]]

local Config = require(script.Parent.Parent.Parent.core.Config)

local CombatAudio = {}

export type SfxSpec = {
	file: string,
	fallbackId: number,
	volume: number,
	pitch: number,
	pitchSpread: number?,
	stepPitch: number?,
	maxDistance: number?,
	maxDuration: number?,
}

local MIN_PITCH = 0.25
local MAX_PITCH = 4

-- Heavy finisher cue on the final hit of the combo; light slash on every earlier step.
function CombatAudio.attackCue(step: number, comboHits: number): string
	if comboHits >= 1 and step >= comboHits then
		return "playerAttackHeavy"
	end
	return "playerAttack"
end

-- Uploaded `assets/` media always wins once synced; the public fallback keeps local Studio runs
-- audible before `make sync-assets` has run.
function CombatAudio.resolveId(spec: SfxSpec?, uploadedId: number?): number
	if not spec then
		return 0
	end
	if type(uploadedId) == "number" and uploadedId > 0 then
		return uploadedId
	end
	if type(spec.fallbackId) == "number" and spec.fallbackId > 0 then
		return spec.fallbackId
	end
	return 0
end

-- Deterministic given `unitRandom` in [0, 1], so the curve is testable offline.
function CombatAudio.playbackSpeed(spec: SfxSpec, step: number?, unitRandom: number): number
	local base = spec.pitch or 1
	local stepOffset = math.max((step or 1) - 1, 0) * (spec.stepPitch or 0)
	local spread = (math.clamp(unitRandom, 0, 1) * 2 - 1) * (spec.pitchSpread or 0)
	return math.clamp(base + stepOffset + spread, MIN_PITCH, MAX_PITCH)
end

--=============================================================================
-- Self test
--=============================================================================

function CombatAudio.selfTest()
	-- Combo cue selection.
	assert(CombatAudio.attackCue(1, 3) == "playerAttack", "hit 1 uses light attack cue")
	assert(CombatAudio.attackCue(2, 3) == "playerAttack", "hit 2 uses light attack cue")
	assert(CombatAudio.attackCue(3, 3) == "playerAttackHeavy", "final hit uses heavy attack cue")

	-- Asset id resolution: uploaded asset overrides fallback.
	local sample: SfxSpec = {
		file = "sample.ogg",
		fallbackId = 12345,
		volume = 0.5,
		pitch = 1,
		pitchSpread = 0.1,
		stepPitch = 0.1,
	}
	assert(CombatAudio.resolveId(sample, 99999) == 99999, "uploaded asset id wins over fallback")
	assert(CombatAudio.resolveId(sample, 0) == 12345, "fallback id used when asset is not uploaded yet")
	assert(CombatAudio.resolveId(sample, nil) == 12345, "fallback id used when uploaded id is nil")
	assert(CombatAudio.resolveId(nil, 99999) == 0, "missing spec resolves to 0")

	-- Pitch progression and spread.
	assert(math.abs(CombatAudio.playbackSpeed(sample, 1, 0.5) - 1.0) < 1e-6, "center random keeps base pitch")
	assert(math.abs(CombatAudio.playbackSpeed(sample, 2, 0.5) - 1.1) < 1e-6, "step 2 applies stepPitch")
	assert(math.abs(CombatAudio.playbackSpeed(sample, 1, 0) - 0.9) < 1e-6, "low random subtracts pitchSpread")
	assert(math.abs(CombatAudio.playbackSpeed(sample, 1, 1) - 1.1) < 1e-6, "high random adds pitchSpread")

	-- Every required combat cue exists in Config.SFX and names a Roblox-accepted audio format.
	local requiredCues = {
		"playerAttack",
		"playerAttackHeavy",
		"playerDash",
		"playerSpin",
		"playerHit",
		"enemyMeleeWindup",
		"enemyMeleeStrike",
		"enemyRangedFire",
		"enemyExploderFuse",
		"enemyExploderBlast",
		"enemyGrabberWindup",
		"enemyGrabberGrab",
		"enemyGrabberEscape",
		"dropHeal",
		"dropBuff",
	}
	for _, cue in ipairs(requiredCues) do
		local spec = Config.SFX[cue]
		assert(spec ~= nil, `missing Config.SFX.{cue}`)
		assert(spec.file:match("%.ogg$") ~= nil or spec.file:match("%.mp3$") ~= nil, `{cue} file must be .ogg or .mp3`)
		assert(spec.volume > 0 and spec.volume <= 10, `{cue} volume must be positive`)
		assert(spec.pitch > 0, `{cue} pitch must be positive`)
	end
end

return CombatAudio
