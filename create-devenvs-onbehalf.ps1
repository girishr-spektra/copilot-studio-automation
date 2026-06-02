# ============================================================================
# BULK DEVELOPER ENVIRONMENT CREATOR (On Behalf Of Users)
# ============================================================================
# Creates Power Platform Developer environments as Global Admin on behalf of
# users using: pac admin create --name "..." --type Developer --user "..."
#
# THROTTLING STRATEGY:
#   - 10-second delay between each environment creation
#   - Exponential backoff on throttling errors (30s -> 60s -> 120s -> 240s)
#   - Auto-resume: skips users who already have environments from prior runs
#   - Results saved after EVERY creation for crash recovery
#
# USAGE:
#   # First time - authenticate as Global Admin:
#   pac auth create --name "LabAdmin"
#
#   # Run with defaults (batch of 10, 10s delay):
#   .\create-devenvs-onbehalf.ps1
#
#   # Custom throttling (slower for safety):
#   .\create-devenvs-onbehalf.ps1 -BatchSize 5 -DelayBetweenCreations 20
#
#   # Resume from user #30 (if you stopped midway):
#   .\create-devenvs-onbehalf.ps1 -StartFromIndex 30
#
#   # Dry run to verify without creating anything:
#   .\create-devenvs-onbehalf.ps1 -DryRun
# ============================================================================

param(
    [Parameter(Mandatory=$false)]
    [string]$UserCsvPath = "C:\automations\important\user-devenv2.csv",

    [Parameter(Mandatory=$false)]
    [string]$ResultsCsvPath = "C:\automations\important\devenv-results.csv",

    [Parameter(Mandatory=$false)]
    [string]$Region = "unitedstates",

    [Parameter(Mandatory=$false)]
    [int]$BatchSize = 10,

    [Parameter(Mandatory=$false)]
    [int]$DelayBetweenCreations = 10,

    [Parameter(Mandatory=$false)]
    [int]$MaxRetries = 3,

    [Parameter(Mandatory=$false)]
    [int]$StartFromIndex = 1,

    [Parameter(Mandatory=$false)]
    [switch]$DryRun = $false,

    [Parameter(Mandatory=$false)]
    [switch]$AutoConfirm = $false
)

$ErrorActionPreference = "Continue"

# ── Banner ──────────────────────────────────────────────────────────────────
Write-Host "`n╔═══════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║  BULK DEVELOPER ENVIRONMENT CREATOR (On Behalf Of Users) ║" -ForegroundColor Green
Write-Host "║  pac admin create --type Developer --user <UPN>          ║" -ForegroundColor Green
Write-Host "╚═══════════════════════════════════════════════════════════╝" -ForegroundColor Cyan

if ($DryRun) {
    Write-Host "`n  *** DRY RUN MODE - No environments will be created ***`n" -ForegroundColor Yellow
}

# ── Preflight checks ───────────────────────────────────────────────────────
Write-Host "`n[PREFLIGHT] Checking PAC CLI..." -ForegroundColor Cyan
try {
    $pacVer = pac --version 2>&1
    if ($LASTEXITCODE -ne 0) { throw "pac not found" }
    Write-Host "  PAC CLI: $pacVer" -ForegroundColor Green
} catch {
    Write-Host "  PAC CLI not installed. Get it from https://aka.ms/PowerAppsCLI" -ForegroundColor Red
    exit 1
}

Write-Host "[PREFLIGHT] Checking auth profile..." -ForegroundColor Cyan
$authList = pac auth list 2>&1
if ($authList -match "No profiles") {
    Write-Host "  No auth profile found. Run:  pac auth create --name `"LabAdmin`"" -ForegroundColor Red
    exit 1
}
Write-Host "  Auth OK" -ForegroundColor Green

# ── Load users ──────────────────────────────────────────────────────────────
Write-Host "[PREFLIGHT] Loading user list from $UserCsvPath..." -ForegroundColor Cyan
if (-not (Test-Path $UserCsvPath)) {
    Write-Host "  File not found: $UserCsvPath" -ForegroundColor Red
    exit 1
}
$allUsers = Import-Csv -Path $UserCsvPath
$totalUsers = $allUsers.Count
Write-Host "  Loaded $totalUsers users" -ForegroundColor Green

# ── Load previous results for resume ────────────────────────────────────────
$completedUsers = @{}
if (Test-Path $ResultsCsvPath) {
    $previousResults = Import-Csv -Path $ResultsCsvPath
    foreach ($r in $previousResults) {
        if ($r.Status -eq "Success") {
            $completedUsers[$r.UserEmail] = $true
        }
    }
    $skipCount = $completedUsers.Count
    if ($skipCount -gt 0) {
        Write-Host "  Found $skipCount already-completed users (will skip)" -ForegroundColor Yellow
    }
}

# ── Build work queue (skip completed + apply StartFromIndex) ────────────────
$workQueue = @()
$idx = 0
foreach ($user in $allUsers) {
    $idx++
    if ($idx -lt $StartFromIndex) { continue }
    if ($completedUsers.ContainsKey($user.UserEmail)) { continue }
    $workQueue += [PSCustomObject]@{
        Index     = $idx
        UserEmail = $user.UserEmail.Trim()
    }
}

$pendingCount = $workQueue.Count
if ($pendingCount -eq 0) {
    Write-Host "`n  All environments already created! Nothing to do." -ForegroundColor Green
    exit 0
}

$totalBatches = [math]::Ceiling($pendingCount / $BatchSize)

# ── Summary ─────────────────────────────────────────────────────────────────
Write-Host "`n┌─────────────────────────────────────┐" -ForegroundColor White
Write-Host "│  Environments to create : $pendingCount" -ForegroundColor White
Write-Host "│  Batch size             : $BatchSize" -ForegroundColor White
Write-Host "│  Total batches          : $totalBatches" -ForegroundColor White
Write-Host "│  Delay between each     : ${DelayBetweenCreations}s" -ForegroundColor White
Write-Host "│  Region                 : $Region" -ForegroundColor White
Write-Host "│  Max retries per user   : $MaxRetries" -ForegroundColor White
Write-Host "└─────────────────────────────────────┘" -ForegroundColor White

if (-not $DryRun -and -not $AutoConfirm) {
    Write-Host ""
    $confirm = Read-Host "Proceed? (Y/N)"
    if ($confirm -notin @("Y","y","yes")) {
        Write-Host "Cancelled." -ForegroundColor Yellow
        exit 0
    }
}

# ── Helper: save one result row (append) ────────────────────────────────────
function Save-Result {
    param(
        [string]$UserEmail,
        [string]$EnvironmentName,
        [string]$Status,
        [string]$EnvironmentId,
        [string]$ErrorDetail,
        [string]$Timestamp
    )

    $row = [PSCustomObject]@{
        UserEmail       = $UserEmail
        EnvironmentName = $EnvironmentName
        Status          = $Status
        EnvironmentId   = $EnvironmentId
        Error           = $ErrorDetail
        Timestamp       = $Timestamp
    }

    $fileExists = Test-Path $ResultsCsvPath
    if ($fileExists) {
        $row | Export-Csv -Path $ResultsCsvPath -Append -NoTypeInformation
    } else {
        $row | Export-Csv -Path $ResultsCsvPath -NoTypeInformation
    }
}

# ── Helper: create one environment with retry ───────────────────────────────
function New-DevEnvOnBehalf {
    param(
        [string]$UserEmail,
        [string]$Region,
        [int]$MaxRetries
    )

    # Derive a friendly environment name from the numeric user ID
    $userId = [regex]::Match($UserEmail.Split('@')[0], '\d+').Value
    $envName = "ODL_User $($userId)'s Environment"

    for ($attempt = 1; $attempt -le $MaxRetries; $attempt++) {

        if ($DryRun) {
            Write-Host "    [DRY RUN] Would create: $envName for $UserEmail" -ForegroundColor Gray
            return @{ Success = $true; EnvId = "dry-run"; EnvName = $envName; Error = $null }
        }

        Write-Host "    Creating '$envName' (attempt $attempt/$MaxRetries)..." -ForegroundColor Gray

        $output = pac admin create `
            --name $envName `
            --type Developer `
            --user $UserEmail `
            --region $Region 2>&1 | Out-String

        if ($LASTEXITCODE -eq 0) {
            # Try to parse environment ID from output
            $envId = "created"
            if ($output -match "([a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12})") {
                $envId = $matches[1]
            }
            return @{ Success = $true; EnvId = $envId; EnvName = $envName; Error = $null }
        }

        # Check for throttling indicators
        $isThrottled = $output -match "throttl|429|Too Many|rate limit|try again|Retry-After" -or
                       $output -match "preparing|Apollo|service unavailable|503"

        if ($isThrottled -and $attempt -lt $MaxRetries) {
            # Exponential backoff: 30s, 60s, 120s
            $backoff = 30 * [math]::Pow(2, $attempt - 1)
            Write-Host "    Throttled! Backing off for ${backoff}s..." -ForegroundColor Yellow
            Start-Sleep -Seconds $backoff
        }
        elseif ($attempt -lt $MaxRetries) {
            # Generic error - short retry delay
            Write-Host "    Failed. Retrying in 15s..." -ForegroundColor Yellow
            Start-Sleep -Seconds 15
        }
    }

    return @{ Success = $false; EnvId = $null; EnvName = $envName; Error = $output }
}

# ── Main loop ───────────────────────────────────────────────────────────────
Write-Host "`n════════════════════════════════════════════════════" -ForegroundColor Yellow
Write-Host "  STARTING ENVIRONMENT CREATION" -ForegroundColor Green
Write-Host "════════════════════════════════════════════════════`n" -ForegroundColor Yellow

$startTime   = Get-Date
$successCount = 0
$failCount    = 0
$processed    = 0

foreach ($item in $workQueue) {
    $processed++

    $userEmail = $item.UserEmail
    $pct = [math]::Round(($processed / $pendingCount) * 100, 1)

    Write-Host "[$processed/$pendingCount] ($pct%) $userEmail" -ForegroundColor Cyan

    # ── Create the environment ──
    $result = New-DevEnvOnBehalf -UserEmail $userEmail -Region $Region -MaxRetries $MaxRetries

    if ($result.Success) {
        $successCount++
        Write-Host "    OK  Environment: $($result.EnvName)  ID: $($result.EnvId)" -ForegroundColor Green

        Save-Result -UserEmail $userEmail `
                    -EnvironmentName $result.EnvName `
                    -Status "Success" `
                    -EnvironmentId $result.EnvId `
                    -ErrorDetail "" `
                    -Timestamp (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
    }
    else {
        $failCount++
        $errShort = if ($result.Error) { ($result.Error -replace "`r`n|`n"," ").Substring(0, [math]::Min(200, $result.Error.Length)) } else { "Unknown error" }
        Write-Host "    FAIL  $errShort" -ForegroundColor Red

        Save-Result -UserEmail $userEmail `
                    -EnvironmentName $result.EnvName `
                    -Status "Failed" `
                    -EnvironmentId "" `
                    -ErrorDetail $errShort `
                    -Timestamp (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
    }

    # ── Throttle delay ──
    if ($processed -lt $pendingCount) {
        if (-not $DryRun) { Start-Sleep -Seconds $DelayBetweenCreations }
    }
}

# ── Final summary ───────────────────────────────────────────────────────────
$elapsed = (Get-Date) - $startTime

Write-Host "`n╔═══════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║                    EXECUTION COMPLETE                     ║" -ForegroundColor Green
Write-Host "╠═══════════════════════════════════════════════════════════╣" -ForegroundColor Cyan
Write-Host "║  Processed  : $processed" -ForegroundColor White
Write-Host "║  Succeeded  : $successCount" -ForegroundColor Green
Write-Host "║  Failed     : $failCount" -ForegroundColor $(if ($failCount -gt 0) {"Red"} else {"Green"})
Write-Host "║  Duration   : $([math]::Round($elapsed.TotalMinutes, 1)) minutes" -ForegroundColor White
Write-Host "║  Results at : $ResultsCsvPath" -ForegroundColor White
Write-Host "╚═══════════════════════════════════════════════════════════╝`n" -ForegroundColor Cyan

if ($failCount -gt 0) {
    Write-Host "To retry failed users, just re-run the script - it auto-skips successes.`n" -ForegroundColor Yellow
}
