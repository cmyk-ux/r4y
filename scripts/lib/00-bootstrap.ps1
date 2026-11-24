function Write-Step([string]$Message) { Write-Host ''; Write-Host ('==> ' + $Message) -ForegroundColor Cyan }
function Write-Ok([string]$Message) { Write-Host ('[ok] ' + $Message) -ForegroundColor Green }
function Write-Warn([string]$Message) { Write-Host ('[warning] ' + $Message) -ForegroundColor Yellow }
function Write-Info([string]$Message) { Write-Host ('     ' + $Message) -ForegroundColor Gray }

function Show-Help {
    @'
R4Y — Recompile4You

Usage:
  r4y.cmd [options]
  r4y-run.cmd [-- game arguments]

Options:
  --backend NAME  upstream | minevictory | xcl (default: minevictory)
  --channel NAME  Backward-compatible alias: upstream | fork (fork = minevictory)
  --dry-run       Check prerequisites without installing, cloning, or writing files
  --no-build      Prepare the backend and configuration without compiling
  --no-run        Build and validate, but do not offer to launch the game
  --yes           Accept dependency installation prompts
  --test          Run cargo test --workspace before building
  --help          Show this help

Backend source and build settings are defined in backends.json.
See CONTRIBUTING.md before changing the installer or backend integration.
'@ | Write-Host
}

function Parse-Arguments([string[]]$Arguments) {
    for ($i = 0; $i -lt $Arguments.Count; $i++) {
        $arg = $Arguments[$i]
        if ($arg -eq '--') {
            if ($i + 1 -lt $Arguments.Count) { $script:Options.GameArgs = @($Arguments[($i + 1)..($Arguments.Count - 1)]) }
            break
        }
        if ($arg -match '^--backend=(.+)$') { $script:Options.Backend = $Matches[1]; continue }
        if ($arg -match '^--channel=(.+)$') { $script:Options.Backend = $Matches[1]; continue }
        switch -CaseSensitive ($arg) {
            '--backend' {
                if ($i + 1 -ge $Arguments.Count) { throw '--backend requires a value.' }
                $i++; $script:Options.Backend = $Arguments[$i]
            }
            '--channel' {
                if ($i + 1 -ge $Arguments.Count) { throw '--channel requires a value.' }
                $i++; $script:Options.Backend = $Arguments[$i]
            }
            '--dry-run' { $script:Options.DryRun = $true }
            '--no-build' { $script:Options.NoBuild = $true }
            '--no-run' { $script:Options.NoRun = $true }
            '--yes' { $script:Options.Yes = $true }
            '--test' { $script:Options.Test = $true }
            '--launch' { $script:Options.Launch = $true }
            '--validate-only' { $script:Options.ValidateOnly = $true }
            '--help' { $script:Options.Help = $true }
            '-h' { $script:Options.Help = $true }
            default { throw ('Unknown option: ' + $arg + '. Use --help.') }
        }
    }
    if ($script:Options.Backend -eq 'fork') { $script:Options.Backend = 'minevictory' }
    if (-not $script:Options.Backend) { $script:Options.Backend = [string]$script:Backends.default_backend }
    if ($script:Backends.backends.PSObject.Properties.Name -notcontains $script:Options.Backend) {
        throw ('Unknown backend "' + $script:Options.Backend + '". Available: ' + (($script:Backends.backends.PSObject.Properties.Name) -join ', '))
    }
}

function Load-Manifest {
    if (-not (Test-Path -LiteralPath $script:ManifestPath -PathType Leaf)) { throw 'backends.json is missing. Restore it from the R4Y repository.' }
    $script:Backends = Get-Content -LiteralPath $script:ManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
}

function Test-Manifest {
    $scriptFiles = @((Join-Path $script:Root 'scripts\r4y.ps1'))
    $libraryDir = Join-Path $script:Root 'scripts\lib'
    if (Test-Path -LiteralPath $libraryDir) {
        $scriptFiles += @(Get-ChildItem -LiteralPath $libraryDir -Filter '*.ps1' -File | Sort-Object Name | ForEach-Object { $_.FullName })
    }
    foreach ($scriptFile in $scriptFiles) {
        $tokens = $null
        $syntaxErrors = $null
        [System.Management.Automation.Language.Parser]::ParseFile($scriptFile, [ref]$tokens, [ref]$syntaxErrors) | Out-Null
        if ($syntaxErrors.Count -gt 0) {
            $messages = @($syntaxErrors | ForEach-Object { $_.Message })
            throw ('PowerShell syntax error in ' + $scriptFile + ': ' + ($messages -join '; '))
        }
    }
    $manifest = Get-Content -LiteralPath $script:ManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ([int]$manifest.schema_version -ne 1) { throw 'Unsupported backends.json schema_version.' }
    $names = @($manifest.backends.PSObject.Properties.Name)
    if ($names.Count -lt 3) { throw 'The backend registry must expose upstream, minevictory, and xcl.' }
    if ($names -notcontains [string]$manifest.default_backend) { throw 'default_backend does not exist in the registry.' }
    foreach ($name in $names) {
        $backend = $manifest.backends.$name
        foreach ($field in @('name', 'repository', 'branch', 'package', 'binary', 'engine')) {
            if ([string]::IsNullOrWhiteSpace([string]$backend.$field)) { throw ('Backend ' + $name + ' is missing ' + $field + '.') }
        }
        if ([string]$backend.repository -notmatch '^https://github\.com/[^/]+/[^/]+\.git$') { throw ('Invalid repository URL for ' + $name + '.') }
        if ([string]$backend.binary -notmatch '^[A-Za-z0-9_.-]+\.exe$') { throw ('Invalid binary name for ' + $name + '.') }
        if ([string]$backend.engine -notin @('victory', 'xcl')) { throw ('Unknown engine type for ' + $name + '.') }
    }
    $launcher = Get-Content -LiteralPath (Join-Path $script:Root 'r4y-run.cmd') -Raw
    if ($launcher -match '(?i)[A-Z]:\\Users\\') { throw 'The generated launcher must not contain a developer-specific absolute path.' }
    if ($launcher -notmatch '--launch') { throw 'r4y-run.cmd must delegate to the portable PowerShell launcher.' }
    Write-Ok ('Manifest valid: ' + ($names -join ', ') + '; default=' + $manifest.default_backend)
}

