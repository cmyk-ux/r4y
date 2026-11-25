# R4Y Windows installer and launcher.
# One workspace, one runtime. No runtime/backend download or selection.
[CmdletBinding()]
param([string]$OptionString = '')

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$script:ScriptDirectory = Split-Path -Parent $PSCommandPath
$script:Root = Split-Path -Parent $script:ScriptDirectory
if (-not (Test-Path -LiteralPath (Join-Path $script:Root 'Cargo.toml') -PathType Leaf) -or
    -not (Test-Path -LiteralPath (Join-Path $script:Root 'apps\r4y\Cargo.toml') -PathType Leaf)) {
    throw ('Could not resolve the R4Y workspace root from installer path: ' + $PSCommandPath)
}
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
$script:CheckMsvc = $false
$script:TestNativeOutput = $false
$script:TranscriptStarted = $false

function Show-Help {
@'
R4Y — Recompile4You

Usage:
  r4y.cmd [options]
  r4y-run.cmd

Options:
  --dry-run       Check prerequisites without installing or writing setup files
  --no-build      Save local game/config selection but skip compilation
  --no-run        Build and validate without offering to launch
  --yes           Accept prerequisite installation prompts
  --test          Run cargo test --workspace --locked before building
  --diagnostics   Build the diagnostics profile instead of normal release
  --launch        Launch the last configured game without running setup
  --check-msvc    Validate the Visual C++ build environment and exit
  --test-native-output  Verify native stderr does not abort PowerShell
  --help          Show this help

R4Y builds the one Rust workspace in this repository. No additional runtime is downloaded.
'@ | Write-Host
}

function Parse-Arguments([string]$Line) {
    $Items = @($Line -split '\s+' | Where-Object { $_ })
    for ($i = 0; $i -lt $Items.Count; $i++) {
        switch -CaseSensitive ($Items[$i]) {
            '--dry-run' { $script:DryRun = $true }
            '--no-build' { $script:NoBuild = $true }
            '--no-run' { $script:NoRun = $true }
            '--yes' { $script:AssumeYes = $true }
            '--test' { $script:RunTests = $true }
            '--diagnostics' { $script:Diagnostics = $true }
            '--launch' { $script:LaunchOnly = $true }
            '--check-msvc' { $script:CheckMsvc = $true }
            '--test-native-output' { $script:TestNativeOutput = $true }
            '--help' { Show-Help; exit 0 }
            '-h' { Show-Help; exit 0 }
            default { throw ('Unknown option: ' + $Items[$i] + '. Use --help.') }
        }
    }
}

function Write-Step([string]$Message) { Write-Host ''; Write-Host ('==> ' + $Message) -ForegroundColor Cyan }
function Write-Info([string]$Message) { Write-Host ('  ' + $Message) -ForegroundColor Gray }
function Write-Ok([string]$Message) { Write-Host ('[OK] ' + $Message) -ForegroundColor Green }
function Write-Warn([string]$Message) { Write-Host ('[!] ' + $Message) -ForegroundColor Yellow }

function Enable-VirtualTerminal {
    if ([Console]::IsOutputRedirected) { return $false }
    try {
        if (-not ('R4YConsoleMode' -as [type])) {
            Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class R4YConsoleMode {
    [DllImport("kernel32.dll", SetLastError=true)]
    public static extern IntPtr GetStdHandle(int nStdHandle);
    [DllImport("kernel32.dll", SetLastError=true)]
    public static extern bool GetConsoleMode(IntPtr hConsoleHandle, out uint mode);
    [DllImport("kernel32.dll", SetLastError=true)]
    public static extern bool SetConsoleMode(IntPtr hConsoleHandle, uint mode);
}
'@ -ErrorAction Stop
        }
        $handle = [R4YConsoleMode]::GetStdHandle(-11)
        [uint32]$mode = 0
        if ($handle -eq [IntPtr]::Zero -or -not [R4YConsoleMode]::GetConsoleMode($handle, [ref]$mode)) {
            return $false
        }
        return [R4YConsoleMode]::SetConsoleMode($handle, ($mode -bor 0x0004))
    } catch {
        return $false
    }
}

function Show-Banner {
    # ASCII-style R4Y mark with Unicode block characters assembled by code point
    # so Windows PowerShell 5.1 can read the script without a UTF-8 BOM.
    $full = [string][char]0x2588
    $shade = [string][char]0x2592
    $logo = @(
        ' FFFFFFFFFFF   FFFFF FFFFF  FFFFF FFFFF',
        'SSFFFSSSSSFFF SSFFF SSFFF  SSFFF SSFFF ',
        ' SFFF    SFFF  SFFF  SFFF F SSFFF FFF  ',
        ' SFFFFFFFFFF   SFFFFFFFFFFF  SSFFFFF   ',
        ' SFFFSSSSSFFF  SSSSSSSFFF SF   SSFFF    ',
        ' SFFF    SFFF        SFFF S     SFFF    ',
        ' FFFFF   FFFFF       FFFFF     FFFFF   ',
        'SSSSS   SSSSS       SSSSS'
    )
    $rows = @(
        '                              .                         *                       .',
        '                   *                    .                       *',
        ''
    )
    foreach ($line in $logo) {
        $rows += $line.Replace('F', $full).Replace('S', $shade)
    }
    $rows += @(
        '',
        '                         R 4 Y   //   R E C O M P I L E 4 Y O U',
        '              NATIVE COMPATIBILITY  |  QUICK SETUP  |  INCREMENTAL BUILD',
        ''
    )

    try { $Host.UI.RawUI.WindowTitle = 'R4Y - Recompile4You' } catch {}
    $useVt = Enable-VirtualTerminal
    $script:BannerRows = $rows.Count
    $script:ScrollRegionActive = $false

    if ($useVt) {
        $esc = [char]27
        $stops = @(@(112,43,255), @(239,48,157), @(255,133,55), @(53,125,255))
        [Console]::Write("$esc[?25l")
        foreach ($row in $rows) {
            if ([string]::IsNullOrEmpty($row)) {
                [Console]::WriteLine()
                continue
            }
            $last = [Math]::Max(1, $row.Length - 1)
            for ($i = 0; $i -lt $row.Length; $i++) {
                $position = ($i / $last) * ($stops.Count - 1)
                $segment = [Math]::Min($stops.Count - 2, [int][Math]::Floor($position))
                $fraction = $position - $segment
                $red = [int][Math]::Round($stops[$segment][0] + ($stops[$segment + 1][0] - $stops[$segment][0]) * $fraction)
                $green = [int][Math]::Round($stops[$segment][1] + ($stops[$segment + 1][1] - $stops[$segment][1]) * $fraction)
                $blue = [int][Math]::Round($stops[$segment][2] + ($stops[$segment + 1][2] - $stops[$segment][2]) * $fraction)
                [Console]::Write(('{0}[38;2;{1};{2};{3}m{4}' -f $esc, $red, $green, $blue, $row[$i]))
            }
            [Console]::WriteLine("$esc[0m")
        }

        # Freeze the branding area; installer output scrolls only below it.
        $scrollStart = $script:BannerRows + 1
        [Console]::Write("$esc[$($scrollStart);r$esc[$($scrollStart);1H$esc[?25h")
        $script:ScrollRegionActive = $true
    } else {
        foreach ($row in $rows) { Write-Host $row -ForegroundColor Cyan }
    }
    Write-Host ''
}

function Reset-R4YScrollRegion {
    if ($script:ScrollRegionActive) {
        $esc = [char]27
        try { [Console]::Write("$esc[r$esc[?25h") } catch {}
        $script:ScrollRegionActive = $false
    }
}

function Confirm-Action([string]$Question) {
    if ($script:AssumeYes) { return $true }
    if ([Console]::IsInputRedirected) { return $false }
    return ((Read-Host ($Question + ' [y/N]')) -match '^(?i:y|yes)$')
}

function Invoke-Native([string]$Executable, [string[]]$NativeArgs, [string]$WorkingDirectory) {
    $previousLocation = Get-Location
    $previousErrorPreference = $ErrorActionPreference
    try {
        if ($WorkingDirectory) { Set-Location -LiteralPath $WorkingDirectory }

        # Windows PowerShell 5.1 converts native stderr into ErrorRecords.
        # Cargo writes routine progress (for example, "Compiling ...") to stderr;
        # with Stop, that first progress line aborts the build before the real
        # compiler diagnostic is printed. Keep native stderr non-terminating.
        $ErrorActionPreference = 'Continue'
        & $Executable @NativeArgs 2>&1 | ForEach-Object {
            Write-Host ([string]$_)
        }
        $nativeExitCode = [int]$LASTEXITCODE
        return $nativeExitCode
    } finally {
        $ErrorActionPreference = $previousErrorPreference
        Set-Location $previousLocation
    }
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
    if (-not $vs) {
        throw 'Visual Studio C++ Build Tools were not found. Install the C++ workload and a Windows SDK.'
    }

    # Run VsDevCmd in a child cmd.exe and import the resulting environment.
    # CALL returns control so SET executes after the developer environment loads.
    $cmdLine = 'call "{0}" -no_logo -arch=x64 -host_arch=x64 && set' -f $vs.DevCmd
    $environment = @(& $env:ComSpec /d /s /c $cmdLine 2>&1)
    $exitCode = $LASTEXITCODE

    if ($exitCode -ne 0) {
        $details = ($environment | ForEach-Object { [string]$_ }) -join [Environment]::NewLine
        if (-not $details) { $details = 'VsDevCmd did not return any diagnostic output.' }
        throw ("VsDevCmd.bat failed with exit code {0}.{1}{2}" -f $exitCode, [Environment]::NewLine, $details)
    }

    foreach ($line in $environment) {
        $entry = [string]$line
        if ($entry -match '^([^=]+)=(.*)$') {
            [Environment]::SetEnvironmentVariable($Matches[1], $Matches[2], 'Process')
        }
    }

    if (-not $env:VCToolsInstallDir) {
        throw 'VsDevCmd completed but did not set VCToolsInstallDir. The C++ toolset may be missing.'
    }
    $compiler = Get-Command cl.exe -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $compiler) {
        throw ('VsDevCmd completed but cl.exe is not on PATH. VCToolsInstallDir: ' + $env:VCToolsInstallDir)
    }

    $pf86 = [Environment]::GetEnvironmentVariable('ProgramFiles(x86)')
    if (-not $pf86) { throw 'ProgramFiles(x86) is not defined; cannot locate Windows SDK headers.' }
    $sdkRoot = Join-Path $pf86 'Windows Kits\10\Include'
    $sdk = Get-ChildItem -LiteralPath $sdkRoot -Directory -ErrorAction SilentlyContinue |
        Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'um\d3d12.h') } |
        Sort-Object Name -Descending | Select-Object -First 1
    if (-not $sdk) {
        throw ('Windows SDK headers (including d3d12.h) were not found under ' + $sdkRoot + '. Install the Windows SDK workload.')
    }

    Write-Ok ('MSVC: ' + $vs.Root)
    Write-Ok ('Compiler: ' + $compiler.Source)
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
    # Every setup asks for the data folder. Never bake one tester's absolute path
    # into the installer; the executable is resolved relative to the selected folder.
    $directory = $null
    if (-not [Console]::IsInputRedirected) {
        $typedDirectory = Read-Host 'Select the game folder (the folder containing game_scarlett_master.exe), or press ENTER to browse'
        if ($typedDirectory) { $directory = $typedDirectory.Trim().Trim('"') }
    }
    if (-not $directory) { $directory = Pick-Folder }
    if (-not $directory -or -not (Test-Path -LiteralPath $directory -PathType Container)) {
        throw 'A valid game folder was not selected.'
    }
    $directory = (Resolve-Path -LiteralPath $directory).ProviderPath

    # The executable must be in the selected folder. Resolve its path dynamically
    # so each tester can install the game anywhere on their own machine.
    $expectedExe = Join-Path $directory 'game_scarlett_master.exe'
    $executable = $null
    if (Test-Path -LiteralPath $expectedExe -PathType Leaf) {
        $executable = (Resolve-Path -LiteralPath $expectedExe).ProviderPath
    } else {
        $found = @(Get-ChildItem -LiteralPath $directory -Filter '*.exe' -File -ErrorAction SilentlyContinue)
        if ($found.Count -eq 1) {
            $executable = $found[0].FullName
        } elseif ($found.Count -gt 1 -and -not [Console]::IsInputRedirected) {
            Write-Warn 'game_scarlett_master.exe was not found; select the correct executable from this folder:'
            for ($i = 0; $i -lt $found.Count; $i++) {
                Write-Host ('[' + ($i + 1) + '] ' + $found[$i].Name)
            }
            $choice = Read-Host 'Executable number'
            if ($choice -match '^\d+$' -and [int]$choice -ge 1 -and [int]$choice -le $found.Count) {
                $executable = $found[[int]$choice - 1].FullName
            }
        }
    }

    if (-not $executable) {
        $executable = Pick-File $directory
    }
    if (-not $executable -and -not [Console]::IsInputRedirected) {
        $executable = (Read-Host 'Enter the full path to the executable inside the selected game folder').Trim().Trim('"')
    }
    if (-not $executable -or -not (Test-Path -LiteralPath $executable -PathType Leaf)) {
        throw 'A valid game executable was not selected in the chosen game folder.'
    }

    $candidate = Get-Item -LiteralPath $executable
    if ($candidate.Extension -ine '.exe') {
        throw ('The selected game executable must be a .exe file: ' + $candidate.FullName)
    }
    $executable = $candidate.FullName
    if (-not $executable.StartsWith(($directory.TrimEnd('\') + '\'), [StringComparison]::OrdinalIgnoreCase)) {
        throw 'The game executable must be inside the selected game folder.'
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
    Write-Ok ('Configuration saved: ' + $script:ConfigPath)
}

function Get-R4YExecutable {
    $profile = if ($script:Diagnostics) { 'diag' } else { 'release' }
    $targetRoot = Join-Path $script:Root 'target'
    if ($env:CARGO_TARGET_DIR) {
        if ([IO.Path]::IsPathRooted($env:CARGO_TARGET_DIR)) {
            $targetRoot = $env:CARGO_TARGET_DIR
        } else {
            $targetRoot = Join-Path $script:Root $env:CARGO_TARGET_DIR
        }
    }
    $path = Join-Path $targetRoot ($profile + '\r4y.exe')
    if (Test-Path -LiteralPath $path -PathType Leaf) { return (Resolve-Path -LiteralPath $path).ProviderPath }
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
    if (-not $binary) {
        $expectedProfile = if ($script:Diagnostics) { 'diag' } else { 'release' }
        $expectedPath = Join-Path $script:Root ('target\' + $expectedProfile + '\r4y.exe')
        throw ('Cargo reported a successful build, but the R4Y executable was not found at ' + $expectedPath +
            '. Workspace root: ' + $script:Root +
            '. CARGO_TARGET_DIR: ' + $env:CARGO_TARGET_DIR)
    }
    Write-Ok ('Built ' + $binary)
    return $binary
}

function Invoke-Launch {
    $state = Load-State
    if (-not $state -or -not $state.exe) { throw 'No game is configured. Run r4y.cmd first.' }
    if (-not (Test-Path -LiteralPath $state.exe -PathType Leaf)) { throw 'The configured game executable no longer exists.' }
    $env:R4Y_CONFIG = $script:ConfigPath
    $script:Diagnostics = ([string]$state.profile -eq 'diag')
    $binary = Get-R4YExecutable
    if (-not $binary) { throw 'R4Y is not built. Run r4y.cmd to compile the workspace.' }
    $runArgs = @('run', [string]$state.exe, '--execute')
    return (Invoke-Native $binary $runArgs $script:Root)
}

function Invoke-Setup {
    if (-not [Environment]::Is64BitOperatingSystem) { throw 'R4Y requires Windows x64.' }
    $os = Get-CimInstance Win32_OperatingSystem
    $isClientWindows = $os.Caption -match 'Windows 10|Windows 11'
    $isActionsServerDryRun = $script:DryRun -and $os.Caption -match 'Windows Server 2025'
    if (-not $isClientWindows -and -not $isActionsServerDryRun) { throw ('Unsupported Windows version: ' + $os.Caption) }
    if ($isActionsServerDryRun) { Write-Warn 'Windows Server is allowed here only for CI dry-run validation; normal installation still requires Windows 10/11.' }
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

    Write-Info ('R4Y workspace: ' + $script:Root)
    Write-Step 'Select the game folder (the installer finds the executable inside it)'
    $selection = Select-Game
    $gameDirectory = [string]$selection[0]
    $exePath = [string]$selection[1]
    Write-Config $gameDirectory $exePath

    if ($script:NoBuild) {
        Write-Ok 'Configuration saved; build skipped by --no-build.'
        return 0
    }

    $binary = Build-R4Y $cargo
    $env:R4Y_CONFIG = $script:ConfigPath
    $inspect = Invoke-Native $binary @('inspect', $exePath) $script:Root
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
    Show-Banner
    Parse-Arguments $OptionString
    if (-not $script:LaunchOnly -and -not $script:DryRun) {
        New-Item -ItemType Directory -Force -Path (Join-Path $script:LocalRoot 'logs') | Out-Null
        try { Start-Transcript -Path $script:LogPath -Append | Out-Null; $script:TranscriptStarted = $true } catch {}
    }
    $exitCode = if ($script:LaunchOnly) { Invoke-Launch } elseif ($script:CheckMsvc) { Initialize-MsvcEnvironment; Write-Ok 'MSVC build environment is ready.'; 0 } elseif ($script:TestNativeOutput) { $windowsPowerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'; $probeCode = Invoke-Native $windowsPowerShell @('-NoProfile', '-Command', '[Console]::Error.WriteLine(''R4Y native stderr probe''); exit 0') $script:Root; if ($probeCode -ne 0) { throw 'Native stderr handling probe failed.' }; Write-Ok 'Native stderr is handled without aborting the installer.'; 0 } else { Invoke-Setup }
} catch {
    Write-Host ''
    Write-Host 'R4Y setup failed:' -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Red
    Write-Host ('Log: ' + $script:LogPath) -ForegroundColor Yellow
    $exitCode = 1
} finally {
    Reset-R4YScrollRegion
    if ($script:TranscriptStarted) { try { Stop-Transcript | Out-Null } catch {} }
}
exit $exitCode
