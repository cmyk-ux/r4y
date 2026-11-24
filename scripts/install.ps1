# R4Y Windows installer and launcher.
# One workspace, one runtime. No runtime/backend download or selection.
[CmdletBinding()]
param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Arguments)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$script:Root = Split-Path -Parent $PSCommandPath
$script:LocalRoot = Join-Path $env:LOCALAPPDATA 'R4Y'
$script:ConfigPath = Join-Path $script:LocalRoot 'r4y.toml'
$script:StatePath = Join-Path $script:LocalRoot 'install-state.json'
$script:LogPath = Join-Path $script:LocalRoot 'logs\installer.log'
$script:DryRun = $false
$script:NoBuild = $false
$script:NoRun = $false
$script:AssumeYes = $false
$script:RunTests = $false
$script:Diagnostics = $false
$script:LaunchOnly = $false
$script:GamePath = $null
$script:ExePath = $null
$script:TitleArgs = @()
$script:TranscriptStarted = $false

function Show-Help {
@'
R4Y — Recompile4You

Usage:
  r4y.cmd [options]
  r4y-run.cmd [-- title arguments]

Options:
  --dry-run       Check prerequisites without installing or writing setup files
  --no-build      Save local game/config selection but skip compilation
  --no-run        Build and validate without offering to launch
  --yes           Accept prerequisite installation prompts
  --test          Run cargo test --workspace --locked before building
  --diagnostics   Build the diagnostics profile instead of normal release
  --game PATH     Select a game folder without opening the folder picker
  --exe PATH      Select an executable inside the selected folder
  --launch        Launch the last configured game without running setup
  --help          Show this help

R4Y builds the one Rust workspace in this repository. No additional engine is downloaded.
'@ | Write-Host
}

function Parse-Arguments([string[]]$Items) {
    for ($i = 0; $i -lt $Items.Count; $i++) {
        switch -CaseSensitive ($Items[$i]) {
            '--dry-run' { $script:DryRun = $true }
            '--no-build' { $script:NoBuild = $true }
            '--no-run' { $script:NoRun = $true }
            '--yes' { $script:AssumeYes = $true }
            '--test' { $script:RunTests = $true }
            '--diagnostics' { $script:Diagnostics = $true }
            '--launch' { $script:LaunchOnly = $true }
            '--help' { Show-Help; exit 0 }
            '-h' { Show-Help; exit 0 }
            '--game' {
                $i++
                if ($i -ge $Items.Count) { throw '--game requires a folder path.' }
                $script:GamePath = $Items[$i]
            }
            '--exe' {
                $i++
                if ($i -ge $Items.Count) { throw '--exe requires an executable path.' }
                $script:ExePath = $Items[$i]
            }
            '--' {
                if ($i + 1 -lt $Items.Count) { $script:TitleArgs = @($Items[($i + 1)..($Items.Count - 1)]) }
                return
            }
            default { throw ('Unknown option: ' + $Items[$i] + '. Use --help.') }
        }
    }
}

function Write-Step([string]$Message) { Write-Host ''; Write-Host ('==> ' + $Message) -ForegroundColor Cyan }
function Write-Info([string]$Message) { Write-Host ('  ' + $Message) -ForegroundColor Gray }
function Write-Ok([string]$Message) { Write-Host ('[OK] ' + $Message) -ForegroundColor Green }
function Write-Warn([string]$Message) { Write-Host ('[!] ' + $Message) -ForegroundColor Yellow }

function Confirm-Action([string]$Question) {
    if ($script:AssumeYes) { return $true }
    if ([Console]::IsInputRedirected) { return $false }
    return ((Read-Host ($Question + ' [y/N]')) -match '^(?i:y|yes|s|sim)$')
}

function Invoke-Native([string]$Executable, [string[]]$NativeArgs, [string]$WorkingDirectory) {
    $previous = Get-Location
    try {
        if ($WorkingDirectory) { Set-Location -LiteralPath $WorkingDirectory }
        & $Executable @NativeArgs
        return [int]$LASTEXITCODE
    } finally { Set-Location $previous }
}

function Get-VsWhere {
    $pf86 = [Environment]::GetEnvironmentVariable('ProgramFiles(x86)')
    if (-not $pf86) { return $null }
    $path = Join-Path $pf86 'Microsoft Visual Studio\Installer\vswhere.exe'
    if (Test-Path -LiteralPath $path -PathType Leaf) { return $path }
    return $null
}

function Get-VisualStudio {
    $vswhere = Get-VsWhere
    if (-not $vswhere) { return $null }
    $output = @(& $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath 2>$null)
    if ($LASTEXITCODE -ne 0 -or $output.Count -eq 0) { return $null }
    $root = ([string]$output[0]).Trim()
    $devCmd = Join-Path $root 'Common7\Tools\VsDevCmd.bat'
    if (-not $root -or -not (Test-Path -LiteralPath $devCmd -PathType Leaf)) { return $null }
    return [pscustomobject]@{ Root = $root; DevCmd = $devCmd }
}

function Initialize-MsvcEnvironment {
    $vs = Get-VisualStudio
    if (-not $vs) { throw 'Visual Studio 2022 C++ Build Tools were not found. Install the C++ workload and Windows SDK.' }
    $cmdLine = '""' + $vs.DevCmd + '" -no_logo -arch=x64 && set"'
    $environment = @(& $env:ComSpec /d /s /c $cmdLine)
    if ($LASTEXITCODE -ne 0) { throw 'VsDevCmd.bat failed to initialize the MSVC environment.' }
    foreach ($line in $environment) {
        if ($line -match '^([^=]+)=(.*)$') {
            [Environment]::SetEnvironmentVariable($Matches[1], $Matches[2], 'Process')
        }
    }
    $pf86 = [Environment]::GetEnvironmentVariable('ProgramFiles(x86)')
    $sdkRoot = Join-Path $pf86 'Windows Kits\10\Include'
    $sdk = Get-ChildItem -LiteralPath $sdkRoot -Directory -ErrorAction SilentlyContinue |
        Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'um\d3d12.h') } |
        Sort-Object Name -Descending | Select-Object -First 1
    if (-not $sdk) { throw 'Windows SDK headers (including d3d12.h) were not found.' }
    Write-Ok ('MSVC: ' + $vs.Root)
    Write-Ok ('Windows SDK: ' + $sdk.Name)
}

function Get-Cargo {
    $rustup = Get-Command rustup.exe -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $rustup) { return $null }
    $cargo = Get-Command cargo.exe -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($cargo) { return [string]$cargo.Source }
    $fallback = Join-Path $env:USERPROFILE '.cargo\bin\cargo.exe'
    if (Test-Path -LiteralPath $fallback -PathType Leaf) { return $fallback }
    return $null
}

function Get-MissingPrerequisites {
    $missing = @()
    if (-not (Get-Cargo)) { $missing += [pscustomobject]@{ Name = 'Rustup and Cargo'; Id = 'Rustlang.Rustup'; Override = $null } }
    if (-not (Get-VisualStudio)) {
        $override = '--wait --quiet --norestart --add Microsoft.VisualStudio.Workload.VCTools --includeRecommended'
        $missing += [pscustomobject]@{ Name = 'Visual Studio 2022 C++ Build Tools and Windows SDK'; Id = 'Microsoft.VisualStudio.2022.BuildTools'; Override = $override }
    }
    return $missing
}

function Install-Prerequisites($Packages) {
    $winget = Get-Command winget.exe -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $winget) { throw 'winget was not found. Install Rustup and Visual Studio 2022 C++ Build Tools manually.' }
    foreach ($package in $Packages) {
        Write-Info ('Installing ' + $package.Name)
        $wingetArgs = @('install', '--id', $package.Id, '--exact', '--source', 'winget', '--accept-package-agreements', '--accept-source-agreements')
        if ($package.Override) { $wingetArgs += @('--override', $package.Override) }
        & $winget.Source @wingetArgs
        $code = $LASTEXITCODE
        if ($code -ne 0 -and $code -ne 3010) { throw ('winget failed to install ' + $package.Name + ' (exit ' + $code + ').') }
    }
    Write-Warn 'Prerequisites were installed. Open a new terminal and run r4y.cmd again.'
    throw 'R4Y setup paused after prerequisite installation.'
}

function Test-Avx2 {
    try {
        if (-not ('R4Y.Native' -as [type])) {
            Add-Type -TypeDefinition 'using System.Runtime.InteropServices; namespace R4Y { public static class Native { [DllImport("kernel32.dll")] public static extern bool IsProcessorFeaturePresent(uint feature); } }'
        }
        return [R4Y.Native]::IsProcessorFeaturePresent(40)
    } catch { return $null }
}

function Show-Hardware {
    $os = Get-CimInstance Win32_OperatingSystem
    Write-Info ($os.Caption + ' (' + $os.OSArchitecture + ')')
    $cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
    Write-Info ('CPU: ' + $cpu.Name)
    $avx2 = Test-Avx2
    if ($avx2 -eq $false) { throw 'This R4Y runtime requires AVX2 CPU support.' }
    if ($avx2 -eq $true) { Write-Ok 'AVX2 supported.' } else { Write-Warn 'Could not verify AVX2 support.' }
    foreach ($gpu in (Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue)) {
        Write-Info ('Display adapter: ' + $gpu.Name)
    }
    Write-Info 'The runtime performs the actual D3D12 adapter and shader capability checks.'
}

function Pick-Folder {
    try {
        Add-Type -AssemblyName System.Windows.Forms
        $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
        $dialog.Description = 'Select the folder containing your own, already-readable game files.'
        if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { return $dialog.SelectedPath }
    } catch { Write-Warn 'Folder picker unavailable; enter the path manually.' }
    return $null
}

function Pick-File([string]$Directory) {
    try {
        Add-Type -AssemblyName System.Windows.Forms
        $dialog = New-Object System.Windows.Forms.OpenFileDialog
        $dialog.Filter = 'Game executable (*.exe)|*.exe|All files (*.*)|*.*'
        $dialog.InitialDirectory = $Directory
        if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { return $dialog.FileName }
    } catch { Write-Warn 'File picker unavailable; enter the path manually.' }
    return $null
}

function Load-State {
    if (-not (Test-Path -LiteralPath $script:StatePath -PathType Leaf)) { return $null }
    try { return (Get-Content -LiteralPath $script:StatePath -Raw | ConvertFrom-Json) } catch { return $null }
}

function Save-State([string]$GameDirectory, [string]$Executable) {
    New-Item -ItemType Directory -Force -Path $script:LocalRoot | Out-Null
    $profile = if ($script:Diagnostics) { 'diag' } else { 'release' }
    ([pscustomobject]@{ schema_version = 1; game_dir = $GameDirectory; exe = $Executable; profile = $profile }) |
        ConvertTo-Json -Depth 3 | Set-Content -LiteralPath $script:StatePath -Encoding UTF8
}

function Select-Game {
    $state = Load-State
    if (-not $script:GamePath -and -not $script:ExePath -and $state -and $state.game_dir -and $state.exe -and
        (Test-Path -LiteralPath $state.game_dir -PathType Container) -and (Test-Path -LiteralPath $state.exe -PathType Leaf)) {
        if ($script:AssumeYes) { return @($state.game_dir, $state.exe) }
        if (-not [Console]::IsInputRedirected) {
            $answer = Read-Host ('Reuse last game executable ' + $state.exe + '? [Y/n]')
            if (-not $answer -or $answer -notmatch '^(?i:n|no|nao)$') { return @($state.game_dir, $state.exe) }
        }
    }

    $directory = $script:GamePath
    if (-not $directory -and -not [Console]::IsInputRedirected) {
        $typed = Read-Host 'Enter the game folder, or press ENTER to browse'
        if ($typed) { $directory = $typed.Trim().Trim('"') }
    }
    if (-not $directory) { $directory = Pick-Folder }
    if (-not $directory -or -not (Test-Path -LiteralPath $directory -PathType Container)) { throw 'A valid game folder was not selected.' }
    $directory = (Resolve-Path -LiteralPath $directory).ProviderPath

    $executable = $script:ExePath
    if (-not $executable) {
        $found = @()
        $found += @(Get-ChildItem -LiteralPath $directory -Filter '*.exe' -File -ErrorAction SilentlyContinue)
        foreach ($child in (Get-ChildItem -LiteralPath $directory -Directory -ErrorAction SilentlyContinue)) {
            $found += @(Get-ChildItem -LiteralPath $child.FullName -Filter '*.exe' -File -ErrorAction SilentlyContinue)
        }
        if ($found.Count -eq 1) {
            $executable = $found[0].FullName
        } elseif ($found.Count -gt 1 -and -not [Console]::IsInputRedirected) {
            for ($i = 0; $i -lt $found.Count; $i++) { Write-Host ('[' + ($i + 1) + '] ' + $found[$i].FullName) }
            $choice = Read-Host 'Enter an executable number, or press ENTER to browse'
            if ($choice -match '^\d+$' -and [int]$choice -ge 1 -and [int]$choice -le $found.Count) {
                $executable = $found[[int]$choice - 1].FullName
            }
        }
        if (-not $executable) { $executable = Pick-File $directory }
        if (-not $executable -and -not [Console]::IsInputRedirected) {
            $executable = (Read-Host 'Enter the full path to the game executable').Trim().Trim('"')
        }
    }
    if (-not $executable -or -not (Test-Path -LiteralPath $executable -PathType Leaf)) { throw 'A valid game executable was not selected.' }
    $executable = (Resolve-Path -LiteralPath $executable).ProviderPath
    $prefix = $directory.TrimEnd('\') + '\'
    if (-not $executable.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'The executable must be inside the selected game folder.'
    }
    return @($directory, $executable)
}

function ConvertTo-TomlString([string]$Value) {
    $slash = [string][char]92
    $quote = [string][char]34
    $escaped = $Value.Replace($slash, $slash + $slash).Replace($quote, $slash + $quote)
    $escaped = $escaped.Replace([string][char]13, '\r').Replace([string][char]10, '\n')
    return $quote + $escaped + $quote
}

function Write-Config([string]$GameDirectory, [string]$Executable) {
    $cache = Join-Path $script:LocalRoot 'cache'
    $data = Join-Path $script:LocalRoot 'data'
    New-Item -ItemType Directory -Force -Path $cache, $data | Out-Null
    $legacy = Join-Path $env:LOCALAPPDATA 'victory\data'
    if ((Test-Path -LiteralPath $legacy -PathType Container) -and
        -not (Get-ChildItem -LiteralPath $data -Force -ErrorAction SilentlyContinue | Select-Object -First 1)) {
        if (Confirm-Action 'Copy existing VIctory saved data into R4Y? The original directory will remain untouched.') {
            Get-ChildItem -LiteralPath $legacy -Force | Copy-Item -Destination $data -Recurse -Force
        }
    }
    $lines = @(
        '# Generated by R4Y. Edit or rerun r4y.cmd to change the selection.',
        '[paths]',
        ('game_dir = ' + (ConvertTo-TomlString $GameDirectory)),
        ('cache_dir = ' + (ConvertTo-TomlString $cache)),
        ('data_dir = ' + (ConvertTo-TomlString $data)),
        'test_titles = []'
    )
    [IO.File]::WriteAllLines($script:ConfigPath, $lines, (New-Object System.Text.UTF8Encoding($false)))
    Save-State $GameDirectory $Executable
    $env:R4Y_CONFIG = $script:ConfigPath
    $env:VICTORY_CONFIG = $script:ConfigPath
    Write-Ok ('Configuration saved: ' + $script:ConfigPath)
}

function Get-R4YExecutable {
    $profile = if ($script:Diagnostics) { 'diag' } else { 'release' }
    $path = Join-Path $script:Root ('target\' + $profile + '\r4y.exe')
    if (Test-Path -LiteralPath $path -PathType Leaf) { return $path }
    return $null
}

function Build-R4Y([string]$Cargo) {
    if ($script:RunTests) {
        $testCode = Invoke-Native $Cargo @('test', '--workspace', '--locked') $script:Root
        if ($testCode -ne 0) { throw 'Workspace tests failed.' }
    }
    if ($script:Diagnostics) {
        $buildArgs = @('build', '--profile', 'diag', '--locked', '-p', 'r4y', '--features', 'diagnostics')
    } else {
        $buildArgs = @('build', '--release', '--locked', '-p', 'r4y')
    }
    $code = Invoke-Native $Cargo $buildArgs $script:Root
    if ($code -ne 0) { throw ('R4Y build failed with exit code ' + $code + '.') }
    $binary = Get-R4YExecutable
    if (-not $binary) { throw 'Cargo did not produce the R4Y executable.' }
    Write-Ok ('Built ' + $binary)
    return $binary
}

function Invoke-Launch {
    $state = Load-State
    if (-not $state -or -not $state.exe) { throw 'No game is configured. Run r4y.cmd first.' }
    if (-not (Test-Path -LiteralPath $state.exe -PathType Leaf)) { throw 'The configured game executable no longer exists.' }
    $env:R4Y_CONFIG = $script:ConfigPath
    $env:VICTORY_CONFIG = $script:ConfigPath
    $script:Diagnostics = ([string]$state.profile -eq 'diag')
    $binary = Get-R4YExecutable
    if (-not $binary) { throw 'R4Y is not built. Run r4y.cmd to compile the workspace.' }
    $runArgs = @('run', [string]$state.exe, '--execute') + $script:TitleArgs
    return (Invoke-Native $binary $runArgs $script:Root)
}

function Invoke-Setup {
    if (-not [Environment]::Is64BitOperatingSystem) { throw 'R4Y requires Windows x64.' }
    $os = Get-CimInstance Win32_OperatingSystem
    if ($os.Caption -notmatch 'Windows 10|Windows 11') { throw ('Unsupported Windows version: ' + $os.Caption) }
    Show-Hardware
    $missing = @(Get-MissingPrerequisites)
    if ($missing.Count -gt 0) {
        foreach ($item in $missing) { Write-Warn ('Missing: ' + $item.Name) }
        if ($script:DryRun) { return 0 }
        if (-not (Confirm-Action 'Install missing prerequisites through winget?')) { throw 'Prerequisite installation was declined.' }
        Install-Prerequisites $missing
    }
    if ($script:DryRun) { Write-Ok 'Dry run complete; no files or prerequisites were changed.'; return 0 }

    Initialize-MsvcEnvironment
    $cargo = Get-Cargo
    if (-not $cargo) { throw 'Cargo was not found after prerequisite checks. Open a new terminal and rerun R4Y.' }

    Write-Step 'Select your game folder and executable'
    $selection = Select-Game
    $gameDirectory = [string]$selection[0]
    $script:ExePath = [string]$selection[1]
    Write-Config $gameDirectory $script:ExePath

    if ($script:NoBuild) {
        Write-Ok 'Configuration saved; build skipped by --no-build.'
        return 0
    }

    $binary = Build-R4Y $cargo
    $env:R4Y_CONFIG = $script:ConfigPath
    $env:VICTORY_CONFIG = $script:ConfigPath
    $inspect = Invoke-Native $binary @('inspect', $script:ExePath) $script:Root
    if ($inspect -ne 0) { throw 'R4Y could not inspect the selected executable. Check the game folder and executable.' }
    Write-Launcher
    Write-Ok 'R4Y is ready. Use r4y-run.cmd to launch later.'
    if (-not $script:NoRun -and -not [Console]::IsInputRedirected -and (Confirm-Action 'Launch the game now?')) {
        return (Invoke-Launch)
    }
    return 0
}

function Write-Launcher {
    $launcher = Join-Path $script:Root 'r4y-run.cmd'
    $lines = @(
        '@echo off',
        'setlocal',
        'chcp 65001 >nul',
        'powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\install.ps1" --launch %*',
        'set "R4Y_EXIT=%ERRORLEVEL%"',
        'if not "%R4Y_EXIT%"=="0" pause',
        'exit /b %R4Y_EXIT%'
    )
    [IO.File]::WriteAllLines($launcher, $lines, (New-Object System.Text.UTF8Encoding($false)))
}

$exitCode = 1
try {
    Parse-Arguments $Arguments
    if (-not $script:LaunchOnly -and -not $script:DryRun) {
        New-Item -ItemType Directory -Force -Path (Join-Path $script:LocalRoot 'logs') | Out-Null
        try { Start-Transcript -Path $script:LogPath -Append | Out-Null; $script:TranscriptStarted = $true } catch {}
    }
    $exitCode = if ($script:LaunchOnly) { Invoke-Launch } else { Invoke-Setup }
} catch {
    Write-Host ''
    Write-Host 'R4Y setup failed:' -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Red
    Write-Host ('Log: ' + $script:LogPath) -ForegroundColor Yellow
    $exitCode = 1
} finally {
    if ($script:TranscriptStarted) { try { Stop-Transcript | Out-Null } catch {} }
}
exit $exitCode
