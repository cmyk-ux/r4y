# R4Y bootstrapper and backend manager.
# Windows PowerShell 5.1 compatible; keep backend-specific behavior in backends.json.
#Requires -Version 5.1
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$script:Root = Split-Path -Parent $PSScriptRoot
$script:ManifestPath = Join-Path $script:Root 'backends.json'
$script:ConfigRoot = Join-Path $script:Root 'config\backends'
$script:StatePath = Join-Path $script:Root 'config\r4y-state.json'
$script:LogPath = Join-Path $script:Root 'r4y.log'
$script:Backends = $null
$script:Options = @{
    Backend = $null
    DryRun = $false
    NoBuild = $false
    NoRun = $false
    Yes = $false
    Test = $false
    Launch = $false
    ValidateOnly = $false
    Help = $false
    GameArgs = @()
}
$script:GitExe = $null
$script:CargoExe = $null
$script:WingetExe = $null
$script:RebootNeeded = $false

$library = Join-Path $PSScriptRoot 'lib'
foreach ($unit in @('00-bootstrap.ps1','10-tools.ps1','20-backend.ps1','30-game-config.ps1','40-runner.ps1')) {
    $unitPath = Join-Path $library $unit
    if (-not (Test-Path -LiteralPath $unitPath -PathType Leaf)) { throw ('R4Y script component is missing: ' + $unitPath) }
    . $unitPath
}

$exitCode = 1
$transcriptStarted = $false
try {
    Load-Manifest
    Parse-Arguments $args
    if ($script:Options.Help) { Show-Help; exit 0 }
    if ($script:Options.ValidateOnly) { Test-Manifest; exit 0 }
    if ($script:Options.Launch) { $exitCode = Invoke-Launch; exit $exitCode }
    try { Start-Transcript -Path $script:LogPath -Force | Out-Null; $transcriptStarted = $true } catch {}
    $exitCode = Invoke-Setup
} catch {
    Write-Host ''
    Write-Host 'R4Y failed' -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Red
    Write-Host ('Log: ' + $script:LogPath) -ForegroundColor Yellow
    $exitCode = 1
} finally {
    if ($transcriptStarted) { try { Stop-Transcript | Out-Null } catch {} }
}
exit $exitCode
