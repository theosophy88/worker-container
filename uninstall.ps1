#Requires -Version 5.1
# =============================================================================
#  EMBEDDING WORKER — Windows Uninstaller
#  Stops the worker, removes the Docker stack, image, and generated .env.
# =============================================================================

param(
    [switch]$Force
)

$currentPrincipal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host ""
    Write-Host "  [!] This script must be run as Administrator." -ForegroundColor Red
    Write-Host "      Right-click PowerShell → 'Run as administrator'" -ForegroundColor Yellow
    Write-Host "      Then run:  Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass" -ForegroundColor Yellow
    Write-Host "                 .\uninstall.ps1" -ForegroundColor Yellow
    Write-Host ""
    pause; exit 1
}

function Write-Header($text) {
    Write-Host ""
    Write-Host "  ══════════════════════════════════════════════" -ForegroundColor Blue
    Write-Host "    $text" -ForegroundColor Blue
    Write-Host "  ══════════════════════════════════════════════" -ForegroundColor Blue
}
function Write-Ok($text)   { Write-Host "  ✓  $text" -ForegroundColor Green  }
function Write-Warn($text) { Write-Host "  ⚠  $text" -ForegroundColor Yellow }
function Write-Err($text)  { Write-Host "  ✗  $text" -ForegroundColor Red    }
function Write-Info($text) { Write-Host "  →  $text" -ForegroundColor Cyan   }

function PromptYN($prompt, $default = "y") {
    while ($true) {
        Write-Host -NoNewline "  $prompt [y/n, default=$default]: " -ForegroundColor White
        $val = Read-Host
        if ($val -eq "") { $val = $default }
        if ($val -match "^[Yy]") { return $true }
        if ($val -match "^[Nn]") { return $false }
        Write-Warn "Enter y or n"
    }
}

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $ScriptDir

Write-Header "Embedding Worker Uninstaller"
Write-Host "  This will stop the worker container, remove the image, and delete generated files." -ForegroundColor White
Write-Host "  It does not uninstall Docker Desktop or remove this repository." -ForegroundColor White
Write-Host ""

if (-not $Force) {
    $confirmed = PromptYN "Continue with uninstall?" "n"
    if (-not $confirmed) {
        Write-Host "  Uninstall cancelled." -ForegroundColor Yellow
        exit 0
    }
}

$dockerCmd = Get-Command docker -ErrorAction SilentlyContinue
if (-not $dockerCmd) {
    Write-Err "Docker is not installed or not available in PATH. Cannot uninstall Docker resources."
    exit 1
}

$composeArgs = @("-f", "docker-compose.yml")
if (Test-Path "docker-compose.nvidia.yml") {
    $composeArgs += @("-f", "docker-compose.nvidia.yml")
}
if (Test-Path "docker-compose.amd.yml") {
    $composeArgs += @("-f", "docker-compose.amd.yml")
}

Write-Info "Stopping Docker compose stack..."
& docker compose @composeArgs down --rmi all --volumes 2>$null
if ($LASTEXITCODE -eq 0) {
    Write-Ok "Compose stack stopped and removed."
} else {
    Write-Warn "docker compose down failed or no stack was running."
}

Write-Info "Stopping any remaining embedding-worker containers..."
$containerIds = & docker ps -aq --filter "name=embedding-worker" 2>$null
$containerIds += & docker ps -aq --filter "ancestor=embedding-worker:latest" 2>$null
$containerIds = $containerIds | Where-Object { $_ -ne "" } | Sort-Object -Unique
if ($containerIds) {
    & docker rm -f $containerIds 2>$null
    if ($LASTEXITCODE -eq 0) {
        Write-Ok "Stopped and removed remaining embedding-worker containers."
    } else {
        Write-Warn "Failed to remove some embedding-worker containers."
    }
} else {
    Write-Info "No remaining embedding-worker containers found."
}

Write-Info "Removing Docker image embedding-worker:latest..."
& docker image rm -f embedding-worker:latest 2>$null
if ($LASTEXITCODE -eq 0) {
    Write-Ok "Docker image removed."
} else {
    Write-Warn "Docker image not found or could not be removed."
}

if (Test-Path ".env") {
    Remove-Item ".env" -Force -ErrorAction SilentlyContinue
    Write-Ok ".env removed."
} else {
    Write-Info ".env not found."
}

if (PromptYN "Also attempt to remove host-mounted model cache at /home/model if present?" "n") {
    try {
        if (Test-Path "/home/model") {
            Remove-Item "/home/model" -Recurse -Force -ErrorAction Stop
            Write-Ok "Host model cache removed from /home/model."
        } else {
            Write-Warn "/home/model not found or not accessible from this shell."
        }
    } catch {
        Write-Warn "Failed to remove /home/model: $_"
    }
}

if (PromptYN "Also remove the installation directory at $ScriptDir?" "n") {
    try {
        $parentDir = Split-Path -Parent $ScriptDir
        Set-Location $parentDir
        Remove-Item $ScriptDir -Recurse -Force -ErrorAction Stop
        Write-Ok "Installation directory removed: $ScriptDir"
    } catch {
        Write-Warn "Failed to remove installation directory: $_"
    }
}

Write-Host ""
Write-Ok "Uninstall complete."
Write-Host "  If you mounted a different host directory for HF_HOME, remove that directory manually." -ForegroundColor White
