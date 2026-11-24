function Refresh-Environment {
    $machine = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $user = [Environment]::GetEnvironmentVariable('Path', 'User')
    $env:Path = $machine + ';' + $user
    $cargoBin = Join-Path $env:USERPROFILE '.cargo\bin'
    if (Test-Path -LiteralPath $cargoBin) { $env:Path += ';' + $cargoBin }
}

function Get-ToolPath([string]$Name, [string[]]$ExtraPaths) {
    $command = Get-Command $Name -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($command -and $command.Source) { return $command.Source }
    foreach ($path in $ExtraPaths) {
        if ($path -and (Test-Path -LiteralPath $path -PathType Leaf)) { return $path }
    }
    return $null
}

function Resolve-Tools {
    Refresh-Environment
    $programFiles = [Environment]::GetFolderPath('ProgramFiles')
    $script:GitExe = Get-ToolPath 'git.exe' @((Join-Path $programFiles 'Git\cmd\git.exe'))
    $script:CargoExe = Get-ToolPath 'cargo.exe' @((Join-Path $env:USERPROFILE '.cargo\bin\cargo.exe'))
    $script:WingetExe = Get-ToolPath 'winget.exe' @()
}

function Get-MsvcRoot {
    $programFilesX86 = [Environment]::GetFolderPath('ProgramFilesX86')
    $vswhere = Join-Path $programFilesX86 'Microsoft Visual Studio\Installer\vswhere.exe'
    if (-not (Test-Path -LiteralPath $vswhere -PathType Leaf)) { return $null }
    $path = & $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath 2>$null
    if ($LASTEXITCODE -eq 0 -and $path) { return [string]($path | Select-Object -First 1) }
    return $null
}

function Test-WindowsSdk {
    $programFilesX86 = [Environment]::GetFolderPath('ProgramFilesX86')
    $sdkRoot = Join-Path $programFilesX86 'Windows Kits\10\Lib'
    if (-not (Test-Path -LiteralPath $sdkRoot)) { return $false }
    $sdk = Get-ChildItem -LiteralPath $sdkRoot -Directory -ErrorAction SilentlyContinue |
        Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'um\x64\kernel32.lib') } |
        Select-Object -First 1
    return [bool]$sdk
}

function Test-Avx2 {
    try {
        if (-not ('R4Y.Native' -as [type])) {
            Add-Type -Namespace R4Y -Name Native -MemberDefinition '[DllImport("kernel32.dll")] public static extern bool IsProcessorFeaturePresent(int feature);' -ErrorAction Stop
        }
        return [bool][R4Y.Native]::IsProcessorFeaturePresent(40)
    } catch { return $null }
}

function Show-Hardware {
    $os = Get-CimInstance Win32_OperatingSystem
    if ($os.Caption -notmatch 'Windows 10|Windows 11') { throw ('Unsupported operating system: ' + $os.Caption) }
    $ramGb = [math]::Round($os.TotalVisibleMemorySize / 1MB, 1)
    $commitGb = [math]::Round($os.TotalVirtualMemorySize / 1MB, 1)
    Write-Info ('Windows: ' + $os.Caption)
    Write-Info ('RAM: ' + $ramGb + ' GiB | commit limit: ' + $commitGb + ' GiB')
    foreach ($gpu in @(Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue)) { Write-Info ('GPU: ' + $gpu.Name) }
    $avx2 = Test-Avx2
    if ($avx2 -eq $true) { Write-Ok 'CPU supports AVX2.' }
    elseif ($avx2 -eq $false) { throw 'This backend requires a CPU with AVX2.' }
    else { Write-Warn 'Could not verify AVX2 support.' }
    if ($commitGb -lt 32) { Write-Warn 'Commit limit is below 32 GiB; some titles may need a larger Windows paging file.' }
    Write-Info 'GPU feature support is backend- and driver-dependent; the listed adapter is informational, not a compatibility guarantee.'
}

function Get-WantedPackages {
    $packages = @()
    if (-not $script:GitExe) { $packages += [pscustomobject]@{ Name = 'Git'; Id = 'Git.Git'; Override = $null } }
    if (-not $script:CargoExe) { $packages += [pscustomobject]@{ Name = 'Rustup (Rust)'; Id = 'Rustlang.Rustup'; Override = $null } }
    if (-not (Get-MsvcRoot)) {
        $packages += [pscustomobject]@{
            Name = 'Visual Studio 2022 Build Tools (C++ and Windows SDK)'
            Id = 'Microsoft.VisualStudio.2022.BuildTools'
            Override = '--passive --wait --norestart --add Microsoft.VisualStudio.Workload.VCTools --add Microsoft.VisualStudio.Component.Windows11SDK.26100 --includeRecommended'
        }
    } elseif (-not (Test-WindowsSdk)) {
        Write-Warn 'Visual Studio C++ is installed, but a Windows SDK was not found. Add a Windows 10/11 SDK in Visual Studio Installer.'
    }
    return $packages
}

function Confirm-Action([string]$Question) {
    if ($script:Options.Yes) { return $true }
    if ([Console]::IsInputRedirected) { return $false }
    $answer = Read-Host ($Question + ' [Y/n]')
    return (-not $answer -or $answer -match '^(?i:y|yes|s|sim)$')
}

function Install-Packages($Packages) {
    if (-not $script:WingetExe) { throw 'winget was not found. Install App Installer from Microsoft Store or install Git, Rustup, and Visual Studio Build Tools manually.' }
    foreach ($package in $Packages) {
        Write-Info ('Installing ' + $package.Name + '...')
        $arguments = @('install', '--id', $package.Id, '-e', '--source', 'winget', '--accept-package-agreements', '--accept-source-agreements')
        if ($package.Override) { $arguments += @('--override', $package.Override) }
        & $script:WingetExe @arguments | Out-Host
        $code = $LASTEXITCODE
        if ($code -eq 3010 -or $code -eq 1641) { $script:RebootNeeded = $true }
        elseif ($code -ne 0) { throw ('winget failed to install ' + $package.Name + ' (exit code ' + $code + ').') }
    }
    Resolve-Tools
}

function Invoke-Native([string]$Executable, [string[]]$Arguments, [string]$WorkingDirectory) {
    $previous = Get-Location
    try {
        if ($WorkingDirectory) { Set-Location -LiteralPath $WorkingDirectory }
        & $Executable @Arguments
        if ($null -eq $LASTEXITCODE) { return 0 }
        return [int]$LASTEXITCODE
    } finally { Set-Location $previous }
}

