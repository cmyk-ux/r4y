function Build-Backend {
    $backend = Get-Backend
    $paths = Get-BackendPaths $script:Options.Backend
    $env:CARGO_TARGET_DIR = $paths.Target
    Write-Info 'Preparing the Rust toolchain pinned by this backend (first build may download components)...'
    $code = Invoke-Native $script:CargoExe @('--version') $paths.Source
    if ($code -ne 0) { throw 'Cargo could not prepare the backend toolchain.' }
    if ($script:Options.Test) {
        Write-Info 'Running cargo test --workspace...'
        $code = Invoke-Native $script:CargoExe @('test', '--workspace') $paths.Source
        if ($code -ne 0) { throw ('Backend tests failed (exit code ' + $code + ').') }
    }
    Write-Info ('Building ' + $backend.name + ' in release mode...')
    $code = Invoke-Native $script:CargoExe @('build', '--release', '-p', [string]$backend.package) $paths.Source
    if ($code -ne 0) { throw ('Cargo build failed (exit code ' + $code + ').') }
    $built = Join-Path $paths.Target ('release\' + [string]$backend.binary)
    if (-not (Test-Path -LiteralPath $built -PathType Leaf)) { throw ('Expected backend binary was not produced: ' + $built) }
    New-Item -ItemType Directory -Force -Path $paths.BinaryDir | Out-Null
    $destination = Join-Path $paths.BinaryDir ([string]$backend.binary)
    Copy-Item -LiteralPath $built -Destination $destination -Force
    Write-Ok ('Built binary: ' + $destination)
}

function Test-Backend([string]$Executable) {
    $backend = Get-Backend
    $paths = Get-BackendPaths $script:Options.Backend
    $binary = Join-Path $paths.BinaryDir ([string]$backend.binary)
    if ($backend.engine -eq 'victory') {
        $env:VICTORY_CONFIG = $paths.Config
        $code = Invoke-Native $binary @('config') $paths.Source
        if ($code -ne 0) { throw 'The backend rejected its generated config file.' }
    }
    $code = Invoke-Native $binary @('inspect', $Executable) $paths.Source
    if ($code -ne 0) { throw 'The backend could not inspect the selected executable. Review the game folder and backend requirements.' }
    Write-Ok 'Backend configuration and executable inspection passed.'
}

function Start-Backend([string]$BackendName, [string]$Executable, [string[]]$GameArguments) {
    $script:Options.Backend = $BackendName
    $backend = Get-Backend
    $paths = Get-BackendPaths $BackendName
    $binary = Join-Path $paths.BinaryDir ([string]$backend.binary)
    if (-not (Test-Path -LiteralPath $binary -PathType Leaf)) {
        throw ('Backend binary not found: ' + $binary + '. Run r4y.cmd --backend ' + $BackendName + ' to build it.')
    }
    if (-not (Test-Path -LiteralPath $Executable -PathType Leaf)) { throw ('Game executable no longer exists: ' + $Executable) }
    $oldVictoryConfig = $env:VICTORY_CONFIG
    $oldXclDataRoot = $env:XCL_DATA_ROOT
    try {
        if ($backend.engine -eq 'victory') {
            $env:VICTORY_CONFIG = $paths.Config
            if ($env:R4Y_LOG) { $env:VICTORY_LOG = $env:R4Y_LOG }
            if ($env:R4Y_D3D12_DEBUG) { $env:VICTORY_D3D12_DEBUG = $env:R4Y_D3D12_DEBUG }
            if ($env:R4Y_D3D12_DRED) { $env:VICTORY_D3D12_DRED = $env:R4Y_D3D12_DRED }
            if ($env:R4Y_D3D12_WARP) { $env:VICTORY_D3D12_WARP = $env:R4Y_D3D12_WARP }
            $arguments = @('run', $Executable, '--execute')
        } else {
            New-Item -ItemType Directory -Force -Path $paths.Data | Out-Null
            $env:XCL_DATA_ROOT = $paths.Data
            $arguments = @('run', $Executable)
        }
        if ($GameArguments -and $GameArguments.Count -gt 0) { $arguments += @('--') + $GameArguments }
        Write-Info ('Launching ' + $backend.name + ': ' + $Executable)
        return (Invoke-Native $binary $arguments $paths.Source)
    } finally {
        $env:VICTORY_CONFIG = $oldVictoryConfig
        $env:XCL_DATA_ROOT = $oldXclDataRoot
    }
}

function Write-Launcher {
    $launcher = Join-Path $script:Root 'r4y-run.cmd'
    $lines = @(
        '@echo off',
        'setlocal',
        'chcp 65001 >nul',
        'rem Portable launcher: all paths are resolved relative to this repository.',
        'powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\r4y.ps1" --launch %*',
        'set "R4Y_EXIT=%ERRORLEVEL%"',
        'if not "%R4Y_EXIT%"=="0" pause',
        'exit /b %R4Y_EXIT%'
    )
    [IO.File]::WriteAllLines($launcher, $lines, (New-Object System.Text.UTF8Encoding($false)))
    Write-Ok ('Launcher: ' + $launcher)
}

function Invoke-Launch {
    $state = Load-State
    if (-not $state) { throw 'No R4Y setup was found. Run r4y.cmd first.' }
    $backendName = [string]$state.backend
    if ($script:Backends.backends.PSObject.Properties.Name -notcontains $backendName) { throw ('Unknown backend in local state: ' + $backendName) }
    if (-not $state.exe) { throw 'The local R4Y state does not contain a game executable. Run setup again.' }
    $code = Start-Backend $backendName ([string]$state.exe) $script:Options.GameArgs
    if ($code -ne 0) { Write-Warn ('The backend exited with code ' + $code + '. Check the backend logs under %LOCALAPPDATA%\R4Y\backends\.') }
    return $code
}

function Invoke-Setup {
    $backend = Get-Backend
    Write-Host ''
    Write-Host ('  R4Y | Recompile4You | ' + $backend.name) -ForegroundColor Magenta
    Write-Info ('Backend source: ' + $backend.repository)
    if (-not [Environment]::Is64BitOperatingSystem) { throw 'R4Y requires Windows 10/11 x64.' }
    Show-Hardware
    Resolve-Tools
    $packages = @(Get-WantedPackages)
    if ($packages.Count -eq 0) { Write-Ok 'Git, Rust, and Visual Studio C++ build tools are available.' }
    else { foreach ($package in $packages) { Write-Warn ('Missing: ' + $package.Name) } }
    if ($script:Options.DryRun) {
        Write-Ok 'Dry run completed. No packages, repositories, config files, or game files were changed.'
        return 0
    }
    if ($packages.Count -gt 0) {
        if (-not (Confirm-Action 'Install the missing dependencies with winget?')) { throw 'Dependency installation was declined.' }
        Install-Packages $packages
    }
    if ($script:RebootNeeded) { Write-Warn 'An installer requested a Windows restart. Restart and run r4y.cmd again.'; return 0 }
    if (-not $script:GitExe) { throw 'Git is still unavailable after dependency setup.' }
    if (-not $script:CargoExe) { throw 'Cargo is still unavailable after dependency setup. Open a new terminal and run R4Y again.' }
    if (-not (Get-MsvcRoot) -or -not (Test-WindowsSdk)) { throw 'Visual Studio C++ Build Tools and a Windows SDK are required.' }

    Write-Step '1/5  Updating the selected backend'
    Update-BackendSource
    Apply-BackendPatches

    Write-Step '2/5  Selecting the game executable'
    $selection = Select-Game
    $gameDir = [string]$selection[0]
    $gameExe = [string]$selection[1]
    Save-State $script:Options.Backend $gameDir $gameExe
    Write-Ok ('Game folder: ' + $gameDir)
    Write-Ok ('Executable: ' + $gameExe)

    Write-Step '3/5  Writing isolated backend configuration'
    Write-BackendConfig $gameDir
    Write-Launcher
    if ($script:Options.NoBuild) {
        Write-Ok 'Setup saved. Build skipped (--no-build). Run r4y.cmd again without --no-build to compile.'
        return 0
    }

    Write-Step '4/5  Building and validating'
    Build-Backend
    Test-Backend $gameExe

    Write-Step '5/5  Ready'
    Write-Ok ('Backend ready: ' + $script:Options.Backend)
    Write-Info 'To launch later, use r4y-run.cmd. Backend data and logs are stored outside the source checkout.'
    if (-not $script:Options.NoRun -and -not [Console]::IsInputRedirected) {
        if (Confirm-Action 'Launch the game now?') {
            $code = Start-Backend $script:Options.Backend $gameExe $script:Options.GameArgs
            if ($code -ne 0) { Write-Warn ('The backend exited with code ' + $code + '.') }
            return $code
        }
    }
    return 0
}
