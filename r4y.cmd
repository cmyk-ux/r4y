@echo off
setlocal EnableExtensions DisableDelayedExpansion
set "R4Y_DRY_RUN=0"
set "R4Y_NO_BUILD=0"
set "R4Y_NO_RUN=0"
set "R4Y_YES=0"
set "R4Y_TEST=0"
set "R4Y_CHANNEL=upstream"
:parse_args
if "%~1"=="" goto args_done
if /i "%~1"=="--dry-run" (
  set "R4Y_DRY_RUN=1"
  shift
  goto parse_args
)
if /i "%~1"=="--no-build" (
  set "R4Y_NO_BUILD=1"
  shift
  goto parse_args
)
if /i "%~1"=="--no-run" (
  set "R4Y_NO_RUN=1"
  shift
  goto parse_args
)
if /i "%~1"=="--yes" (
  set "R4Y_YES=1"
  shift
  goto parse_args
)
if /i "%~1"=="--test" (
  set "R4Y_TEST=1"
  shift
  goto parse_args
)
if /i "%~1"=="--channel" (
  set "R4Y_CHANNEL=%~2"
  shift
  shift
  goto parse_args
)
if /i "%~1"=="--help" goto help
if /i "%~1"=="-h" goto help
echo Opcao desconhecida: %~1
echo Rode r4y.cmd --help para ver o uso.
goto bad_args
:help
echo R4Y - Recompile4You: instalacao rapida / atualizacao / build
echo.
echo Uso: r4y.cmd [opcoes]
echo.
echo   --dry-run   Mostra o que falta. Nao altera nada.
echo   --no-build  Prepara tudo e grava a configuracao, mas nao compila.
echo   --no-run    Compila e checa, mas nao pergunta se quer iniciar.
echo   --yes       Nao pede confirmacao para instalar pacotes.
echo   --test      Roda tambem cargo test --workspace.
echo   --channel   upstream (padrao) ou fork.
echo   --help      Mostra esta ajuda.
exit /b 0
:bad_args
echo.
pause
exit /b 2
:args_done
for /f "tokens=2 delims=:" %%A in ('%SystemRoot%\System32\chcp.com') do set "OLD_CP=%%A"
set "OLD_CP=%OLD_CP: =%"
%SystemRoot%\System32\chcp.com 65001 >nul
title R4Y - Recompile4You
set "SELF=%~f0"
set "PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if not exist "%PS%" set "PS=powershell.exe"
@"%PS%" -NoLogo -NoProfile -ExecutionPolicy Bypass -Command "$ErrorActionPreference='Stop'; $tmp=$null; try { $raw=[IO.File]::ReadAllText($env:SELF,[Text.Encoding]::UTF8); $marker=':__POWERSHELL_PAYLOAD__'; $pos=$raw.LastIndexOf($marker,[StringComparison]::Ordinal); if($pos -lt 0){throw 'Payload PowerShell ausente.'}; $line=$raw.IndexOf([char]10,$pos); if($line -lt 0){throw 'Payload PowerShell incompleto.'}; $payload=$raw.Substring($line+1); $tmp=Join-Path ([IO.Path]::GetTempPath()) ('R4Y_'+[guid]::NewGuid().ToString('N')+'.ps1'); $fs=[IO.File]::Open($tmp,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None); try { $bytes=(New-Object System.Text.UTF8Encoding($true)).GetBytes($payload); $fs.Write($bytes,0,$bytes.Length) } finally { $fs.Dispose() }; & $tmp; if($null -eq $global:R4Y_BOOTSTRAP_EXIT){throw 'O instalador nao informou um codigo de saida.'}; $rc=[int]$global:R4Y_BOOTSTRAP_EXIT } catch { Write-Host $_.Exception.Message -ForegroundColor Red; $rc=1 } finally { if($tmp -and (Test-Path -LiteralPath $tmp)){Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue} }; exit $rc"
set "RC=%ERRORLEVEL%"
if defined OLD_CP %SystemRoot%\System32\chcp.com %OLD_CP% >nul
echo.
if "%RC%"=="0" (
  echo ============================================================
  echo R4Y: CONCLUIDO
  echo ============================================================
) else (
  echo ============================================================
  echo R4Y: FALHOU
  echo Veja r4y.log nesta pasta.
  echo ============================================================
)
echo(
echo Pressione qualquer tecla para fechar.
pause >nul
exit /b %RC%
:__POWERSHELL_PAYLOAD__
#Requires -Version 5.1
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$script:Root      = Split-Path -Parent $env:SELF
$script:SrcDir    = Join-Path $script:Root 'src\r4y-core'
$script:BinDir    = Join-Path $script:Root 'bin'
$script:CfgDir    = Join-Path $script:Root 'config'
$script:PatchDir  = Join-Path $script:Root 'patches'
$script:TargetDir = Join-Path $script:Root 'build\target'
$script:LogPath   = Join-Path $script:Root 'r4y.log'
$script:StatePath = Join-Path $script:CfgDir 'r4y-state.json'
$script:TomlPath  = Join-Path $script:CfgDir 'r4y.toml'
$script:RunCmd    = Join-Path $script:Root 'r4y-run.cmd'
$script:Channel   = $env:R4Y_CHANNEL
$script:DryRun    = ($env:R4Y_DRY_RUN -eq '1')
$script:NoBuild   = ($env:R4Y_NO_BUILD -eq '1')
$script:NoRun     = ($env:R4Y_NO_RUN -eq '1')
$script:AssumeYes = ($env:R4Y_YES -eq '1')
$script:RunTests  = ($env:R4Y_TEST -eq '1')
$script:Channels  = @{
    'upstream' = 'https://github.com/Marvisak/VIctory.git'
    'fork'     = 'https://github.com/fxceless/victory-gta6.git'
}
$script:Winget = $null
$script:GitExe = $null
$script:CargoExe = $null
$script:RebootNeeded = $false
$global:R4Y_BOOTSTRAP_EXIT = 1

function Write-Step([string]$m) { Write-Host ''; Write-Host ('==> ' + $m) -ForegroundColor Cyan }
function Write-Ok([string]$m)   { Write-Host ('[ok] ' + $m) -ForegroundColor Green }
function Write-Warn([string]$m) { Write-Host ('[aviso] ' + $m) -ForegroundColor Yellow }
function Write-Info([string]$m) { Write-Host ('     ' + $m) -ForegroundColor Gray }

function Show-Banner {
    Write-Host ''
    Write-Host '  R4Y  |  Recompile4You' -ForegroundColor Magenta
    Write-Host '  instalacao rapida  |  atualizacao  |  build incremental' -ForegroundColor DarkGray
    Write-Host ('  canal: ' + $script:Channel) -ForegroundColor DarkGray
}

function Refresh-Environment {
    $machine = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $user = [Environment]::GetEnvironmentVariable('Path', 'User')
    $env:Path = ($machine + ';' + $user)
    $cargoBin = Join-Path $env:USERPROFILE '.cargo\bin'
    if (Test-Path -LiteralPath $cargoBin) { $env:Path = $env:Path + ';' + $cargoBin }
}

function Get-ToolPath([string]$name, [string[]]$extra) {
    $c = Get-Command $name -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($c -and $c.Source) { return $c.Source }
    foreach ($e in $extra) {
        if ($e -and (Test-Path -LiteralPath $e -PathType Leaf)) { return $e }
    }
    return $null
}

function Get-MsvcRoot {
    $vw = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
    if (-not (Test-Path -LiteralPath $vw)) { return $null }
    $p = & $vw -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath 2>$null
    if ($p) { return ($p | Select-Object -First 1) }
    return $null
}

function Test-WindowsSdk {
    $lib = Join-Path ${env:ProgramFiles(x86)} 'Windows Kits\10\Lib'
    if (-not (Test-Path -LiteralPath $lib)) { return $false }
    $hit = Get-ChildItem -LiteralPath $lib -Directory -ErrorAction SilentlyContinue |
        Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'um\x64\kernel32.lib') } |
        Select-Object -First 1
    return [bool]$hit
}

function Test-Avx2 {
    try {
        Add-Type -Namespace R4Y -Name Native -MemberDefinition '[DllImport("kernel32.dll")] public static extern bool IsProcessorFeaturePresent(int feature);' -ErrorAction Stop
    } catch {}
    try { return [bool][R4Y.Native]::IsProcessorFeaturePresent(40) } catch { return $null }
}

function Confirm-Action([string]$question) {
    if ($script:AssumeYes) { return $true }
    if ([Console]::IsInputRedirected) { return $false }
    $a = Read-Host ($question + ' [S/n]')
    return (-not $a -or $a -match '^(?i:s|sim|y|yes)$')
}

function Invoke-Native([string]$exe, [string[]]$arguments, [string]$workDir) {
    $old = Get-Location
    try {
        if ($workDir) { Set-Location -LiteralPath $workDir }
        & $exe @arguments | Out-Host
        return $LASTEXITCODE
    } finally { Set-Location $old }
}

function Get-WantedPackages {
    $list = @()
    if (-not $script:GitExe) {
        $list += [pscustomobject]@{ Name = 'Git'; Id = 'Git.Git'; Override = $null }
    }
    if (-not $script:CargoExe) {
        $list += [pscustomobject]@{ Name = 'Rustup (Rust)'; Id = 'Rustlang.Rustup'; Override = $null }
    }
    if (-not (Get-MsvcRoot)) {
        $list += [pscustomobject]@{
            Name = 'Visual Studio 2022 Build Tools (C++ e Windows SDK)'
            Id = 'Microsoft.VisualStudio.2022.BuildTools'
            Override = '--passive --wait --norestart --add Microsoft.VisualStudio.Workload.VCTools --add Microsoft.VisualStudio.Component.Windows11SDK.26100 --includeRecommended'
        }
    } elseif (-not (Test-WindowsSdk)) {
        Write-Warn 'Visual Studio C++ encontrado, mas sem Windows SDK. Instale o componente "Windows 11 SDK" pelo Visual Studio Installer.'
    }
    return $list
}

function Resolve-Tools {
    Refresh-Environment
    $script:GitExe = Get-ToolPath 'git.exe' @((Join-Path $env:ProgramFiles 'Git\cmd\git.exe'))
    $script:CargoExe = Get-ToolPath 'cargo.exe' @((Join-Path $env:USERPROFILE '.cargo\bin\cargo.exe'))
    $script:Winget = Get-ToolPath 'winget.exe' @()
}

function Show-Hardware {
    $os = Get-CimInstance Win32_OperatingSystem
    $ramGb = [math]::Round($os.TotalVisibleMemorySize / 1MB, 1)
    $commitGb = [math]::Round($os.TotalVirtualMemorySize / 1MB, 1)
    Write-Info ('Windows: ' + $os.Caption)
    Write-Info ('RAM: ' + $ramGb + ' GiB | limite de commit: ' + $commitGb + ' GiB')
    foreach ($g in @(Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue)) {
        Write-Info ('GPU: ' + $g.Name)
    }
    $avx = Test-Avx2
    if ($avx -eq $true) { Write-Ok 'CPU com AVX2.' }
    elseif ($avx -eq $false) { throw 'Esta CPU nao tem AVX2, que o nucleo exige.' }
    else { Write-Warn 'Nao foi possivel verificar AVX2.' }
    if ($commitGb -lt 32) {
        Write-Warn 'Limite de commit abaixo de 32 GiB. O jogo pode precisar de 24 GiB ou mais em uso; aumente o arquivo de paginacao se aparecer o erro 1455 em crashes.log.'
    }
    Write-Info 'A GPU precisa de Direct3D 12 com Shader Model 6.6 (e mesh shaders para o mundo). Isso nao e verificado aqui.'
}

function Install-Packages($packages) {
    if (-not $script:Winget) {
        throw 'winget nao foi encontrado. Instale o "App Installer" pela Microsoft Store ou instale manualmente: Git, Rustup e Visual Studio 2022 Build Tools (C++ e Windows SDK).'
    }
    foreach ($p in $packages) {
        Write-Info ('Instalando ' + $p.Name + '...')
        $wargs = @('install', '--id', $p.Id, '-e', '--source', 'winget', '--accept-package-agreements', '--accept-source-agreements')
        if ($p.Override) { $wargs += @('--override', $p.Override) }
        & $script:Winget @wargs | Out-Host
        if ($LASTEXITCODE -eq 3010) { $script:RebootNeeded = $true }
    }
    Resolve-Tools
}

function Update-Source {
    $url = $script:Channels[$script:Channel]
    if (-not (Test-Path -LiteralPath (Join-Path $script:SrcDir '.git'))) {
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $script:SrcDir) | Out-Null
        Write-Info ('Clonando ' + $url)
        $rc = Invoke-Native $script:GitExe @('clone', '--depth', '1', $url, $script:SrcDir) $null
        if ($rc -ne 0) { throw ('git clone falhou (codigo ' + $rc + ').') }
    } else {
        $origin = (& $script:GitExe -C $script:SrcDir remote get-url origin | Out-String).Trim()
        if ($origin -ne $url) {
            Write-Warn ('Trocando a origem do nucleo para ' + $url)
            $rc = Invoke-Native $script:GitExe @('-C', $script:SrcDir, 'remote', 'set-url', 'origin', $url) $null
            if ($rc -ne 0) { throw 'Nao foi possivel trocar a origem do nucleo.' }
        }
        $rc = Invoke-Native $script:GitExe @('-C', $script:SrcDir, 'fetch', '--depth', '1', 'origin', 'HEAD') $null
        if ($rc -ne 0) { throw ('git fetch falhou (codigo ' + $rc + '). O nucleo local foi mantido.') }
        $rc = Invoke-Native $script:GitExe @('-C', $script:SrcDir, 'reset', '--hard', 'FETCH_HEAD') $null
        if ($rc -ne 0) { throw 'git reset falhou.' }
    }
    $head = (& $script:GitExe -C $script:SrcDir rev-parse --short=12 HEAD | Out-String).Trim()
    Write-Ok ('Nucleo pronto em ' + $head + '.')
}

function Apply-Patches {
    if (-not (Test-Path -LiteralPath $script:PatchDir)) { return }
    $patches = @(Get-ChildItem -LiteralPath $script:PatchDir -Filter '*.patch' -File | Sort-Object Name)
    if ($patches.Count -eq 0) { Write-Info 'Nenhum patch em patches\.'; return }
    foreach ($p in $patches) {
        $chk = Invoke-Native $script:GitExe @('-C', $script:SrcDir, 'apply', '--check', $p.FullName) $null
        if ($chk -eq 0) {
            $ap = Invoke-Native $script:GitExe @('-C', $script:SrcDir, 'apply', $p.FullName) $null
            if ($ap -eq 0) { Write-Ok ('Patch aplicado: ' + $p.Name) } else { Write-Warn ('Falha ao aplicar: ' + $p.Name) }
        } else {
            Write-Warn ('Patch ignorado (nao aplica nesta versao do nucleo): ' + $p.Name)
        }
    }
}

function Load-State {
    if (Test-Path -LiteralPath $script:StatePath) {
        try { return (Get-Content -LiteralPath $script:StatePath -Raw | ConvertFrom-Json) } catch {}
    }
    return $null
}

function Save-State([string]$gameDir, [string]$exe) {
    New-Item -ItemType Directory -Force -Path $script:CfgDir | Out-Null
    ([pscustomobject]@{ game_dir = $gameDir; exe = $exe; channel = $script:Channel }) |
        ConvertTo-Json | Set-Content -LiteralPath $script:StatePath -Encoding UTF8
}

function Pick-Folder([string]$description) {
    try {
        Add-Type -AssemblyName System.Windows.Forms
        $d = New-Object System.Windows.Forms.FolderBrowserDialog
        $d.Description = $description
        if ($d.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { return $d.SelectedPath }
    } catch {}
    return $null
}

function Pick-File([string]$initialDir) {
    try {
        Add-Type -AssemblyName System.Windows.Forms
        $d = New-Object System.Windows.Forms.OpenFileDialog
        $d.Filter = 'Executavel (*.exe)|*.exe'
        if ($initialDir -and (Test-Path -LiteralPath $initialDir)) { $d.InitialDirectory = $initialDir }
        if ($d.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { return $d.FileName }
    } catch {}
    return $null
}

function Select-Game {
    $state = Load-State
    if ($state -and $state.game_dir -and $state.exe -and
        (Test-Path -LiteralPath $state.game_dir -PathType Container) -and
        (Test-Path -LiteralPath $state.exe -PathType Leaf)) {
        Write-Host ''
        Write-Host ('Ultima escolha: ' + $state.exe) -ForegroundColor White
        if ([Console]::IsInputRedirected) { return @($state.game_dir, $state.exe) }
        $a = Read-Host 'Usar de novo? [S/n]'
        if (-not $a -or $a -match '^(?i:s|sim|y|yes)$') { return @($state.game_dir, $state.exe) }
    }
    if ([Console]::IsInputRedirected) { throw 'Nenhum jogo configurado e a entrada nao e interativa. Rode r4y.cmd em uma janela normal.' }

    Write-Host ''
    Write-Host 'Pasta do jogo que voce quer rodar (a que tem os arquivos do seu jogo ja legiveis em disco).' -ForegroundColor White
    $typed = Read-Host 'Digite o caminho ou aperte ENTER para abrir o seletor'
    if ($typed) { $gameDir = $typed.Trim().Trim('"') } else { $gameDir = Pick-Folder 'Escolha a pasta do jogo' }
    if (-not $gameDir -or -not (Test-Path -LiteralPath $gameDir -PathType Container)) { throw 'Pasta do jogo invalida ou nao escolhida.' }
    $gameDir = (Resolve-Path -LiteralPath $gameDir).ProviderPath

    $srcFull = [IO.Path]::GetFullPath($script:SrcDir).TrimEnd('\') + '\'
    $gameFull = [IO.Path]::GetFullPath($gameDir).TrimEnd('\') + '\'
    if ($gameFull.StartsWith($srcFull, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'A pasta do jogo nao pode ficar dentro de src\r4y-core (o nucleo recusa caminhos dentro do repositorio).'
    }
    $cfgFile = Get-ChildItem -LiteralPath $gameDir -Filter 'MicrosoftGame.config' -File -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $cfgFile) { Write-Warn 'MicrosoftGame.config nao esta no topo dessa pasta. Confira se e a pasta certa.' }

    $found = @(Get-ChildItem -LiteralPath $gameDir -Filter '*.exe' -File -Recurse -Depth 2 -ErrorAction SilentlyContinue | Select-Object -First 30)
    $exe = $null
    if ($found.Count -eq 1) {
        $exe = $found[0].FullName
        Write-Info ('Executavel encontrado: ' + $exe)
    } elseif ($found.Count -gt 1) {
        Write-Host 'Executaveis encontrados:' -ForegroundColor White
        for ($i = 0; $i -lt $found.Count; $i++) {
            Write-Host ('  [' + ($i + 1) + '] ' + $found[$i].FullName.Substring($gameDir.Length).TrimStart('\'))
        }
        $n = Read-Host 'Numero do executavel (ENTER abre o seletor)'
        if ($n -match '^\d+$' -and [int]$n -ge 1 -and [int]$n -le $found.Count) { $exe = $found[[int]$n - 1].FullName }
        else { $exe = Pick-File $gameDir }
    } else {
        $exe = Pick-File $gameDir
    }
    if (-not $exe -or -not (Test-Path -LiteralPath $exe -PathType Leaf)) { throw 'Executavel invalido ou nao escolhido.' }
    Save-State $gameDir $exe
    return @($gameDir, $exe)
}

function ConvertTo-TomlString([string]$s) {
    if ($s.Contains("'")) { return '"' + $s.Replace('\', '\\').Replace('"', '\"') + '"' }
    return "'" + $s + "'"
}

function Write-Config([string]$gameDir) {
    New-Item -ItemType Directory -Force -Path $script:CfgDir | Out-Null
    $lines = @(
        '# Gerado pelo r4y.cmd. Rode r4y.cmd de novo para trocar de jogo.',
        '[paths]',
        ('game_dir = ' + (ConvertTo-TomlString $gameDir)),
        'test_titles = []'
    )
    [IO.File]::WriteAllLines($script:TomlPath, $lines, (New-Object System.Text.UTF8Encoding($false)))
    Write-Ok ('Configuracao gravada em ' + $script:TomlPath)
}

function Build-Core {
    $env:CARGO_TARGET_DIR = $script:TargetDir
    Write-Info 'Preparando o toolchain Rust que o repositorio fixa (na primeira vez baixa componentes)...'
    $rc = Invoke-Native $script:CargoExe @('--version') $script:SrcDir
    if ($rc -ne 0) { throw 'cargo nao conseguiu preparar o toolchain.' }
    if ($script:RunTests) {
        Write-Info 'Rodando cargo test --workspace (nao usa dados do jogo)...'
        $rc = Invoke-Native $script:CargoExe @('test', '--workspace') $script:SrcDir
        if ($rc -ne 0) { throw ('Testes falharam (codigo ' + $rc + ').') }
    }
    Write-Info 'Compilando em release (pode demorar bastante na primeira vez)...'
    $rc = Invoke-Native $script:CargoExe @('build', '--release', '-p', 'victory') $script:SrcDir
    if ($rc -ne 0) { throw ('cargo build falhou (codigo ' + $rc + ').') }
    $built = Join-Path $script:TargetDir 'release\victory.exe'
    if (-not (Test-Path -LiteralPath $built -PathType Leaf)) { throw ('Binario nao encontrado em ' + $built) }
    New-Item -ItemType Directory -Force -Path $script:BinDir | Out-Null
    Copy-Item -LiteralPath $built -Destination (Join-Path $script:BinDir 'r4y.exe') -Force
    Write-Ok ('Binario: ' + (Join-Path $script:BinDir 'r4y.exe'))
}

function Check-Setup([string]$exePath) {
    $r4y = Join-Path $script:BinDir 'r4y.exe'
    $env:VICTORY_CONFIG = $script:TomlPath
    $rc = Invoke-Native $r4y @('config') $script:SrcDir
    if ($rc -ne 0) { throw 'A checagem da configuracao falhou. Veja as mensagens acima e config\r4y.toml.' }
    Write-Ok 'Configuracao aceita pelo nucleo.'
    $rc = Invoke-Native $r4y @('inspect', $exePath) $script:SrcDir
    if ($rc -ne 0) { Write-Warn 'O nucleo nao conseguiu inspecionar esse executavel. Confira se e o executavel do jogo.' }
    else { Write-Ok 'Executavel inspecionado.' }
}

function Write-Launcher([string]$exePath) {
    $r4y = Join-Path $script:BinDir 'r4y.exe'
    $lines = @(
        '@echo off',
        'chcp 65001 >nul',
        'rem Gerado por r4y.cmd. Rode r4y.cmd de novo para trocar de jogo.',
        'if defined R4Y_LOG set "VICTORY_LOG=%R4Y_LOG%"',
        'if defined R4Y_D3D12_DEBUG set "VICTORY_D3D12_DEBUG=%R4Y_D3D12_DEBUG%"',
        'if defined R4Y_D3D12_WARP set "VICTORY_D3D12_WARP=%R4Y_D3D12_WARP%"',
        ('set "VICTORY_CONFIG=' + $script:TomlPath + '"'),
        ('cd /d "' + $script:SrcDir + '"'),
        ('"' + $r4y + '" run "' + $exePath + '" --execute %*'),
        'echo.',
        'pause'
    )
    [IO.File]::WriteAllLines($script:RunCmd, $lines, (New-Object System.Text.UTF8Encoding($false)))
    Write-Ok ('Launcher: ' + $script:RunCmd)
}

$exitCode = 0
$transcript = $false
try {
    try { Start-Transcript -Path $script:LogPath -Force | Out-Null; $transcript = $true } catch {}
    Show-Banner
    if (-not $script:Channels.ContainsKey($script:Channel)) {
        throw ('Canal invalido: "' + $script:Channel + '". Use upstream ou fork.')
    }

    Write-Step '1/7  Verificando Windows, hardware e pre-requisitos'
    if (-not [Environment]::Is64BitOperatingSystem) { throw 'O R4Y exige Windows 10 ou 11 de 64 bits.' }
    $osCaption = (Get-CimInstance Win32_OperatingSystem).Caption
    if ($osCaption -notmatch 'Windows 10|Windows 11') { throw ('Sistema nao suportado: ' + $osCaption) }
    Show-Hardware
    Resolve-Tools
    $packages = @(Get-WantedPackages)
    if ($packages.Count -eq 0) { Write-Ok 'Git, Rust e Visual Studio C++ ja estao instalados.' }
    else { foreach ($p in $packages) { Write-Warn ('Falta: ' + $p.Name) } }

    if ($script:DryRun) {
        Write-Ok 'Dry run concluido. Nada foi instalado, baixado nem alterado.'
    } else {
        if ($packages.Count -gt 0) {
            Write-Step '2/7  Instalando o que falta'
            if (-not (Confirm-Action 'Instalar os pacotes acima com o winget?')) {
                throw 'Instalacao recusada (ou entrada nao interativa sem --yes).'
            }
            Install-Packages $packages
        } else {
            Write-Step '2/7  Pre-requisitos ja instalados'
        }

        if ($script:RebootNeeded) {
            Write-Warn 'Um pacote pediu reinicio do Windows. Reinicie e rode r4y.cmd de novo: o que falta sera detectado.'
        } else {
            if (-not $script:GitExe) { throw 'Git continua indisponivel apos a instalacao.' }
            if (-not $script:CargoExe) { throw 'Cargo continua indisponivel apos a instalacao. Abra um novo terminal e rode de novo.' }
            if (-not (Get-MsvcRoot)) { throw 'Visual Studio Build Tools (C++) continua indisponivel apos a instalacao.' }

            Write-Step '3/7  Baixando/atualizando o nucleo e aplicando patches'
            Update-Source
            Apply-Patches

            Write-Step '4/7  Escolhendo o jogo'
            $sel = Select-Game
            $gameDir = $sel[0]
            $exePath = $sel[1]
            Write-Ok ('Jogo: ' + $gameDir)
            Write-Ok ('Executavel: ' + $exePath)

            Write-Step '5/7  Configurando e compilando'
            Write-Config $gameDir
            if ($script:NoBuild) {
                Write-Ok 'Preparacao concluida. Compilacao ignorada (--no-build).'
            } else {
                Build-Core

                Write-Step '6/7  Checando'
                Check-Setup $exePath

                Write-Step '7/7  Launcher'
                Write-Launcher $exePath
                if (-not $script:NoRun -and -not [Console]::IsInputRedirected) {
                    if (Confirm-Action 'Iniciar o jogo agora?') {
                        if ($transcript) { try { Stop-Transcript | Out-Null } catch {}; $transcript = $false }
                        $env:VICTORY_CONFIG = $script:TomlPath
                        Write-Info 'Iniciando. Se a GPU travar e os monitores ficarem pretos por um instante, e o driver sendo reiniciado (veja README, Aviso).'
                        $rc = Invoke-Native (Join-Path $script:BinDir 'r4y.exe') @('run', $exePath, '--execute') $script:SrcDir
                        if ($rc -ne 0) { Write-Warn ('O jogo terminou com codigo ' + $rc + '. Veja crashes.log em %LOCALAPPDATA%\victory\data.') }
                    } else {
                        Write-Ok 'Pronto. Para iniciar depois, use r4y-run.cmd.'
                    }
                } else {
                    Write-Ok 'Pronto. Para iniciar, use r4y-run.cmd.'
                }
            }
        }
    }
} catch {
    $exitCode = 1
    Write-Host ''
    Write-Host 'R4Y FALHOU' -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Red
    Write-Host ('Log: ' + $script:LogPath) -ForegroundColor Yellow
} finally {
    if ($transcript) { try { Stop-Transcript | Out-Null } catch {} }
}

$global:R4Y_BOOTSTRAP_EXIT = $exitCode
