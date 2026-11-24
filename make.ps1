#Requires -Version 5.1
<#
.SYNOPSIS
    PowerShell port of the Makefile: same targets, same variables.

.DESCRIPTION
    Usage mirrors make:

        .\make.ps1 <target> [KEY=VALUE ...]

    Examples:
        .\make.ps1                  # list targets
        .\make.ps1 test ONLY=ui
        .\make.ps1 serve PORT=34873
        .\make.ps1 check
        .\make.ps1 upload-asset FILE=assets/click.ogg TYPE=Audio

    Variables resolve like make's '?=': KEY=VALUE on the command line first,
    then the environment, then the built-in default.

    Packages/ is a build output, gitignored and rebuilt from wally.lock;
    'setup' installs it and every target that reads the project keeps it
    current, the same way the Makefile's Packages prerequisite does.

    The targets backed by shell scripts (lsp-defs, sync-assets, check-assets,
    upload-asset, logs, stamp) run the same scripts/*.sh through Git Bash, so the
    logic stays in one place and CI calls those scripts directly. sync-assets
    needs a working python3 inside Git Bash; the Microsoft Store python3 alias
    stub does not count.

    This file and the Makefile are two ports of one thing and they drift the
    moment only one of them is edited. A target added to either belongs in
    both, and `check` running the same steps in both is what keeps a Windows
    contributor's green run meaning what CI's green run means.

    ARGS with spaces must be a single quoted token:
        .\make.ps1 logs "ARGS=--list"
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$Target = 'help',

    [Parameter(ValueFromRemainingArguments = $true)]
    [object[]]$Rest
)

# ---------------------------------------------------------------------------
# KEY=VALUE overrides, exactly like make's command-line variables.
# ---------------------------------------------------------------------------

$Opt = @{}
foreach ($token in $Rest) {
    # PowerShell parses an unquoted comma token (AT=0,0,600) into an array
    # before it reaches us; rejoin it so the value keeps its commas.
    if ($token -is [array]) { $token = $token -join ',' }
    if ($token -match '^([A-Za-z_][A-Za-z0-9_]*)=(.*)$') {
        $Opt[$Matches[1]] = $Matches[2]
    }
    else {
        Write-Host "error: unexpected argument '$token'"
        Write-Host "Pass overrides as KEY=VALUE, e.g.  .\make.ps1 test ONLY=layout"
        exit 1
    }
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

function Get-MakeVar {
    param([string]$Name, [string]$Default)
    if ($Opt.ContainsKey($Name)) { return $Opt[$Name] }
    $value = [Environment]::GetEnvironmentVariable($Name)
    if ($value) { return $value }
    return $Default
}

function Invoke-Native {
    param([string]$Exe, [string[]]$ArgList)
    if (-not (Get-Command $Exe -ErrorAction SilentlyContinue)) {
        throw "$Exe is not on PATH - run '.\make.ps1 setup' to install the toolchain pinned in rokit.toml"
    }
    & $Exe @ArgList
    if ($LASTEXITCODE -ne 0) { throw "$Exe exited with code $LASTEXITCODE" }
}

function Find-Bash {
    # Prefer Git for Windows' bash; a bare 'bash' on PATH can be WSL's, which
    # does not share this repo's tooling assumptions.
    $candidates = @()
    if ($env:ProgramFiles)        { $candidates += Join-Path $env:ProgramFiles 'Git\bin\bash.exe' }
    if (${env:ProgramFiles(x86)}) { $candidates += Join-Path ${env:ProgramFiles(x86)} 'Git\bin\bash.exe' }
    if ($env:LOCALAPPDATA)        { $candidates += Join-Path $env:LOCALAPPDATA 'Programs\Git\bin\bash.exe' }
    foreach ($candidate in $candidates) {
        if (Test-Path $candidate) { return $candidate }
    }
    # -All: the first 'bash' on PATH can be WSL's System32 stub with a real
    # Git Bash (scoop, choco, per-user Git) further down the PATH.
    $onPath = Get-Command bash -All -ErrorAction SilentlyContinue |
        Where-Object { $_.Source -and $_.Source -notlike '*System32*' } |
        Select-Object -First 1
    if ($onPath) { return $onPath.Source }
    throw 'Git Bash not found. Install Git for Windows (https://git-scm.com) to run this target.'
}

function Invoke-BashScript {
    param([string]$Script, [string[]]$ScriptArgs = @())
    & (Find-Bash) $Script @ScriptArgs
    if ($LASTEXITCODE -ne 0) { throw "$Script exited with code $LASTEXITCODE" }
}

function Split-ShellArgs {
    # Quote-aware split for ARGS, mirroring the shell that expands $(ARGS) in
    # the Makefile: --root 'My Map' stays two tokens, quotes stripped.
    param([string]$Line)
    $tokens = @()
    foreach ($match in [regex]::Matches($Line, '(?:[^\s''"]+|''[^'']*''|"[^"]*")+')) {
        $tokens += ($match.Value -replace '''([^'']*)''', '$1' -replace '"([^"]*)"', '$1')
    }
    return $tokens
}

# One table drives both the help listing and the unknown-target check, so
# drift errors in both directions: a target advertised here without a switch
# case hits the switch's default throw, and a switch case missing from here
# is rejected before the switch is reached.
$TargetHelp = [ordered]@{
    'help'            = 'List available targets'
    'setup'           = 'Install the toolchain pinned in rokit.toml, then the Wally packages'
    'plugin'          = 'Install the Rojo Studio plugin on Linux/Vinegar (once per machine)'
    'plugin-win'      = 'Install the Rojo Studio plugin on Windows or macOS (once per machine)'
    'dev'             = 'Build your scratch place, then serve it - the normal way to start work'
    'serve'           = 'Start the live-sync server (Studio pulls from disk)'
    'packages'        = 'Download the Wally dependencies into Packages/ and patch their types'
    'place'           = 'Rebuild the local scratch place from scratch, discarding its contents'
    'build'           = 'Build the place the way CI does, to verify the project compiles'
    'sourcemap'       = 'Generate sourcemap.json for luau-lsp autocomplete'
    'watch-sourcemap' = 'Keep the sourcemap current as files are added or renamed'
    'fmt'             = "Reformat the project JSON to Rojo's canonical style"
    'test'            = 'Run every check that does not need Studio - the syntax sweep and the self tests'
    'test-list'       = "Name every suite '.\make.ps1 test ONLY=' accepts"
    'style'           = 'Format every .luau file with stylua, per stylua.toml'
    'style-check'     = 'Report files stylua would reformat, changing nothing'
    'lsp-defs'        = 'Download the Roblox type definitions luau-lsp needs (once per machine)'
    'analyze'         = "Type-check against the Roblox API. Needs '.\make.ps1 lsp-defs' first."
    'globals'         = "Fail on any undefined global. Needs '.\make.ps1 lsp-defs' first."
    'check'           = 'What CI runs - the suites pass, no undefined globals, and the project builds'
    'clean'           = 'Remove build outputs and scratch places'
    'sync-assets'     = 'Upload anything in assets/ that Roblox does not have, and record its id'
    'check-assets'    = 'Report assets missing from src/shared/core/Assets/AssetIds.json (no upload)'
    'upload-asset'    = 'Upload one file and print its id, without touching the manifest'
    'stamp'           = 'Write the current commit into the place, so a session says which build it is'
    'logs'            = "Read the published game's diagnostics ring buffer through Open Cloud"
    'syncback-dry'    = 'Preview pulling geometry edited in Studio back to disk (writes nothing)'
    'syncback'        = 'Pull geometry edited in Studio back into assets/, then review the diff'
    'upload'          = 'Publish by hand. Prefer pushing to staging/main and letting CI do it.'
}

function Show-Help {
    Write-Host 'development commands (make.ps1)'
    Write-Host ''
    foreach ($entry in $TargetHelp.GetEnumerator()) {
        Write-Host ('  .\make.ps1 {0,-16} {1}' -f $entry.Key, $entry.Value)
    }
    Write-Host ''
    Write-Host 'Variables are passed like make:  .\make.ps1 test ONLY=layout   .\make.ps1 serve PORT=34873'
    Write-Host 'lsp-defs, sync-assets, check-assets, upload-asset, logs and stamp run scripts/*.sh through Git Bash.'
    Write-Host ''
    Write-Host 'First time?  .\make.ps1 setup; .\make.ps1 plugin-win; .\make.ps1 dev'
}

# ---------------------------------------------------------------------------
# Variables - same defaults as the Makefile. INPUT tracks LOCAL_PLACE.
# ---------------------------------------------------------------------------

$Project          = Get-MakeVar 'PROJECT'          'default.project.json'
$LocalPlace       = Get-MakeVar 'LOCAL_PLACE'      'local.rbxlx'
$SyncbackProject  = Get-MakeVar 'SYNCBACK_PROJECT' 'syncback.project.json'
$InputPlace       = Get-MakeVar 'INPUT'            $LocalPlace
$BuildPlace       = Get-MakeVar 'BUILD_PLACE'      'game.rbxl'
$Sourcemap        = Get-MakeVar 'SOURCEMAP'        'sourcemap.json'
$Port             = Get-MakeVar 'PORT'             '34872'

# Composite building blocks, so dev/check/analyze can reuse targets.

# One spelling of the sourcemap flags, like the Makefile's SOURCEMAP_CMD: two
# copies would drift the first time one changed. Deliberately *without*
# --include-non-scripts - see the Makefile for why.
function Invoke-SourcemapCommand {
    param([switch]$Watch)
    $argList = @('sourcemap', $Project, '--output', $Sourcemap)
    if ($Watch) { $argList += '--watch' }
    Invoke-Native rojo $argList
}

function Invoke-PackagesTarget {
    # Mirror of the Makefile's Packages file target: reinstall only when
    # wally.toml or wally.lock is newer than Packages/. default.project.json
    # mounts Packages at ReplicatedStorage.Packages, and rojo will not build
    # a project whose $path is missing.
    $stamp = Get-Item 'Packages' -ErrorAction SilentlyContinue
    if ($stamp) {
        $newest = (Get-Item 'wally.toml', 'wally.lock' |
            Measure-Object -Property LastWriteTime -Maximum).Maximum
        if ($stamp.LastWriteTime -ge $newest) { return }
    }
    Invoke-Native wally @('install')
    # wally-package-types rewrites Wally's one-line re-export stubs so
    # luau-lsp can follow them to the types inside _Index. It reads a
    # sourcemap, which is why one is built here.
    Invoke-SourcemapCommand
    Invoke-Native wally-package-types @('--sourcemap', $Sourcemap, 'Packages/')
    (Get-Item 'Packages').LastWriteTime = Get-Date
}

function Invoke-TestTarget {
    $argList = @('run', 'scripts/run-tests.luau')
    $only = Get-MakeVar 'ONLY' $null
    if ($only) { $argList += @('--only', $only) }
    Invoke-Native lune $argList
}

function Invoke-PlaceTarget {
    Invoke-PackagesTarget
    Invoke-Native rojo @('build', $Project, '--output', $LocalPlace)
    Write-Host "Built $LocalPlace - this file is disposable, rebuild it any time."
}

function Invoke-BuildTarget {
    Invoke-PackagesTarget
    Invoke-Native rojo @('build', $Project, '--output', $BuildPlace)
}

function Invoke-ServeTarget {
    Invoke-PackagesTarget
    Invoke-Native rojo @('serve', $Project, '--port', $Port)
}

function Invoke-SourcemapTarget {
    param([switch]$Watch)
    Invoke-PackagesTarget
    Invoke-SourcemapCommand -Watch:$Watch
}

# ---------------------------------------------------------------------------
# Targets
# ---------------------------------------------------------------------------

Push-Location $PSScriptRoot
try {
    if (-not $TargetHelp.Contains($Target)) {
        Write-Host "error: unknown target '$Target'"
        Write-Host ''
        Show-Help
        exit 1
    }

    switch ($Target) {

        'help' { Show-Help }

        'setup' {
            if (-not (Get-Command rokit -ErrorAction SilentlyContinue)) {
                Write-Host 'error: rokit is not installed.'
                Write-Host ''
                Write-Host "Install it, then re-run '.\make.ps1 setup':"
                Write-Host '  Windows:  Invoke-RestMethod https://raw.githubusercontent.com/rojo-rbx/rokit/main/scripts/install.ps1 | Invoke-Expression'
                Write-Host ''
                Write-Host 'See https://github.com/rojo-rbx/rokit for other install options (Cargo, manual binary).'
                exit 1
            }
            Invoke-Native rokit @('install')
            Invoke-PackagesTarget
        }

        'plugin' {
            Write-Host "'plugin' installs the Rojo Studio plugin on Linux/Vinegar. On Windows use:  .\make.ps1 plugin-win"
        }

        'plugin-win' { Invoke-Native rojo @('plugin', 'install') }

        'dev' {
            Invoke-PlaceTarget
            $bash = $null
            try { $bash = Find-Bash } catch { }
            if ($bash) {
                $checkOutput = & $bash scripts/sync-assets.sh --check 2>&1
                if ($LASTEXITCODE -ne 0) {
                    # Exit 127 (or 'command not found' anywhere in the output)
                    # is the check itself failing to run - usually python3
                    # missing inside Git Bash - not assets being out of sync.
                    if ($LASTEXITCODE -eq 127 -or "$checkOutput" -match 'command not found') {
                        Write-Host ''
                        Write-Host 'Note: the asset check itself could not run - a dependency is missing inside Git Bash:'
                        $checkOutput | Select-Object -Last 3 | ForEach-Object { Write-Host "      $_" }
                        Write-Host '      sync-assets needs a working python3 in Git Bash; the Microsoft Store alias stub does not count.'
                    }
                    else {
                        Write-Host ''
                        Write-Host 'Note: some files in assets/ are not on Roblox yet, so they will be silent.'
                        Write-Host "      Run '.\make.ps1 check-assets' to see which, '.\make.ps1 sync-assets' to upload them."
                    }
                }
            }
            else {
                Write-Host ''
                Write-Host 'Note: Git Bash not found - skipping the asset check.'
            }
            Write-Host ''
            Write-Host "Open $LocalPlace in Studio, then connect the Rojo plugin to localhost:$Port."
            Write-Host 'Leave this running; edits on disk sync into Studio live.'
            Write-Host ''
            Invoke-ServeTarget
        }

        'serve' { Invoke-ServeTarget }

        'packages' { Invoke-PackagesTarget }

        'place' { Invoke-PlaceTarget }

        'build' { Invoke-BuildTarget }

        'sourcemap' { Invoke-SourcemapTarget }

        'watch-sourcemap' { Invoke-SourcemapTarget -Watch }

        'fmt' { Invoke-Native rojo @('fmt-project', $Project) }

        'test' { Invoke-TestTarget }

        'test-list' { Invoke-Native lune @('run', 'scripts/run-tests.luau', '--list') }

        'style' { Invoke-Native stylua @('src', 'scripts') }

        'style-check' { Invoke-Native stylua @('--check', 'src', 'scripts') }

        'lsp-defs' { Invoke-BashScript 'scripts/fetch-luau-defs.sh' }

        'analyze' {
            Invoke-SourcemapTarget
            if (-not (Test-Path '.lsp/globalTypes.d.luau')) {
                Write-Host "error: run '.\make.ps1 lsp-defs' first"
                exit 1
            }
            Invoke-Native luau-lsp @('analyze', "--sourcemap=$Sourcemap", '--definitions=.lsp/globalTypes.d.luau',
                '--base-luaurc=.luaurc', '--platform=roblox', 'src')
        }

        # Narrower than 'analyze' on purpose, so it can gate while analyze cannot: a growing
        # codebase accumulates type findings nobody intends to fix, and an undefined global is
        # never one of them. Nothing else catches this class - rojo packs source without reading
        # it, and the syntax sweep compiles without resolving names, so a require through a name
        # nobody bound builds clean, passes every suite, and takes the realm's bootstrap down on
        # the first frame of a real server.
        'globals' {
            Invoke-SourcemapTarget
            if (-not (Test-Path '.lsp/globalTypes.d.luau')) {
                Write-Host "error: run '.\make.ps1 lsp-defs' first"
                exit 1
            }
            $found = & luau-lsp analyze "--sourcemap=$Sourcemap" '--definitions=.lsp/globalTypes.d.luau' `
                '--base-luaurc=.luaurc' '--platform=roblox' 'src' 2>&1 |
                Select-String -SimpleMatch 'Unknown global'
            if ($found) {
                $found | ForEach-Object { Write-Host $_.Line }
                Write-Host 'error: the globals above are bound nowhere - reading one gets nil, requiring through one throws'
                exit 1
            }
            Write-Host 'OK - no undefined globals.'
            # Explicit: otherwise this script exits with luau-lsp's own code, which is non-zero
            # for any type finding at all, and `check` (which reads $LASTEXITCODE) fails on a
            # clean run. The Makefile's `globals` already exits 0 here.
            exit 0
        }

        'check' {
            Invoke-TestTarget
            & $PSCommandPath 'globals'
            if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
            Invoke-BuildTarget
            Write-Host "OK - $Project builds."
        }

        'clean' {
            # Leaves Packages/ alone on purpose: everything else here is
            # regenerated from the repo, and that one needs the network.
            Remove-Item -Path $LocalPlace, $BuildPlace, $Sourcemap -Force -ErrorAction SilentlyContinue
            Remove-Item -Path '*.rbxlx.lock', '*.rbxl.lock' -Force -ErrorAction SilentlyContinue
        }

        'sync-assets' { Invoke-BashScript 'scripts/sync-assets.sh' }

        'check-assets' { Invoke-BashScript 'scripts/sync-assets.sh' @('--check') }

        'upload-asset' {
            $file = Get-MakeVar 'FILE' $null
            $type = Get-MakeVar 'TYPE' $null
            if (-not $file) { Write-Host 'error: set FILE=<path>'; exit 1 }
            if (-not $type) { Write-Host 'error: set TYPE=<Audio|Decal|Model>'; exit 1 }
            Invoke-BashScript 'scripts/upload-asset.sh' @($file, $type)
        }

        'logs' {
            $extra = Get-MakeVar 'ARGS' $null
            $logArgs = @()
            if ($extra) { $logArgs = Split-ShellArgs $extra }
            Invoke-BashScript 'scripts/fetch-logs.sh' $logArgs
        }

        # CI runs this before every publish; by hand it is for reproducing something a
        # published server reported. It modifies one tracked file, and the stamp belongs to a
        # build rather than to the source, so put it back before committing:
        #   git checkout src/shared/core/Build/BuildInfo.json
        'stamp' { Invoke-BashScript 'scripts/stamp-build.sh' }

        'syncback-dry' {
            if (-not (Test-Path $InputPlace)) {
                Write-Host "error: $InputPlace does not exist - save the place from Studio first"
                exit 1
            }
            Invoke-Native rojo @('syncback', $SyncbackProject, '--input', $InputPlace, '--list', '--dry-run')
        }

        'syncback' {
            if (-not (Test-Path $InputPlace)) {
                Write-Host "error: $InputPlace does not exist - save the place from Studio first"
                exit 1
            }
            Invoke-Native rojo @('syncback', $SyncbackProject, '--input', $InputPlace)
            Write-Host ''
            Write-Host 'Review before committing:  git diff assets/'
        }

        'upload' {
            $apiKey     = Get-MakeVar 'ROBLOX_API_KEY' $null
            $universeId = Get-MakeVar 'ROBLOX_UNIVERSE_ID' $null
            $placeId    = Get-MakeVar 'ROBLOX_PLACE_ID' $null
            if (-not $apiKey)     { Write-Host 'error: ROBLOX_API_KEY not set'; exit 1 }
            if (-not $universeId) { Write-Host 'error: ROBLOX_UNIVERSE_ID not set'; exit 1 }
            if (-not $placeId)    { Write-Host 'error: ROBLOX_PLACE_ID not set'; exit 1 }
            Invoke-PackagesTarget
            Write-Host "About to publish LIVE to place $placeId. Ctrl-C within 5s to abort."
            Start-Sleep -Seconds 5
            Invoke-Native rojo @('upload', $Project,
                '--api_key', $apiKey, '--universe_id', $universeId, '--asset_id', $placeId)
        }

        default {
            throw "target '$Target' is in the help table but has no switch case - add one"
        }
    }
}
catch {
    Write-Host "error: $($_.Exception.Message)"
    exit 1
}
finally {
    Pop-Location
}
