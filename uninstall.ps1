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

Write-Host ""
Write-Ok "Uninstall complete."
Write-Host "  If you mounted a different host directory for HF_HOME, remove that directory manually." -ForegroundColor White
