# Power Platform Developer Environment Provisioning & App User Registration

## Overview

This automation provisions **Power Platform Developer Environments** for bulk users and then registers an **Azure AD Application User (S2S)** with **System Administrator** role in each of those environments. This is a two-step workflow run by a Global Admin / Power Platform Admin.

---

## Architecture & Workflow

```
┌─────────────────────────────────────────────────────────────────────────┐
│                         TWO-STEP WORKFLOW                                │
│                                                                         │
│  STEP 1: Create Developer Environments                                  │
│  ─────────────────────────────────────                                  │
│  Input:  users-devenv.csv (or user-devenv2.csv)                         │
│  Script: create-devenvs-onbehalf.ps1                                    │
│  Output: devenv-results.csv                                             │
│                                                                         │
│  STEP 2: Add Application User (S2S) to Each Environment                 │
│  ────────────────────────────────────────────────────────               │
│  Input:  devenv-results.csv (output from Step 1)                        │
│  Script: add-appuser-to-envs.ps1                                        │
│  Output: appuser-registration-results.csv                               │
│                                                                         │
└─────────────────────────────────────────────────────────────────────────┘
```

---

## Prerequisites

1. **PAC CLI (Power Platform CLI)** installed  
   - Install: https://aka.ms/PowerAppsCLI  
   - Verify: `pac --version`

2. **Authentication** — You must be authenticated as a **Global Admin** or **Power Platform Admin**:
   ```powershell
   pac auth create --name "LabAdmin"
   ```
   This opens a browser for interactive login. After auth, verify with:
   ```powershell
   pac auth list
   ```

3. **Azure AD Application Registration** already exists  
   - The Application (Client) ID used in Step 2 is: `5e3e0b1b-dc41-4cab-a63f-ebcdea476f46`
   - This app is registered in Azure AD (Entra ID) under the tenant
   - It will be added as an S2S Application User with System Administrator role

4. **PowerShell 7+** recommended (works with Windows PowerShell 5.1 too)

5. **Working directory**: `C:\automations\important\`

---

## File Structure

```
C:\automations\important\
├── context.md                              ← This file (workflow documentation)
├── create-devenvs-onbehalf.ps1             ← STEP 1: Creates dev environments
├── add-appuser-to-envs.ps1                 ← STEP 2: Registers app user in envs
├── users-devenv.csv                        ← INPUT: User emails (you edit this)
├── user-devenv2.csv                        ← INPUT: Alternate user list
├── devenv-results.csv                      ← OUTPUT: Created environments with IDs
├── appuser-registration-results.csv        ← OUTPUT: App user registration results
├── devenv-results-batch2.csv               ← OUTPUT: Env results for batch2 users
└── appuser-registration-results-batch2.csv ← OUTPUT: App user results for batch2
```

---

## Quick Start (For Colleagues)

### What You Need To Do:

1. **Add user emails** to a CSV file
2. **Run Step 1** to create environments
3. **Run Step 2** to add the app user

That's it. Details below.

---

## Step-by-Step Instructions

### STEP 0: Prepare Your User List

Create or edit a CSV file with a single column `UserEmail`. Example:

**File**: `C:\automations\important\users-devenv.csv`

```csv
UserEmail
odl_user_2154166@cloudlabssandbox.onmicrosoft.com
odl_user_2154168@cloudlabssandbox.onmicrosoft.com
odl_user_2154169@cloudlabssandbox.onmicrosoft.com
```

> **IMPORTANT**: The CSV must have a header row `UserEmail` as the first line. Each subsequent line is one user's UPN (email).

---

### STEP 1: Create Developer Environments

This script creates a Power Platform Developer environment for each user in the CSV using `pac admin create --type Developer --user <UPN>`.

**Command:**
```powershell
cd C:\automations\important
.\create-devenvs-onbehalf.ps1
```

**With custom parameters:**
```powershell
# Use a specific input file
.\create-devenvs-onbehalf.ps1 -UserCsvPath "C:\automations\important\users-devenv.csv"

# Dry run (preview without creating)
.\create-devenvs-onbehalf.ps1 -DryRun

# Auto-confirm (skip Y/N prompt)
.\create-devenvs-onbehalf.ps1 -AutoConfirm

# Resume from user #30 if interrupted
.\create-devenvs-onbehalf.ps1 -StartFromIndex 30

# Custom throttling (slower to avoid rate limits)
.\create-devenvs-onbehalf.ps1 -BatchSize 5 -DelayBetweenCreations 20
```

**Parameters:**
| Parameter | Default | Description |
|-----------|---------|-------------|
| `-UserCsvPath` | `C:\automations\important\user-devenv2.csv` | Path to input CSV with user emails |
| `-ResultsCsvPath` | `C:\automations\important\devenv-results.csv` | Path to output results CSV |
| `-Region` | `unitedstates` | Power Platform region |
| `-BatchSize` | `10` | Users per batch |
| `-DelayBetweenCreations` | `10` | Seconds between each creation |
| `-MaxRetries` | `3` | Retry attempts per user on failure |
| `-StartFromIndex` | `1` | Skip to this user index (for resume) |
| `-DryRun` | `$false` | Preview mode, no actual creation |
| `-AutoConfirm` | `$false` | Skip Y/N confirmation prompt |

**Output**: `devenv-results.csv` with columns:
```csv
UserEmail,EnvironmentName,Status,EnvironmentId,Error,Timestamp
```

**Behavior:**
- Creates environment named `"ODL_User <NUMBER>'s Environment"` per user
- 10-second delay between creations to avoid throttling
- Exponential backoff (30s → 60s → 120s → 240s) on throttle errors
- **Auto-resume**: Re-running skips already-successful users
- Results saved after EVERY creation for crash recovery
- Takes ~10-15 seconds per environment

---

### STEP 2: Add Application User (S2S) to All Environments

This script adds an Azure AD app as an Application User with System Administrator role in every successfully-created environment using:
```
pac admin assign-user --environment <id> --user <app-id> --role "System Administrator" --application-user
```

**Command:**
```powershell
cd C:\automations\important
.\add-appuser-to-envs.ps1
```

**With custom parameters:**
```powershell
# Point to specific environment results
.\add-appuser-to-envs.ps1 -EnvResultsCsvPath "C:\automations\important\devenv-results.csv"

# Use a different output file
.\add-appuser-to-envs.ps1 -OutputCsvPath "C:\automations\important\appuser-registration-results.csv"

# Auto-confirm (skip Y/N prompt)
.\add-appuser-to-envs.ps1 -AutoConfirm

# Dry run
.\add-appuser-to-envs.ps1 -DryRun

# Resume from index 20
.\add-appuser-to-envs.ps1 -StartFromIndex 20

# Different application ID
.\add-appuser-to-envs.ps1 -ApplicationId "your-app-guid-here"
```

**Parameters:**
| Parameter | Default | Description |
|-----------|---------|-------------|
| `-ApplicationId` | `5e3e0b1b-dc41-4cab-a63f-ebcdea476f46` | Azure AD App (Client) ID GUID |
| `-EnvResultsCsvPath` | `C:\automations\important\devenv-results.csv` | Input: environment results from Step 1 |
| `-OutputCsvPath` | `C:\automations\important\appuser-registration-results.csv` | Output: registration results |
| `-MaxRetries` | `3` | Retry attempts per environment on failure |
| `-StartFromIndex` | `1` | Skip to this index (for resume) |
| `-DryRun` | `$false` | Preview mode, no actual registration |
| `-AutoConfirm` | `$false` | Skip Y/N confirmation prompt |

**Output**: `appuser-registration-results.csv` with columns:
```csv
EnvironmentId,EnvironmentName,UserEmail,ApplicationId,Status,Error,Timestamp
```

**Behavior:**
- Reads only `Status -eq "Success"` rows from the env results CSV
- No delay between successful operations (runs as fast as possible)
- Exponential backoff (30s → 60s → 120s → 240s) ONLY on errors
- **Auto-resume**: Re-running skips environments already successfully registered
- Detects "already exists" as success (idempotent)
- Takes ~10-12 seconds per environment

---

## Common Scenarios

### Scenario 1: Fresh batch of new users
```powershell
# 1. Edit users-devenv.csv with new user emails
# 2. Create environments
.\create-devenvs-onbehalf.ps1 -UserCsvPath "C:\automations\important\users-devenv.csv" -AutoConfirm

# 3. Add app user to all created environments
.\add-appuser-to-envs.ps1 -AutoConfirm
```

### Scenario 2: Environments already exist, just need app user
If environments were already created (you can see them in `pac env list`), you need to build the devenv-results CSV first. Ask Copilot to:
> "Get environment IDs for the users in users-devenv.csv from pac env list and create a devenv-results CSV, then run add-appuser-to-envs.ps1"

The approach:
1. Run `pac env list` to get all environments
2. Match user numbers from email (e.g., `odl_user_2154166` → `ODL_User 2154166's Environment`)
3. Build a CSV with columns: `UserEmail,EnvironmentName,Status,EnvironmentId,Error,Timestamp`
4. Run `add-appuser-to-envs.ps1` pointing to that CSV

**Quick PowerShell to build the CSV from existing environments:**
```powershell
# Get all environments
$envOutput = pac env list 2>&1
$envMap = @{}
foreach ($line in $envOutput) {
    if ($line -match "ODL_User\s+(\d+)'s Environment\s+([0-9a-f\-]{36})") {
        $envMap[$Matches[1]] = $Matches[2]
    }
}

# Match to users
$users = Import-Csv "C:\automations\important\users-devenv.csv"
$results = @()
foreach ($u in $users) {
    if ($u.UserEmail -match "odl_user_(\d+)@") {
        $num = $Matches[1]
        if ($envMap.ContainsKey($num)) {
            $results += [PSCustomObject]@{
                UserEmail       = $u.UserEmail
                EnvironmentName = "ODL_User ${num}'s Environment"
                Status          = "Success"
                EnvironmentId   = $envMap[$num]
                Error           = ""
                Timestamp       = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
            }
        }
    }
}
$results | Export-Csv -Path "C:\automations\important\devenv-results.csv" -NoTypeInformation -Encoding UTF8
Write-Host "Matched $($results.Count) environments"
```

Then run:
```powershell
.\add-appuser-to-envs.ps1 -EnvResultsCsvPath "C:\automations\important\devenv-results.csv" -AutoConfirm
```

### Scenario 3: Script was interrupted / needs resume
Just re-run the same command. Both scripts auto-skip successfully completed items.

### Scenario 4: Using a separate output file for a different batch
```powershell
.\add-appuser-to-envs.ps1 `
    -EnvResultsCsvPath "C:\automations\important\devenv-results-batch2.csv" `
    -OutputCsvPath "C:\automations\important\appuser-registration-results-batch2.csv" `
    -AutoConfirm
```

---

## Important Notes

1. **Environment Naming Convention**: Each environment is named `"ODL_User <NUMBER>'s Environment"` where `<NUMBER>` is extracted from the email like `odl_user_2154166@...` → `2154166`

2. **Application ID**: The hardcoded default `5e3e0b1b-dc41-4cab-a63f-ebcdea476f46` is the Azure AD App Registration Client ID. This is NOT the Application ID URI. If using a different app, pass `-ApplicationId "your-guid"`.

3. **Tenant**: `cloudlabssandbox.onmicrosoft.com`

4. **Region**: `unitedstates` (default for Power Platform)

5. **Idempotency**: Both scripts are safe to re-run. They skip already-completed items.

6. **Rate Limits**: Power Platform APIs throttle aggressively. The scripts handle this with exponential backoff. If you see many throttle errors, increase `-DelayBetweenCreations` in Step 1.

7. **Crash Recovery**: Results are saved after each operation. If the process dies, just re-run.

8. **PAC CLI Commands Used**:
   - `pac admin create --name "..." --type Developer --user "..." --region "unitedstates"` (Step 1)
   - `pac admin assign-user --environment <id> --user <app-id> --role "System Administrator" --application-user` (Step 2)

---

## Troubleshooting

| Problem | Solution |
|---------|----------|
| "No auth profile found" | Run `pac auth create --name "LabAdmin"` |
| "pac not found" | Install PAC CLI from https://aka.ms/PowerAppsCLI |
| Many throttle errors | Increase `DelayBetweenCreations` to 20-30s |
| Environment creation fails with "already exists" | The user already has a dev env; script marks as success |
| App user "already registered" | Script marks as success and moves on |
| Script interrupted | Just re-run — it auto-resumes from where it left off |
| Wrong application ID error | Ensure you use the Application (Client) ID GUID, not the App ID URI |
| Need to check progress | Look at the output CSV file — rows are appended in real-time |

---

## CSV Format Reference

### Input CSV (users-devenv.csv / user-devenv2.csv)
```csv
UserEmail
odl_user_2154166@cloudlabssandbox.onmicrosoft.com
odl_user_2154168@cloudlabssandbox.onmicrosoft.com
```
- **One column**: `UserEmail`
- **No quotes needed** (PowerShell handles it)
- **No trailing commas or spaces**

### Output: devenv-results.csv
```csv
UserEmail,EnvironmentName,Status,EnvironmentId,Error,Timestamp
odl_user_2154166@cloudlabssandbox.onmicrosoft.com,ODL_User 2154166's Environment,Success,61506900-c98d-e5f7-a58d-cc5694186400,,2026-04-06 08:34:17
```

### Output: appuser-registration-results.csv
```csv
EnvironmentId,EnvironmentName,UserEmail,ApplicationId,Status,Error,Timestamp
61506900-c98d-e5f7-a58d-cc5694186400,ODL_User 2154166's Environment,odl_user_2154166@cloudlabssandbox.onmicrosoft.com,5e3e0b1b-dc41-4cab-a63f-ebcdea476f46,Success,,2026-04-06 09:31:52
```

---

## TL;DR for Copilot Agents

When a user says "create dev environments and add app user for these users":

1. Ensure `users-devenv.csv` has the user emails (header: `UserEmail`)
2. Run: `.\create-devenvs-onbehalf.ps1 -UserCsvPath "C:\automations\important\users-devenv.csv" -AutoConfirm`
3. Wait for completion
4. Run: `.\add-appuser-to-envs.ps1 -AutoConfirm`

When a user says "environments already exist, just add app user":

1. Run `pac env list` to get environment IDs
2. Match user emails to environment IDs using the naming pattern
3. Build `devenv-results.csv` with matched data
4. Run: `.\add-appuser-to-envs.ps1 -EnvResultsCsvPath "<path-to-csv>" -AutoConfirm`

When a user says "use a different batch/file":
- Pass `-UserCsvPath`, `-EnvResultsCsvPath`, and `-OutputCsvPath` to point to the right files
- Use different output paths to avoid overwriting previous batch results
