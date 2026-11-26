# Tonemapping

How post-processing tonemapping is configured and applied to `Lighting`.

## Active default and reference catalogue

**`agx-punchy`** (`Config.TONEMAPPER_DEFAULT` in `src/shared/core/Config/Tonemapping.luau`) is the
active default look for *The Complex*. The remaining operators stay in `Config.TONEMAPPER_PRESETS`
and `src/shared/features/tonemapping/Tonemapper.luau` as reference presets so switching or baking
static 3D LUTs later is a one-line config change:

| Preset id | Role | Notes |
|---|---|---|
| `agx-punchy` | **Active default** | Blender AgX Punchy look — deep blacks, vivid sci-fi neons |
| `roblox-default` | Reference | Native post-2019 Roblox filmic tonemapper |
| `roblox-retro` | Reference | Native pre-2019 softer contrast / lower saturation |
| `pbr-neutral` | Reference | Exact port of `KhronosGroup/ToneMapping` (`PBR_Neutral/pbrNeutral.glsl`) |
| `agx` | Reference | Troy Sobotka AgX (inset/outset + 6th-order sigmoid) |
| `aces` | Reference | Stephen Hill ACES RRT+ODT fit (Rec. 709 ↔ AP1) |
| `uncharted2` | Reference | John Hable filmic curve |
| `reinhard` | Reference | Luminance-preserving Extended Reinhard |
| `invert` / `identity` | Diagnostic | 1024×32 LUT tests for verifying `ColorLutContent` in future Studio builds |

## Runtime backend

`TonemapperController` (`src/client/features/tonemapping/TonemapperController.luau`) manages three
dedicated instances under `Lighting`: `ComplexTonemapGrading`, `ComplexTonemapLut`, and
`ComplexTonemapBloom`.

**Studio 0.748 engine status:** verified live in Studio `0.748.0.7481526` that
`ColorCorrectionEffect.ColorLutContent` accepts `Object`, `Opaque` (`CreateDataModelContentAsync`),
and `Uri` (`Content.fromAssetId`) without throwing, yet produces zero pixel delta (`MAD = 0.00`)
even for a solid-magenta LUT — Roblox's LUT rendering pass is not yet enabled on that build.

Because of that, `Config.TONEMAPPER_BACKEND_MODE` defaults to `"approx"`, applying the tuned
`ColorGradingEffect.TonemapperPreset` + `Lighting.ExposureCompensation` + `ColorCorrectionEffect` +
`BloomEffect` profile for the active preset.

Once Roblox turns on the `ColorLutContent` renderer pass:
1. Run `lune run scripts/generate-luts.luau --assets && make sync-assets` to upload the static
   `1024×32` PNG LUTs (avoiding runtime `EditableImage` budget in production).
2. Switch `Config.TONEMAPPER_BACKEND_MODE` in `src/shared/core/Config/Tonemapping.luau` to `"auto"`.
