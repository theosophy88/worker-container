#Requires -Version 5.1
# =============================================================================
#  EMBEDDING WORKER — Windows Installer
#  Installs Docker Desktop, configures the embedding worker,
#  and handles network issues (DHCP / static IP).
#
#  Run in PowerShell as Administrator:
#    Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
#    .\install.ps1
# =============================================================================

param(
    [switch]$Reconfigure,      # skip Docker install, re-run config only
    [switch]$Raw               # print raw install instructions and exit
)

# ── Admin check ───────────────────────────────────────────────────────────────
$currentPrincipal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host ""
    Write-Host "  [!] This script must be run as Administrator." -ForegroundColor Red
    Write-Host "      Right-click PowerShell → 'Run as administrator'" -ForegroundColor Yellow
    Write-Host "      Then run:  Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass" -ForegroundColor Yellow
    Write-Host "                 .\install.ps1" -ForegroundColor Yellow
    Write-Host ""
    pause; exit 1
}

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

# ── Helpers ───────────────────────────────────────────────────────────────────
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

function Prompt-Input($prompt, $default = "") {
    if ($default -ne "") { Write-Host -NoNewline "  $prompt [$default]: " -ForegroundColor White }
    else                 { Write-Host -NoNewline "  ${prompt}: "           -ForegroundColor White }
    $val = Read-Host
    if ($val -eq "" -and $default -ne "") { return $default }
    return $val
}

function Prompt-YN($prompt, $default = "y") {
    while ($true) {
        Write-Host -NoNewline "  $prompt [y/n, default=$default]: " -ForegroundColor White
        $val = Read-Host
        if ($val -eq "") { $val = $default }
        if ($val -match "^[Yy]") { return $true  }
        if ($val -match "^[Nn]") { return $false }
        Write-Warn "Enter y or n"
    }
}

function Get-TotalPhysicalMemoryGB {
    try {
        $bytes = (Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory
        return [math]::Round($bytes / 1GB, 1)
    } catch {
        return 0
    }
}

function Get-QualifiedGpuAdapters {
    try {
        Get-CimInstance Win32_VideoController | Where-Object {
            $_.AdapterRAM -ge (16 * 1024 * 1024 * 1024)
        } | Select-Object Name, @{Name='MemoryGB';Expression={[math]::Round($_.AdapterRAM / 1GB, 1)}}
    } catch {
        @()
    }
}

# ── --Raw: print manual instructions ─────────────────────────────────────────
if ($Raw) {
    Write-Host @"

==========================================================================
  RAW WINDOWS DOCKER INSTALL INSTRUCTIONS
==========================================================================

Option A — via winget (Windows 10/11, recommended):
  winget install Docker.DockerDesktop

Option B — via Chocolatey:
  # Install Chocolatey first if not installed:
  Set-ExecutionPolicy Bypass -Scope Process -Force
  [System.Net.ServicePointManager]::SecurityProtocol = 3072
  iex ((New-Object Net.WebClient).DownloadString('https://chocolatey.org/install.ps1'))
  # Then:
  choco install docker-desktop -y

Option C — manual download:
  https://desktop.docker.com/win/main/amd64/Docker%20Desktop%20Installer.exe

After install:
  1. Start Docker Desktop (from Start menu)
  2. Wait for Docker to fully start (whale icon in taskbar = stable)
  3. Open PowerShell in the embedding_worker folder
  4. Copy .env.example to .env, fill in your settings
  5. Run: docker compose build
  6. Run: docker compose up -d
  7. Run: docker logs -f embedding-worker

CPU management on Windows:
  The manage.sh script requires WSL2 or Git Bash.
  Alternatively use: docker update --cpus=4 embedding-worker
  (run in PowerShell or Command Prompt)
==========================================================================
"@
    exit 0
}

# ── Banner ─────────────────────────────────────────────────────────────────────
Clear-Host
Write-Host ""
Write-Host "  ╔════════════════════════════════════════════════════════╗" -ForegroundColor Blue
Write-Host "  ║     EMBEDDING WORKER — Windows Installer               ║" -ForegroundColor Blue
Write-Host "  ║     HuggingFace · sentence-transformers                ║" -ForegroundColor Blue
Write-Host "  ║     Qwen/Qwen3-Embedding-8B  |  float16-only           ║" -ForegroundColor Blue
Write-Host "  ╚════════════════════════════════════════════════════════╝" -ForegroundColor Blue
Write-Host ""

# ── Network check ─────────────────────────────────────────────────────────────
Write-Header "Network Check"

$internetOk = $false
foreach ($host in @("8.8.8.8", "1.1.1.1", "9.9.9.9")) {
    if (Test-Connection -ComputerName $host -Count 1 -Quiet -ErrorAction SilentlyContinue) {
        $internetOk = $true; break
    }
}

if ($internetOk) {
    Write-Ok "Internet reachable"
    # DNS check
    try {
        [System.Net.Dns]::GetHostAddresses("download.docker.com") | Out-Null
        Write-Ok "DNS resolution: OK"
    } catch {
        Write-Warn "DNS failing — adding Google DNS..."
        # Set DNS on all active adapters
        $adapters = Get-NetAdapter | Where-Object { $_.Status -eq "Up" }
        foreach ($a in $adapters) {
            Set-DnsClientServerAddress -InterfaceAlias $a.Name `
                -ServerAddresses "8.8.8.8","8.8.4.4" -ErrorAction SilentlyContinue
        }
        Write-Ok "Google/Cloudflare DNS configured"
    }
} else {
    Write-Warn "No internet connectivity detected!"
    Write-Host ""

    # List active interfaces
    $adapters = Get-NetAdapter | Where-Object { $_.Status -eq "Up" -or $_.Status -eq "Disconnected" }
    if ($adapters.Count -eq 0) {
        Write-Err "No network adapters found. Check hardware/drivers."
        exit 1
    }

    Write-Host "  Available network adapters:" -ForegroundColor White
    Write-Host ""
    for ($i = 0; $i -lt $adapters.Count; $i++) {
        $a = $adapters[$i]
        $ip = (Get-NetIPAddress -InterfaceAlias $a.Name -AddressFamily IPv4 `
            -ErrorAction SilentlyContinue | Select-Object -First 1).IPAddress
        if (-not $ip) { $ip = "none" }
        Write-Host ("    [{0}]  {1,-25}  Status:{2,-12}  IP:{3}" -f `
            ($i+1), $a.Name, $a.Status, $ip) -ForegroundColor Gray
    }

    Write-Host ""
    $sel = Prompt-Input "Select adapter number" "1"
    $selIdx = [int]$sel - 1
    if ($selIdx -lt 0 -or $selIdx -ge $adapters.Count) {
        Write-Err "Invalid selection"; exit 1
    }
    $selectedAdapter = $adapters[$selIdx].Name

    Write-Host ""
    Write-Host "  Configure ${selectedAdapter} as:" -ForegroundColor White
    Write-Host "    [1]  DHCP   — automatic (recommended)"
    Write-Host "    [2]  Static — manual IP, gateway, DNS"
    $netMode = Prompt-Input "Choice" "1"

    if ($netMode -eq "1") {
        # DHCP
        Write-Info "Setting $selectedAdapter to DHCP..."
        Set-NetIPInterface -InterfaceAlias $selectedAdapter -Dhcp Enabled `
            -ErrorAction SilentlyContinue
        Set-DnsClientServerAddress -InterfaceAlias $selectedAdapter `
            -ResetServerAddresses -ErrorAction SilentlyContinue
        # Force interface to re-acquire
        Disable-NetAdapter -Name $selectedAdapter -Confirm:$false -ErrorAction SilentlyContinue
        Start-Sleep 2
        Enable-NetAdapter -Name $selectedAdapter -ErrorAction SilentlyContinue
        Write-Ok "DHCP configured on $selectedAdapter"
    } else {
        # Static
        Write-Host ""
        Write-Host "  Static IP configuration for ${selectedAdapter}:" -ForegroundColor White
        $ip4     = Prompt-Input "  IP address   (e.g. 192.168.1.100)" ""
        $prefix  = Prompt-Input "  Prefix len   (e.g. 24)" "24"
        $gw      = Prompt-Input "  Gateway      (e.g. 192.168.1.1)" ""
        $dns1    = Prompt-Input "  Primary DNS" "8.8.8.8"
        $dns2    = Prompt-Input "  Secondary DNS" "8.8.4.4"

        Write-Info "Applying ${ip4}/${prefix} → gateway ${gw}..."

        # Remove existing IP config
        Remove-NetIPAddress -InterfaceAlias $selectedAdapter -AddressFamily IPv4 `
            -Confirm:$false -ErrorAction SilentlyContinue
        Remove-NetRoute -InterfaceAlias $selectedAdapter -AddressFamily IPv4 `
            -Confirm:$false -ErrorAction SilentlyContinue

        New-NetIPAddress -InterfaceAlias $selectedAdapter `
            -IPAddress $ip4 -PrefixLength ([int]$prefix) `
            -DefaultGateway $gw -ErrorAction Stop | Out-Null
        Set-DnsClientServerAddress -InterfaceAlias $selectedAdapter `
            -ServerAddresses $dns1,$dns2
        Write-Ok "Static IP ${ip4}/${prefix} configured"
    }

    # Wait for connectivity
    Write-Info "Waiting up to 20s for connectivity..."
    $ok = $false
    for ($attempt = 1; $attempt -le 10; $attempt++) {
        Start-Sleep 2
        Write-Host -NoNewline "`r  Checking... $attempt/10"
        if (Test-Connection -ComputerName "8.8.8.8" -Count 1 -Quiet -ErrorAction SilentlyContinue) {
            $ok = $true; break
        }
    }
    Write-Host ""
    if ($ok) { Write-Ok "Network is up!" }
    else {
        Write-Warn "Network still not reachable."
        $cont = Prompt-YN "Continue anyway? (Docker pull will fail)" "n"
        if (-not $cont) { exit 1 }
    }
}

# ── Docker Desktop ────────────────────────────────────────────────────────────
Write-Header "Docker Desktop"

if (-not $Reconfigure) {
    $dockerCmd = Get-Command docker -ErrorAction SilentlyContinue
    if ($dockerCmd) {
        $ver = & docker --version 2>$null
        Write-Ok "Docker already installed: $ver"
    } else {
        Write-Info "Docker Desktop not found — installing..."

        $installed = $false

        # Try winget first
        $winget = Get-Command winget -ErrorAction SilentlyContinue
        if ($winget) {
            Write-Info "Installing via winget..."
            try {
                & winget install Docker.DockerDesktop --silent --accept-package-agreements `
                    --accept-source-agreements 2>&1
                $installed = $true
                Write-Ok "Docker Desktop installed via winget"
            } catch {
                Write-Warn "winget install failed: $_"
            }
        }

        # Try Chocolatey
        if (-not $installed) {
            $choco = Get-Command choco -ErrorAction SilentlyContinue
            if (-not $choco) {
                Write-Info "Installing Chocolatey..."
                try {
                    Set-ExecutionPolicy Bypass -Scope Process -Force
                    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
                    Invoke-Expression ((New-Object Net.WebClient).DownloadString(
                        'https://community.chocolatey.org/install.ps1'))
                    $choco = Get-Command choco -ErrorAction SilentlyContinue
                } catch {
                    Write-Warn "Chocolatey install failed: $_"
                }
            }
            if ($choco) {
                Write-Info "Installing Docker Desktop via Chocolatey..."
                & choco install docker-desktop -y --no-progress
                $installed = $true
            }
        }

        # Fallback — direct download
        if (-not $installed) {
            $installer = "$env:TEMP\DockerDesktopInstaller.exe"
            Write-Info "Downloading Docker Desktop installer directly..."
            try {
                $url = "https://desktop.docker.com/win/main/amd64/Docker%20Desktop%20Installer.exe"
                (New-Object Net.WebClient).DownloadFile($url, $installer)
                Write-Info "Running installer (follow any prompts)..."
                Start-Process -Wait -FilePath $installer -ArgumentList "install --quiet"
                $installed = $true
                Write-Ok "Docker Desktop installed"
            } catch {
                Write-Err "All install methods failed: $_"
                Write-Host ""
                Write-Host "  Manual download: https://www.docker.com/products/docker-desktop/" -ForegroundColor Yellow
                exit 1
            }
        }

        Write-Warn "Docker Desktop requires a restart or sign-out in some cases."
        Write-Host ""
        Write-Host "  Please start Docker Desktop from the Start menu," -ForegroundColor Yellow
        Write-Host "  wait for the whale icon to appear in the taskbar," -ForegroundColor Yellow
        Write-Host "  then press Enter to continue." -ForegroundColor Yellow
        Read-Host
    }

    # Wait for Docker daemon
    Write-Info "Waiting for Docker daemon..."
    $ready = $false
    for ($i = 1; $i -le 30; $i++) {
        Start-Sleep 2
        Write-Host -NoNewline "`r  Checking Docker daemon... $i/30"
        $result = & docker info 2>$null
        if ($LASTEXITCODE -eq 0) { $ready = $true; break }
    }
    Write-Host ""
    if (-not $ready) {
        Write-Err "Docker daemon not responding. Start Docker Desktop and try again."
        exit 1
    }
    Write-Ok "Docker daemon is ready"

    # Verify compose
    $composeVer = & docker compose version 2>$null
    if ($LASTEXITCODE -eq 0) { Write-Ok "Docker Compose: $composeVer" }
    else { Write-Warn "Docker Compose not found — upgrade Docker Desktop" }
}

# ── Compute mode ──────────────────────────────────────────────────────────────
Write-Header "Compute Mode — HuggingFace / sentence-transformers"
Write-Host ""
Write-Host "  This installer configures float16 only." -ForegroundColor White
Write-Host "  Minimum resources for float16: CPU requires >=16 GB RAM, GPU requires >=16 GB VRAM." -ForegroundColor White
Write-Host ""

$ramGB = Get-TotalPhysicalMemoryGB
$qualifiedGpus = Get-QualifiedGpuAdapters
$hasCpu = $ramGB -ge 16
$hasGpu = $qualifiedGpus.Count -gt 0

Write-Host "  System RAM detected: ${ramGB} GB" -ForegroundColor White
if ($hasGpu) {
    Write-Host "  GPU(s) with >=16 GB VRAM detected:" -ForegroundColor White
    foreach ($gpu in $qualifiedGpus) {
        Write-Host "    - $($gpu.Name) ($($gpu.MemoryGB) GB)" -ForegroundColor White
    }
} else {
    Write-Host "  No GPU with >=16 GB VRAM detected." -ForegroundColor Yellow
}
Write-Host ""

if (-not $hasCpu -and -not $hasGpu) {
    Write-Err "This machine does not meet minimum float16 requirements."
    Write-Err "Minimum requirements: CPU >=16 GB RAM, or GPU >=16 GB VRAM."
    Write-Err "Use a machine with enough resources or install on a different host."
    exit 1
}

if ($hasCpu -and $hasGpu) {
    Write-Host "  Both CPU and GPU meet float16 minimums." -ForegroundColor White
    Write-Host "    [1]  CPU float16   — requires >=16 GB RAM" -ForegroundColor White
    Write-Host "    [2]  GPU float16   — requires >=16 GB VRAM" -ForegroundColor White
    Write-Host ""
    $computeChoice = Prompt-Input "Target device" "2"
} elseif ($hasGpu) {
    Write-Host "  Only GPU float16 is available on this host." -ForegroundColor White
    $computeChoice = "2"
} else {
    Write-Host "  Only CPU float16 is available on this host." -ForegroundColor White
    $computeChoice = "1"
}

$COMPUTE_MODE  = "gpu"
$GPU_TYPE      = ""
$PRECISION     = "float16"
$HSA_OVERRIDE  = ""

switch ($computeChoice) {
    "1" {
        $COMPUTE_MODE = "cpu"
        $PRECISION    = "float16"
    }
    "2" {
        $COMPUTE_MODE = "gpu"
        $PRECISION    = "float16"
        Write-Host "    [1] NVIDIA (CUDA)   [2] AMD (ROCm)" -ForegroundColor Gray
        $gt = Prompt-Input "GPU type" "1"
        $GPU_TYPE = if ($gt -eq "2") { "amd" } else { "nvidia" }
        if ($GPU_TYPE -eq "amd") {
            $HSA_OVERRIDE = Prompt-Input "HSA_OVERRIDE_GFX_VERSION (e.g. 11.0.0, blank to skip)" ""
        }
    }
    default { Write-Err "Invalid choice"; exit 1 }
}

Write-Ok "Compute: $COMPUTE_MODE | Precision: $PRECISION"

# ── Worker configuration ───────────────────────────────────────────────────────
Write-Header "Worker Configuration"

$hostname      = $env:COMPUTERNAME.ToLower() -replace '[^a-z0-9-]', ''
$NODE_NAME     = Prompt-Input "Node name (unique per server)" "worker-$hostname"
Write-Host ""
Write-Host "  n8n Webhook URLs:" -ForegroundColor White
$N8N_GET_URL   = Prompt-Input "  GET batch URL" `
    "https://n8n.3rfan.ir/webhook/4f1d52bf-25d5-4e0b-ab30-123f680d0265"
$N8N_SAVE_URL  = Prompt-Input "  SAVE vectors URL" `
    "https://n8n.3rfan.ir/webhook/4f1d52bf-25d5-4e0b-ab30-123f680d0255"
$N8N_API_KEY   = Prompt-Input "  API Key" "123"
Write-Host ""
Write-Host "  Status reporting — optional heartbeat POST to n8n:" -ForegroundColor White
Write-Host "  Leave blank to disable." -ForegroundColor DarkGray
$N8N_STATUS_URL  = Prompt-Input "  STATUS webhook URL" ""
$STATUS_INTERVAL = "10"
if ($N8N_STATUS_URL -ne "") {
    $STATUS_INTERVAL = Prompt-Input "  Report status every N cycles" "10"
}
Write-Host ""
$HF_MODEL_NAME = Prompt-Input "HuggingFace model name" "Qwen/Qwen3-Embedding-8B"
Write-Host ""
Write-Host "  Model source options:" -ForegroundColor White
Write-Host "    [hf]    — download from HuggingFace Hub (may require API token)" -ForegroundColor White
Write-Host "    [url]   — direct HTTP URL to a model archive (zip/tar.gz)" -ForegroundColor White
Write-Host "    [local] — local path on the host (must be mounted into the container)" -ForegroundColor White

$modelSource = Prompt-Input "Model source (hf/url/local)" "hf"
$HF_AUTH_TOKEN = ""
$HF_MODEL_URL = ""
$HF_MODEL_LOCAL_PATH = ""
if ($modelSource -eq "hf") {
    $HF_AUTH_TOKEN = Prompt-Input "HuggingFace API token (leave blank to use public or existing creds)" ""
} elseif ($modelSource -eq "url") {
    $HF_MODEL_URL = Prompt-Input "Direct model URL (zip or tar.gz)" ""
} elseif ($modelSource -eq "local") {
    $HF_MODEL_LOCAL_PATH = Prompt-Input "Local model path (host path, mapped to container)" ""
} else {
    Write-Warn "Unknown source type — defaulting to HuggingFace Hub"
    $modelSource = "hf"
    $HF_AUTH_TOKEN = Prompt-Input "HuggingFace API token (leave blank to use public or existing creds)" ""
}

$defaultBatch  = if ($COMPUTE_MODE -eq "cpu") { "2" } else { "10" }
Write-Host "  Recommended: CPU=2-5  GPU=10-50" -ForegroundColor DarkGray
$BATCH_SIZE    = Prompt-Input "Batch size" $defaultBatch
$DELAY_SECS    = Prompt-Input "Delay between cycles (seconds)" "5"
Write-Host "  Examples: 30m  8h  1d  1d-5h-30m  (blank = run forever)" -ForegroundColor DarkGray
$STOP_AT       = Prompt-Input "Stop after" ""

# ── Write .env ────────────────────────────────────────────────────────────────
Write-Header "Writing Configuration"

$restartPolicy = if ($STOP_AT -ne "") { "on-failure" } else { "always" }
$envContent = @"
# Embedding Worker — generated by install.ps1 $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')

# -- Identity -----------------------------------------------------------------
NODE_NAME=$NODE_NAME

# -- n8n Webhooks -------------------------------------------------------------
N8N_GET_URL=$N8N_GET_URL
N8N_SAVE_URL=$N8N_SAVE_URL
N8N_API_KEY=$N8N_API_KEY
N8N_STATUS_URL=$N8N_STATUS_URL
STATUS_INTERVAL=$STATUS_INTERVAL

# -- Model (HuggingFace) ------------------------------------------------------
HF_MODEL_NAME=$HF_MODEL_NAME
HF_HOME=/root/.cache/huggingface
# Optional model source settings:
# HF_AUTH_TOKEN — API token for HuggingFace Hub (written to container env)
# HF_MODEL_URL  — direct HTTP URL to a model archive (zip/tar.gz)
# HF_MODEL_LOCAL_PATH — path on host mounted into container for local models
HF_AUTH_TOKEN=$HF_AUTH_TOKEN
HF_MODEL_URL=$HF_MODEL_URL
HF_MODEL_LOCAL_PATH=$HF_MODEL_LOCAL_PATH

# -- Precision / compute ------------------------------------------------------
# PRECISION: float16 | float32 | 8bit | 4bit
PRECISION=$PRECISION
COMPUTE_MODE=$COMPUTE_MODE
GPU_TYPE=$GPU_TYPE
# AMD GPU compatibility override (leave blank for NVIDIA or pure CPU)
HSA_OVERRIDE_GFX_VERSION=$HSA_OVERRIDE

# -- Batch / timing -----------------------------------------------------------
BATCH_SIZE=$BATCH_SIZE
DELAY_SECONDS=$DELAY_SECS
STOP_AT=$STOP_AT
REQUEST_TIMEOUT=30
RESTART_POLICY=$restartPolicy
"@

$envPath = Join-Path $ScriptDir ".env"
$envContent | Set-Content -Path $envPath -Encoding UTF8
Write-Ok ".env written to $envPath"

# Patch docker-compose.yml to add container_name
$composePath = Join-Path $ScriptDir "docker-compose.yml"
if (Test-Path $composePath) {
    $compose = Get-Content $composePath -Raw
    if ($compose -notmatch "container_name:") {
        $compose = $compose -replace "(\s*image:)", "    container_name: embedding-worker`n`$1"
        $compose | Set-Content -Path $composePath -Encoding UTF8
        Write-Ok "docker-compose.yml: added container_name: embedding-worker"
    } else {
        Write-Ok "docker-compose.yml: container_name already set"
    }
}

# ── Build & start ─────────────────────────────────────────────────────────────
Write-Header "Building & Starting Worker"
Set-Location $ScriptDir

$composeArgs = @("-f", "docker-compose.yml")
if ($COMPUTE_MODE -ne "cpu") {
    if ($GPU_TYPE -eq "nvidia" -and (Test-Path "docker-compose.nvidia.yml")) {
        $composeArgs += @("-f", "docker-compose.nvidia.yml")
    } elseif ($GPU_TYPE -eq "amd" -and (Test-Path "docker-compose.amd.yml")) {
        $composeArgs += @("-f", "docker-compose.amd.yml")
    }
}

Write-Info "Building image (first run downloads model from HuggingFace — may take 10-30 min)..."
& docker compose @composeArgs build
if ($LASTEXITCODE -ne 0) { Write-Err "Build failed — check output above"; exit 1 }

Write-Info "Starting container..."
& docker compose @composeArgs up -d
Start-Sleep 4

$running = & docker ps --filter "name=embedding-worker" --filter "status=running" `
    --format "{{.Names}}" 2>$null
if ($running -match "embedding-worker") {
    Write-Ok "Container 'embedding-worker' is running!"
    & docker ps --filter "name=embedding-worker" --format "  {{.Names}}  {{.Status}}"
} else {
    Write-Warn "Container may still be starting — check: docker logs embedding-worker"
}

# ── Done ──────────────────────────────────────────────────────────────────────
Write-Header "Installation Complete"
Write-Host ""
Write-Host "  Worker is running!" -ForegroundColor Green
Write-Host ""
Write-Host "  Quick commands:" -ForegroundColor White
Write-Host "    docker logs -f embedding-worker           <- live logs"
Write-Host "    docker ps                                 <- container status"
Write-Host ""
Write-Host "  CPU management (works while container is running):" -ForegroundColor White
Write-Host "    docker update --cpus=4 embedding-worker   <- limit to 4 cores"
Write-Host "    docker update --cpu-quota=-1 embedding-worker  <- remove limit"
Write-Host ""
Write-Host "  On WSL2 or Git Bash you can also use:" -ForegroundColor DarkGray
Write-Host "    bash manage.sh logs                       <- live monitor"
Write-Host "    bash manage.sh cpu 4 8h                   <- 4 cores for 8 hours"
Write-Host ""
