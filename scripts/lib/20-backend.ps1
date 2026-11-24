function Get-Backend {
    $property = $script:Backends.backends.PSObject.Properties[$script:Options.Backend]
    if (-not $property) { throw ('Backend not found in registry: ' + $script:Options.Backend) }
    return $property.Value
}

function Get-BackendPaths([string]$Name) {
    $source = Join-Path $script:Root ('src\backends\' + $Name)
    $target = Join-Path $script:Root ('build\' + $Name + '\target')
    $binaryDir = Join-Path $script:Root ('bin\backends\' + $Name)
    $backendConfig = Join-Path $script:ConfigRoot ($Name + '.toml')
    $localData = Join-Path $env:LOCALAPPDATA ('R4Y\backends\' + $Name)
    return [pscustomobject]@{ Source = $source; Target = $target; BinaryDir = $binaryDir; Config = $backendConfig; Cache = (Join-Path $localData 'cache'); Data = (Join-Path $localData 'data') }
}

function Update-BackendSource {
    $backend = Get-Backend
    $paths = Get-BackendPaths $script:Options.Backend
    $source = $paths.Source
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $source) | Out-Null
    if (-not (Test-Path -LiteralPath (Join-Path $source '.git'))) {
        if (Test-Path -LiteralPath $source) {
            $items = @(Get-ChildItem -LiteralPath $source -Force -ErrorAction SilentlyContinue)
            if ($items.Count -gt 0) { throw ('Backend source directory exists but is not a Git checkout: ' + $source) }
        }
        Write-Info ('Cloning ' + $backend.repository)
        $code = Invoke-Native $script:GitExe @('clone', '--depth', '1', '--branch', [string]$backend.branch, [string]$backend.repository, $source) $null
        if ($code -ne 0) { throw ('git clone failed for backend ' + $script:Options.Backend + ' (exit code ' + $code + ').') }
    } else {
        $origin = (& $script:GitExe -C $source remote get-url origin | Out-String).Trim()
        if ($origin -ne [string]$backend.repository) {
            throw ('The existing checkout at ' + $source + ' has a different origin. Move it aside or remove it before switching sources; R4Y will not overwrite it.')
        }
        $changes = (& $script:GitExe -C $source status --porcelain --untracked-files=normal | Out-String).Trim()
        if ($LASTEXITCODE -ne 0) { throw 'Could not inspect the backend Git working tree.' }
        if ($changes) { throw ('Backend source has local changes: ' + $source + '. Commit or move those changes before updating; R4Y will not discard contributor work.') }
        $code = Invoke-Native $script:GitExe @('-C', $source, 'fetch', '--depth', '1', 'origin', [string]$backend.branch) $null
        if ($code -ne 0) { throw 'git fetch failed; the existing backend checkout was left untouched.' }
        $code = Invoke-Native $script:GitExe @('-C', $source, 'reset', '--hard', 'FETCH_HEAD') $null
        if ($code -ne 0) { throw 'Could not fast-forward the clean backend checkout.' }
    }
    $head = (& $script:GitExe -C $source rev-parse --short=12 HEAD | Out-String).Trim()
    if ($LASTEXITCODE -ne 0 -or -not $head) { throw 'Could not read the backend revision.' }
    Write-Ok ($backend.name + ' ready at ' + $head)
}

function Apply-BackendPatches {
    $source = (Get-BackendPaths $script:Options.Backend).Source
    $patches = @()
    $specific = Join-Path $script:Root ('patches\' + $script:Options.Backend)
    if (Test-Path -LiteralPath $specific) { $patches += @(Get-ChildItem -LiteralPath $specific -Filter '*.patch' -File | Sort-Object Name) }
    # Keep the original top-level patch directory working for existing VIctory users.
    if ($script:Options.Backend -in @('upstream', 'minevictory')) {
        $legacy = @(Get-ChildItem -LiteralPath (Join-Path $script:Root 'patches') -Filter '*.patch' -File | Sort-Object Name)
        $patches += $legacy
    }
    foreach ($patch in $patches) {
        $check = Invoke-Native $script:GitExe @('-C', $source, 'apply', '--check', $patch.FullName) $null
        if ($check -ne 0) { throw ('Patch does not apply to ' + $script:Options.Backend + ': ' + $patch.Name + '. Rebase or remove it; patches are never silently skipped.') }
        $apply = Invoke-Native $script:GitExe @('-C', $source, 'apply', $patch.FullName) $null
        if ($apply -ne 0) { throw ('Could not apply patch ' + $patch.Name + '.') }
        Write-Ok ('Applied patch: ' + $patch.Name)
    }
    if ($patches.Count -eq 0) { Write-Info 'No backend-specific patches to apply.' }
}

function Load-State {
    if (-not (Test-Path -LiteralPath $script:StatePath -PathType Leaf)) { return $null }
    try { return (Get-Content -LiteralPath $script:StatePath -Raw -Encoding UTF8 | ConvertFrom-Json) } catch { return $null }
}

function Save-State([string]$Backend, [string]$GameDir, [string]$Executable) {
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $script:StatePath) | Out-Null
    $state = [pscustomobject]@{ schema_version = 1; backend = $Backend; game_dir = $GameDir; exe = $Executable }
    $state | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $script:StatePath -Encoding UTF8
}

