local AssetIds = require(script.AssetIds)

local Assets = {}

-- Looks up a file from assets/ in the manifest `make sync-assets` writes. Returns 0 when
-- the file has not been uploaded yet, which every caller treats as "no media": better a
-- silent gun than a crash on a fresh clone.
function Assets.id(fileName: string): number
	local entry = AssetIds[fileName]
	if type(entry) ~= "table" then
		return 0
	end
	return tonumber(entry.assetId) or 0
end

return Assets
