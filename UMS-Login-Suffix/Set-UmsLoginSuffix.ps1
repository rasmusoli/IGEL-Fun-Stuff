#requires -Version 5.1
<#
.SYNOPSIS
Adds an optional default UPN suffix to the UMS login template.
.DESCRIPTION
The suffix comes from whoami /upn. The menu offers a read-only dry run,
installation, and verified restoration of an original backup.
Backs up the original JAR outside the webapp, patches a temporary copy, verifies
every archive entry, then replaces the installed JAR with the UMS service stopped.
Only services running before the operation are restarted.
#>
[CmdletBinding()]
param(
    [string]$JarPath,
    [string]$UmsPath,
    [string]$BackupDirectory = (Join-Path $PSScriptRoot 'ums-login-backups'),
    [ValidateSet('Menu','DryRun','Add','Restore')]
    [string]$Action = 'Menu',
    [string]$ServiceName,
    [switch]$PrepareOnly
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression.FileSystem

function Resolve-LoginJar([string]$InstallationPath, [string]$ExplicitJarPath) {
    if ($InstallationPath -and $ExplicitJarPath) { throw 'Specify either -UmsPath or -JarPath, not both.' }
    if ($ExplicitJarPath) {
        $file = Get-Item -LiteralPath $ExplicitJarPath
        if ($file.PSIsContainer -or $file.Name -notlike 'login-ui-resource-*.jar') {
            throw '-JarPath must name a login-ui-resource-*.jar file.'
        }
        return $file.FullName
    }
    $relativeLib = 'rmguiserver\webapps\auth-service\WEB-INF\lib'
    if (-not $InstallationPath) {
        # Prefer native Program Files even when launched from 32-bit PowerShell.
        $programFilesRoot = $env:ProgramW6432
        if (-not $programFilesRoot) { $programFilesRoot = $env:ProgramFiles }
        if (-not $programFilesRoot) { throw 'Cannot determine Program Files. Supply -UmsPath.' }
        $defaultPath = Join-Path $programFilesRoot 'IGEL\RemoteManager'
        if (Test-Path -LiteralPath (Join-Path $defaultPath $relativeLib) -PathType Container) {
            $InstallationPath = $defaultPath
        } else {
            Write-Host "Default UMS instance not found: $defaultPath"
            $InstallationPath = (Read-Host 'Enter the UMS RemoteManager installation directory (blank cancels)').Trim().Trim('"')
            if (-not $InstallationPath) { throw 'UMS path selection cancelled.' }
        }
    }
    $root = Get-Item -LiteralPath $InstallationPath
    if (-not $root.PSIsContainer) { throw '-UmsPath must be the RemoteManager installation directory.' }
    $lib = Join-Path $root.FullName $relativeLib
    if (-not (Test-Path -LiteralPath $lib -PathType Container)) { throw "UMS auth-service library directory not found: $lib" }
    $jars = @(Get-ChildItem -LiteralPath $lib -Filter 'login-ui-resource-*.jar' -File)
    if ($jars.Count -eq 0) { throw "No login-ui-resource-*.jar found in $lib" }
    if ($jars.Count -gt 1) {
        throw "Multiple login resource JARs found: $($jars.Name -join ', '). Supply -JarPath with the exact intended file; no version is selected automatically."
    }
    return $jars[0].FullName
}

function New-LoginTemplate([string]$Template, [string]$Suffix) {
    if ($Template.Contains('UMS-UPN-SUFFIX-PATCH-v1')) {
        throw 'This template is already patched. Restore the original before changing the suffix.'
    }
    if ($Suffix -notmatch '^[A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?$') {
        throw 'The UPN suffix contains unsupported characters.'
    }
    $anchor = "fields = JSON.parse(spikeLoginFrom.getAttribute('fields'));"
    foreach ($required in @($anchor, 'nonce="NONCE_PLACEHOLDER"', 'th:formAction="@{/login}"')) {
        if (-not $Template.Contains($required)) { throw "Unexpected template: missing $required" }
    }
    if (($Template.Split(@($anchor), [StringSplitOptions]::None).Count - 1) -ne 1) {
        throw 'Expected exactly one fields initialization.'
    }
    $fieldPatch = @'

            // UMS-UPN-SUFFIX-PATCH-v1
            fields.splice(1, 0, {
                id: 'umsUseExactUsername',
                type: 'checkbox',
                label: 'Use username as entered (do not append @__SUFFIX__)',
                checked: false,
                testingId: 'login_exact_username'
            });
'@
    $scriptPatch = @'

    <script nonce="NONCE_PLACEHOLDER">
        // UMS-UPN-SUFFIX-PATCH-v1: change only the outgoing username.
        window.addEventListener('load', async () => {
            const builder = document.getElementById('loginForm');
            await customElements.whenDefined('spike-form-builder');
            await builder.updateComplete;
            const form = builder.shadowRoot && builder.shadowRoot.querySelector('form');
            if (!form) {
                console.error('UMS suffix customization unavailable; enter a full UPN.');
                return;
            }
            form.addEventListener('formdata', event => {
                const checkbox = builder.shadowRoot.getElementById('umsUseExactUsername');
                const username = event.formData.get('username');
                if (checkbox && !checkbox.checked && typeof username === 'string' &&
                    username.trim() !== '' && !username.includes('@') && !username.includes('\\')) {
                    event.formData.set('username', username + '@__SUFFIX__');
                }
                event.formData.delete('umsUseExactUsername');
            });
        });
    </script>
'@
    if (($Template.Split(@('</head>'), [StringSplitOptions]::None).Count - 1) -ne 1) {
        throw 'Expected exactly one closing head tag.'
    }
    $result = $Template.Replace($anchor, $anchor + $fieldPatch.Replace('__SUFFIX__', $Suffix))
    return $result.Replace('</head>', $scriptPatch.Replace('__SUFFIX__', $Suffix) + "`r`n</head>")
}

function Read-Template([string]$Path) {
    $zip = [IO.Compression.ZipFile]::OpenRead($Path)
    try {
        $entry = $zip.GetEntry('templates/login.html')
        if ($null -eq $entry) { throw 'templates/login.html was not found.' }
        $reader = [IO.StreamReader]::new($entry.Open())
        try { return $reader.ReadToEnd() } finally { $reader.Dispose() }
    } finally { $zip.Dispose() }
}

function Get-ArchiveManifest([string]$Path) {
    $zip = [IO.Compression.ZipFile]::OpenRead($Path)
    $manifest = @{}
    try {
        foreach ($entry in $zip.Entries) {
            if ($manifest.ContainsKey($entry.FullName)) { throw "Duplicate archive entry: $($entry.FullName)" }
            if ($entry.FullName -match '^META-INF/.*\.(SF|RSA|DSA|EC)$') {
                throw 'Signed JAR detected; this script will not invalidate its signature.'
            }
            $stream = $entry.Open()
            $sha = [Security.Cryptography.SHA256]::Create()
            try { $manifest[$entry.FullName] = [BitConverter]::ToString($sha.ComputeHash($stream)) }
            finally { $sha.Dispose(); $stream.Dispose() }
        }
    } finally { $zip.Dispose() }
    return $manifest
}

function Invoke-AddCore([string]$suffix) {
$originalText = Read-Template $JarPath
$patchedText = New-LoginTemplate $originalText $suffix
$originalManifest = Get-ArchiveManifest $JarPath
$originalHash = (Get-FileHash -LiteralPath $JarPath -Algorithm SHA256).Hash
$runId = (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + [Guid]::NewGuid().ToString('N').Substring(0,8)
$runDirectory = Join-Path $BackupDirectory $runId
$null = New-Item -ItemType Directory -Path $runDirectory
$backupPath = Join-Path $runDirectory ([IO.Path]::GetFileName($JarPath) + '.original')
Copy-Item -LiteralPath $JarPath -Destination $backupPath
if ((Get-FileHash -LiteralPath $backupPath -Algorithm SHA256).Hash -ne $originalHash) {
    throw 'Backup verification failed. Installed JAR was not modified.'
}
Write-Host "Verified original backup: $backupPath"
Write-Host "Default UPN suffix: @$suffix"

$candidate = Join-Path $runDirectory ([IO.Path]::GetFileName($JarPath) + '.patched')
Copy-Item -LiteralPath $backupPath -Destination $candidate
$zip = [IO.Compression.ZipFile]::Open($candidate, [IO.Compression.ZipArchiveMode]::Update)
try {
    $zip.GetEntry('templates/login.html').Delete()
    $entry = $zip.CreateEntry('templates/login.html')
    $writer = [IO.StreamWriter]::new($entry.Open(), [Text.UTF8Encoding]::new($false))
    try { $writer.Write($patchedText) } finally { $writer.Dispose() }
} finally { $zip.Dispose() }

$patchedManifest = Get-ArchiveManifest $candidate
if ($patchedManifest.Count -ne $originalManifest.Count) { throw 'Archive entry count changed unexpectedly.' }
foreach ($name in $originalManifest.Keys) {
    if (-not $patchedManifest.ContainsKey($name)) { throw "Missing archive entry: $name" }
    if ($name -ne 'templates/login.html' -and $originalManifest[$name] -ne $patchedManifest[$name]) {
        throw "Unexpected modification: $name"
    }
}
if ((Read-Template $candidate) -cne $patchedText) { throw 'Patched template verification failed.' }
$candidateHash = (Get-FileHash -LiteralPath $candidate -Algorithm SHA256).Hash
[ordered]@{
    OriginalPath = $JarPath; BackupPath = $backupPath; CandidatePath = $candidate
    OriginalSHA256 = $originalHash; PatchedSHA256 = $candidateHash
    Suffix = $suffix; Created = (Get-Date).ToString('o')
} | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $runDirectory 'manifest.json') -Encoding UTF8

if ($PrepareOnly) {
    Write-Host "Verified candidate: $candidate"
    Write-Host 'PrepareOnly: installed JAR unchanged. Run again without -PrepareOnly to apply.'
    return
}

# Stage on the same volume for an atomic replacement. Never edit the live ZIP in place.
$staging = Join-Path (Split-Path -Parent $JarPath) ('.ums-login-' + $runId + '.tmp')
try {
    Copy-Item -LiteralPath $candidate -Destination $staging
    if ((Get-FileHash -LiteralPath $staging -Algorithm SHA256).Hash -ne $candidateHash) { throw 'Staging verification failed.' }
    if ((Get-FileHash -LiteralPath $JarPath -Algorithm SHA256).Hash -ne $originalHash) {
        throw 'Installed JAR changed during preparation. Aborting replacement.'
    }
    [IO.File]::Replace($staging, $JarPath, [NullString]::Value)
} finally {
    if (Test-Path -LiteralPath $staging) { Remove-Item -LiteralPath $staging }
}
if ((Get-FileHash -LiteralPath $JarPath -Algorithm SHA256).Hash -ne $candidateHash) {
    throw "Installed hash mismatch. Keep UMS stopped and restore $backupPath"
}
Write-Host 'Patch installed and verified.'
Write-Host 'Rollback: stop UMS, then restore the original with:'
Write-Host ("Copy-Item -LiteralPath '{0}' -Destination '{1}' -Force" -f $backupPath.Replace("'", "''"), $JarPath.Replace("'", "''"))

}

function Get-CurrentSuffix {
    $upnOutput = & whoami.exe /upn 2>$null
    if ($LASTEXITCODE -ne 0) { throw 'Cannot determine UPN. Run this script as a domain user.' }
    $upn = ($upnOutput | Out-String).Trim()
    if ($upn -notmatch '^[^@\s]+@([^@\s]+)$') { throw 'The current account did not return a valid UPN.' }
    return [pscustomobject]@{ UPN = $upn; Suffix = $Matches[1] }
}

function Get-UmsService {
    $services = @(Get-CimInstance Win32_Service)
    if ($ServiceName) {
        $selected = @($services | Where-Object { $_.Name -eq $ServiceName })
    } else {
        $index = $JarPath.IndexOf('\rmguiserver\', [StringComparison]::OrdinalIgnoreCase)
        if ($index -lt 0) { throw 'Cannot infer installation root. Supply -ServiceName with the exact UMS service name.' }
        $root = $JarPath.Substring(0, $index) + '\'
        $selected = @($services | Where-Object {
            $_.PathName -and $_.PathName.IndexOf($root, [StringComparison]::OrdinalIgnoreCase) -ge 0 -and
            ($_.PathName -match 'rmguiserver' -or $_.Name -match '^IGELRMServer$' -or
             $_.DisplayName -match 'IGEL.*Universal Management Suite')
        })
    }
    if ($selected.Count -ne 1) {
        throw 'UMS service detection was not unambiguous. Supply -ServiceName with the exact UMS service name; no services were changed.'
    }
    return $selected[0]
}

function Get-RestoreBackup {
    $currentHash = (Get-FileHash -LiteralPath $JarPath -Algorithm SHA256).Hash
    if (-not (Test-Path -LiteralPath $BackupDirectory)) { throw 'No backup directory exists.' }
    foreach ($file in (Get-ChildItem -LiteralPath $BackupDirectory -Filter manifest.json -Recurse -File | Sort-Object FullName -Descending)) {
        $record = Get-Content -LiteralPath $file.FullName -Raw | ConvertFrom-Json
        if ($record.OriginalPath -ne $JarPath -or $record.PatchedSHA256 -ne $currentHash) { continue }
        # Resolve the original beside its manifest, so the backup folder can be moved.
        $original = Join-Path $file.DirectoryName ([IO.Path]::GetFileName($JarPath) + '.original')
        if (-not (Test-Path -LiteralPath $original)) { continue }
        if ((Get-FileHash -LiteralPath $original -Algorithm SHA256).Hash -ne $record.OriginalSHA256) {
            throw "Original backup failed SHA-256 verification: $original"
        }
        if ((Read-Template $original).Contains('UMS-UPN-SUFFIX-PATCH-v1')) { throw 'Backup is not an unpatched original.' }
        return [pscustomobject]@{ Path = $original; Hash = $record.OriginalSHA256; CurrentHash = $currentHash }
    }
    throw 'No verified original backup matches the installed patched JAR. No restoration will be attempted.'
}

function Invoke-RestoreCore($Backup) {
    $runId = (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + [Guid]::NewGuid().ToString('N').Substring(0,8)
    $folder = Join-Path $BackupDirectory ('restore-' + $runId)
    $null = New-Item -ItemType Directory -Path $folder
    $saved = Join-Path $folder ([IO.Path]::GetFileName($JarPath) + '.before-restore')
    Copy-Item -LiteralPath $JarPath -Destination $saved
    if ((Get-FileHash -LiteralPath $saved -Algorithm SHA256).Hash -ne $Backup.CurrentHash) { throw 'Pre-restore backup verification failed.' }
    if ((Get-FileHash -LiteralPath $Backup.Path -Algorithm SHA256).Hash -ne $Backup.Hash) { throw 'Original backup changed.' }
    $staging = Join-Path (Split-Path -Parent $JarPath) ('.ums-restore-' + $runId + '.tmp')
    try {
        Copy-Item -LiteralPath $Backup.Path -Destination $staging
        if ((Get-FileHash -LiteralPath $staging -Algorithm SHA256).Hash -ne $Backup.Hash) { throw 'Restore staging verification failed.' }
        if ((Get-FileHash -LiteralPath $JarPath -Algorithm SHA256).Hash -ne $Backup.CurrentHash) { throw 'Installed JAR changed. Restoration aborted.' }
        [IO.File]::Replace($staging, $JarPath, [NullString]::Value)
    } finally {
        if (Test-Path -LiteralPath $staging) { Remove-Item -LiteralPath $staging }
    }
    if ((Get-FileHash -LiteralPath $JarPath -Algorithm SHA256).Hash -ne $Backup.Hash) { throw 'Restored JAR hash mismatch.' }
    Write-Host "Original restored and verified: $($Backup.Path)"
    Write-Host "Previous patched JAR retained: $saved"
}

function Show-Plan([string]$Operation, $Service, $Identity, $Backup, [bool]$NoChanges = $false) {
    Write-Host "`nOperation: $Operation"
    Write-Host "JAR: $JarPath"
    Write-Host 'Archive entry changed by Add: templates/login.html'
    Write-Host "Backups: $BackupDirectory (timestamped subdirectory, SHA-256 verified)"
    Write-Host 'Apply/restore also stages a temporary .tmp file beside the JAR, then removes it.'
    if ($Identity) {
        Write-Host "Running account UPN: $($Identity.UPN)"
        Write-Host "Default suffix: @$($Identity.Suffix)"
        Write-Host "Example: admininitials -> admininitials@$($Identity.Suffix)"
        Write-Host 'UI: add unchecked Use username as entered checkbox.'
        Write-Host 'Checked: preserve username. Full UPNs and DOMAIN\user values are preserved.'
        Write-Host 'No directory accounts or AD UPN attributes are modified.'
    }
    if ($Backup) { Write-Host "Original to restore: $($Backup.Path)" }
    Write-Host "Service: $($Service.Name) [$($Service.DisplayName)]"
    Write-Host "Service executable: $($Service.PathName)"
    Write-Host "State: $($Service.State); current process ID: $($Service.ProcessId)"
    if ($NoChanges) {
        Write-Host 'Add actions: none; already patched. No service stop or restart.'
    } elseif ($Service.State -eq 'Running') {
        Write-Host 'Actions: stop this service, change the JAR, restart this service.'
    } elseif ($Service.State -eq 'Stopped') {
        Write-Host 'Actions: change the JAR; leave this service stopped.'
    } else { Write-Host 'BLOCKED: service must be Running or Stopped.' }
    Write-Host 'No processes are killed directly; Stop-Service is used without -Force.'
}

function Assert-Administrator {
    $principal = [Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Run PowerShell as administrator to apply or restore.'
    }
}

function Invoke-WithUmsStopped($Service, [scriptblock]$Work) {
    Assert-Administrator
    $controller = Get-Service -Name $Service.Name
    $controller.Refresh()
    if ($controller.Status -notin @('Running','Stopped')) { throw 'Service must be Running or Stopped.' }
    $runningDependents = @($controller.DependentServices | Where-Object { $_.Status -ne 'Stopped' })
    if ($runningDependents.Count) { throw "Stop dependent services first: $($runningDependents.Name -join ', ')" }
    $restart = $controller.Status -eq 'Running'
    try {
        if ($restart) {
            Write-Host "Stopping $($Service.Name)..."
            Stop-Service -Name $Service.Name -ErrorAction Stop
            $controller.WaitForStatus('Stopped', [TimeSpan]::FromSeconds(60))
        }
        & $Work
    } finally {
        if ($restart) {
            $controller.Refresh()
            if ($controller.Status -eq 'StopPending') { $controller.WaitForStatus('Stopped', [TimeSpan]::FromSeconds(60)) }
            if ($controller.Status -eq 'Stopped') {
                Write-Host "Starting $($Service.Name)..."
                Start-Service -Name $Service.Name -ErrorAction Stop
                $controller.WaitForStatus('Running', [TimeSpan]::FromSeconds(60))
                Write-Host 'Service is running. Reload the login page after UMS finishes starting.'
            }
        }
    }
}

function Invoke-Choice([string]$Choice) {
    $service = Get-UmsService
    $template = Read-Template $JarPath
    $isPatched = $template.Contains('UMS-UPN-SUFFIX-PATCH-v1')
    if ($Choice -eq 'Restore') {
        $backup = Get-RestoreBackup
        Show-Plan 'Restore Original Backup' $service $null $backup
        Invoke-WithUmsStopped $service { Invoke-RestoreCore $backup }
        return
    }
    $identity = Get-CurrentSuffix
    if ($Choice -eq 'DryRun') {
        Show-Plan 'Dry run / Add UPNs' $service $identity $null $isPatched
        if ($isPatched) {
            $installedSuffix = [regex]::Match($template, "username \+ '@([^']+)'").Groups[1].Value
            Write-Host "Installed suffix: @$installedSuffix"
            Write-Host 'Add: no change; login template is already patched. Restore first to change the suffix.'
            try {
                $backup = Get-RestoreBackup
                Write-Host "Restore available: $($backup.Path)"
                if ($service.State -eq 'Running') { Write-Host 'Restore would stop and restart the service listed above, saving the current JAR first.' }
                else { Write-Host 'Restore would save the current JAR first and leave the stopped service stopped.' }
            } catch { Write-Host "Restore unavailable: $($_.Exception.Message)" }
        } else {
            $null = New-LoginTemplate $template $identity.Suffix
            $null = Get-ArchiveManifest $JarPath
            Write-Host 'Template and archive checks passed. Add would create an original backup, candidate and manifest.json.'
        }
        $dependents = @((Get-Service -Name $service.Name).DependentServices | Where-Object { $_.Status -ne 'Stopped' })
        if ($dependents.Count) { Write-Host "BLOCKED by active dependent services: $($dependents.Name -join ', ')" }
        Write-Host 'Dry run complete: no files written and no services changed.'
        return
    }
    if ($isPatched) { Write-Host 'Already patched. Restore Original Backup before changing the suffix.'; return }
    $null = New-LoginTemplate $template $identity.Suffix
    $null = Get-ArchiveManifest $JarPath
    Show-Plan 'Add UPNs' $service $identity $null
    if ($PrepareOnly) { Invoke-AddCore $identity.Suffix }
    else { Invoke-WithUmsStopped $service { Invoke-AddCore $identity.Suffix } }
}

$JarPath = Resolve-LoginJar -InstallationPath $UmsPath -ExplicitJarPath $JarPath
Write-Host "Discovered login resource: $JarPath"
$BackupDirectory = [IO.Path]::GetFullPath($BackupDirectory)
$webappsIndex = $JarPath.IndexOf('\webapps\', [StringComparison]::OrdinalIgnoreCase)
if ($webappsIndex -ge 0) {
    $webappsRoot = $JarPath.Substring(0, $webappsIndex + '\webapps\'.Length)
    if (($BackupDirectory.TrimEnd('\') + '\').StartsWith($webappsRoot, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Choose a backup directory outside webapps.'
    }
}
if ($PrepareOnly -and $Action -eq 'Menu') { $Action = 'Add' }
if ($PrepareOnly -and $Action -ne 'Add') { throw '-PrepareOnly is only valid with Add.' }
if ($Action -ne 'Menu') { Invoke-Choice $Action; return }
while ($true) {
    Write-Host "`nUMS login customization"
    Write-Host '1 - Dry run'
    Write-Host '2 - Add UPNs'
    Write-Host '3 - Restore Original Backup'
    Write-Host '0 - Exit'
    $choice = Read-Host 'Select an option'
    if ($choice -eq '0') { break }
    try {
        switch ($choice) {
            '1' { Invoke-Choice 'DryRun' }
            '2' { Invoke-Choice 'Add' }
            '3' { Invoke-Choice 'Restore' }
            default { Write-Host 'Select 1, 2, 3 or 0.' }
        }
    } catch { Write-Host "Operation failed: $($_.Exception.Message)" -ForegroundColor Red }
}
