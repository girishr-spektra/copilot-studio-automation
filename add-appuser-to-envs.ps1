# ============================================================================
# BULK APPLICATION USER (S2S) REGISTRATION TO DEVELOPER ENVIRONMENTS
# ============================================================================
# Registers an Azure AD application as an Application User (S2S) with
# System Administrator role in all developer environments from devenv-results.csv
#
# Uses: pac admin assign-user --environment <id> --user <app-id> --role "System Administrator" --application-user
#
# This is the correct PAC CLI command to add an S2S application user to a
# specific Dataverse environment with a security role.
#
# FEATURES:
#   - Auto-resume: skips environments already processed in prior runs
#   - Results saved after EVERY registration for crash recovery
#   - Exponential backoff on errors (retries only on failure)
#   - No delays between successful operations (runs as fast as possible)
#
# USAGE:
#   # First time - authenticate as Global/Power Platform Admin:
#   pac auth create --name "LabAdmin"
#
#   # Run with defaults:
#   .\add-appuser-to-envs.ps1
#
#   # Point to a different results file:
#   .\add-appuser-to-envs.ps1 -EnvResultsCsvPath "C:\automations\important\devenv-results.csv"
#
#   # Resume from a specific index:
#   .\add-appuser-to-envs.ps1 -StartFromIndex 20
#
#   # Dry run:
#   .\add-appuser-to-envs.ps1 -DryRun
# ============================================================================

param(
    [Parameter(Mandatory=$false, HelpMessage="Azure AD Application (Client) ID GUID of the S2S app to register")]
    [string]$ApplicationId = "5e3e0b1b-dc41-4cab-a63f-ebcdea476f46",

    [Parameter(Mandatory=$false)]
    [string]$EnvResultsCsvPath = "C:\automations\important\devenv-results.csv",

    [Parameter(Mandatory=$false)]
    [string]$OutputCsvPath = "C:\automations\important\appuser-registration-results.csv",

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
Write-Host "`n╔═══════════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║  BULK APPLICATION USER (S2S) REGISTRATION                    ║" -ForegroundColor Green
Write-Host "║  Adds app user as System Administrator to all dev envs       ║" -ForegroundColor Green
Write-Host "╚═══════════════════════════════════════════════════════════════╝" -ForegroundColor Cyan

if ($DryRun) {
    Write-Host "`n  *** DRY RUN MODE - No registrations will be performed ***`n" -ForegroundColor Yellow
}

# ── Validate ApplicationId is a GUID ───────────────────────────────────────
$guidRegex = '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
if ($ApplicationId -notmatch $guidRegex) {
    Write-Host "`n  [ERROR] ApplicationId must be a valid GUID (Application Client ID)." -ForegroundColor Red
    Write-Host "  You provided: $ApplicationId" -ForegroundColor Red
    Write-Host "`n  The Application ID URI (e.g. https://cloudlabssandbox.onmicrosoft.com/cloudlabs.ai/)" -ForegroundColor Yellow
    Write-Host "  is NOT the same as the Application (Client) ID." -ForegroundColor Yellow
    Write-Host "  Go to Azure Portal > App Registrations > find your app > copy the GUID.`n" -ForegroundColor Yellow
    exit 1
}

# ── Preflight checks ───────────────────────────────────────────────────────
Write-Host "`n[PREFLIGHT] Checking PAC CLI..." -ForegroundColor Cyan
try {
    $pacHelp = pac help 2>&1
    if ($LASTEXITCODE -ne 0) { throw "pac not found" }
    Write-Host "  PAC CLI found" -ForegroundColor Green
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

# ── Load environment results ───────────────────────────────────────────────
Write-Host "[PREFLIGHT] Loading environment results from $EnvResultsCsvPath..." -ForegroundColor Cyan
if (-not (Test-Path $EnvResultsCsvPath)) {
    Write-Host "  File not found: $EnvResultsCsvPath" -ForegroundColor Red
    Write-Host "  Run the dev environment creation script first." -ForegroundColor Yellow
    exit 1
}

$allEnvs = Import-Csv -Path $EnvResultsCsvPath | Where-Object { $_.Status -eq "Success" -and $_.EnvironmentId }
$totalEnvs = $allEnvs.Count

if ($totalEnvs -eq 0) {
    Write-Host "  No successful environments found in results CSV." -ForegroundColor Red
    exit 1
}
Write-Host "  Loaded $totalEnvs successful environments" -ForegroundColor Green

# ── Load previous results for resume ───────────────────────────────────────
$completedEnvs = @{}
if (Test-Path $OutputCsvPath) {
    $previousResults = Import-Csv -Path $OutputCsvPath
    foreach ($r in $previousResults) {
        if ($r.Status -eq "Success") {
            $completedEnvs[$r.EnvironmentId] = $true
        }
    }
    $skipCount = $completedEnvs.Count
    if ($skipCount -gt 0) {
        Write-Host "  Found $skipCount already-completed environments (will skip)" -ForegroundColor Yellow
    }
}

# ── Build work queue ───────────────────────────────────────────────────────
$workQueue = @()
$idx = 0
foreach ($env in $allEnvs) {
    $idx++
    if ($idx -lt $StartFromIndex) { continue }
    if ($completedEnvs.ContainsKey($env.EnvironmentId)) { continue }
    $workQueue += [PSCustomObject]@{
        Index           = $idx
        UserEmail       = $env.UserEmail
        EnvironmentName = $env.EnvironmentName
        EnvironmentId   = $env.EnvironmentId
    }
}

$pendingCount = $workQueue.Count
if ($pendingCount -eq 0) {
    Write-Host "`n  All environments already have the app user registered! Nothing to do." -ForegroundColor Green
    exit 0
}

# ── Summary ─────────────────────────────────────────────────────────────────
Write-Host "`n┌──────────────────────────────────────────┐" -ForegroundColor White
Write-Host "│  Application (Client) ID : $ApplicationId" -ForegroundColor White
Write-Host "│  Environments to process : $pendingCount" -ForegroundColor White
Write-Host "│  Max retries per env     : $MaxRetries" -ForegroundColor White
Write-Host "└──────────────────────────────────────────┘" -ForegroundColor White

if (-not $DryRun -and -not $AutoConfirm) {
    Write-Host ""
    $confirm = Read-Host "  Proceed? (Y/N)"
    if ($confirm -ne "Y" -and $confirm -ne "y") {
        Write-Host "  Cancelled." -ForegroundColor Yellow
        exit 0
    }
}

# ── Helper: Save one result row ────────────────────────────────────────────
function Save-Result {
    param(
        [string]$EnvironmentId,
        [string]$EnvironmentName,
        [string]$UserEmail,
        [string]$ApplicationId,
        [string]$Status,
        [string]$Error
    )
    $row = [PSCustomObject]@{
        EnvironmentId   = $EnvironmentId
        EnvironmentName = $EnvironmentName
        UserEmail       = $UserEmail
        ApplicationId   = $ApplicationId
        Status          = $Status
        Error           = $Error
        Timestamp       = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
    }
    $fileExists = Test-Path $OutputCsvPath
    if ($fileExists) {
        $row | Export-Csv -Path $OutputCsvPath -Append -NoTypeInformation -Encoding UTF8
    } else {
        $row | Export-Csv -Path $OutputCsvPath -NoTypeInformation -Encoding UTF8
    }
    return $row
}

# ── Main loop ──────────────────────────────────────────────────────────────
$startTime = Get-Date
$successCount = 0
$failedCount = 0
$skippedCount = 0
$batchCounter = 0

Write-Host "`n═══════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "  STARTING APPLICATION USER REGISTRATION" -ForegroundColor Green
Write-Host "═══════════════════════════════════════════`n" -ForegroundColor Cyan

foreach ($item in $workQueue) {
    $batchCounter++
    $elapsed = (Get-Date) - $startTime
    $elapsedStr = "{0:hh\:mm\:ss}" -f $elapsed

    Write-Host "[$batchCounter/$pendingCount] [$elapsedStr]" -ForegroundColor Cyan
    Write-Host "  Env: $($item.EnvironmentName) ($($item.EnvironmentId))" -ForegroundColor White
    Write-Host "  Owner: $($item.UserEmail)" -ForegroundColor Gray

    if ($DryRun) {
        Write-Host "  [DRY RUN] Would register app $ApplicationId" -ForegroundColor Yellow
        $skippedCount++
        continue
    }

    # Retry loop with exponential backoff
    $registered = $false
    $lastError = ""
    $backoffSeconds = 30

    for ($attempt = 1; $attempt -le $MaxRetries; $attempt++) {
        if ($attempt -gt 1) {
            Write-Host "  Retry $attempt/$MaxRetries (backoff ${backoffSeconds}s)..." -ForegroundColor Yellow
            Start-Sleep -Seconds $backoffSeconds
            $backoffSeconds = [math]::Min($backoffSeconds * 2, 240)
        }

        try {
            Write-Host "  Adding application user (S2S) with System Administrator role..." -ForegroundColor Gray

            $output = pac admin assign-user `
                --environment $item.EnvironmentId `
                --user $ApplicationId `
                --role "System Administrator" `
                --application-user 2>&1

            $outputStr = $output -join "`n"

            if ($LASTEXITCODE -eq 0) {
                Write-Host "  [SUCCESS] App user registered as System Administrator" -ForegroundColor Green
                Save-Result `
                    -EnvironmentId $item.EnvironmentId `
                    -EnvironmentName $item.EnvironmentName `
                    -UserEmail $item.UserEmail `
                    -ApplicationId $ApplicationId `
                    -Status "Success" `
                    -Error ""
                $successCount++
                $registered = $true
                break
            } else {
                $lastError = $outputStr
                # Check for throttling
                if ($outputStr -match "throttl|429|Too Many Requests|rate limit") {
                    Write-Host "  [THROTTLED] Will retry after backoff..." -ForegroundColor Yellow
                    continue
                }
                # Check if app user already exists
                if ($outputStr -match "already exists|already registered|duplicate") {
                    Write-Host "  [SKIPPED] App user already registered in this environment" -ForegroundColor Yellow
                    Save-Result `
                        -EnvironmentId $item.EnvironmentId `
                        -EnvironmentName $item.EnvironmentName `
                        -UserEmail $item.UserEmail `
                        -ApplicationId $ApplicationId `
                        -Status "Success" `
                        -Error "Already registered"
                    $successCount++
                    $registered = $true
                    break
                }
                # Other error - retry
                Write-Host "  [ERROR] $outputStr" -ForegroundColor Red
            }
        }
        catch {
            $lastError = $_.Exception.Message
            Write-Host "  [ERROR] $lastError" -ForegroundColor Red
        }
    }

    if (-not $registered) {
        Write-Host "  [FAILED] All $MaxRetries attempts exhausted" -ForegroundColor Red
        Save-Result `
            -EnvironmentId $item.EnvironmentId `
            -EnvironmentName $item.EnvironmentName `
            -UserEmail $item.UserEmail `
            -ApplicationId $ApplicationId `
            -Status "Failed" `
            -Error $lastError
        $failedCount++
    }
}

# ── Summary ────────────────────────────────────────────────────────────────
$totalElapsed = (Get-Date) - $startTime
$totalElapsedStr = "{0:hh\:mm\:ss}" -f $totalElapsed

Write-Host "`n╔═══════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║          REGISTRATION COMPLETE                ║" -ForegroundColor Green
Write-Host "╠═══════════════════════════════════════════════╣" -ForegroundColor Cyan
Write-Host "║  Application ID : $ApplicationId" -ForegroundColor White
Write-Host "║  Total processed: $batchCounter" -ForegroundColor White
Write-Host "║  Successful     : $successCount" -ForegroundColor Green
Write-Host "║  Failed         : $failedCount" -ForegroundColor $(if ($failedCount -gt 0) { "Red" } else { "White" })
if ($DryRun) {
Write-Host "║  Dry Run skipped: $skippedCount" -ForegroundColor Yellow
}
Write-Host "║  Elapsed time   : $totalElapsedStr" -ForegroundColor White
Write-Host "║  Results saved  : $OutputCsvPath" -ForegroundColor White
Write-Host "╚═══════════════════════════════════════════════╝`n" -ForegroundColor Cyan
