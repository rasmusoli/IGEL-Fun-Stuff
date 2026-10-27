# UMS Login UPN Suffix

Add a default UPN suffix to the IGEL UMS login page, with a **Use username as entered** checkbox for local accounts or other usernames that should remain unchanged.

The script derives the suffix from the UPN of the Windows account running it (`whoami /upn`). Running it as `admininitials@sub.domain.local` configures `@sub.domain.local` as the login page default for all users. It does not change Active Directory accounts or UPN attributes.

This is an independent customization of the installed UMS login template, not an official IGEL feature. The original login modification was confirmed working on the investigated installation using `login-ui-resource-12.14.103.jar`. The later menu, backup/restore, and service-control additions were checked with local test archives and mocked services; validate service detection on your server using Dry run.

## Files

- [Set-UmsLoginSuffix.ps1](Set-UmsLoginSuffix.ps1): interactive menu and command-line actions.
- `ums-login-backups/`: created locally when adding or restoring; excluded from Git.

## Requirements

- Run locally on the Windows UMS server with PowerShell 5.1 or later.
- Use an elevated PowerShell window for Add and Restore.
- Run Add and Dry run as a domain account whose UPN has the desired suffix. **Run as different user** changes which account supplies the suffix. Restore does not require UPN discovery.
- Allow a UMS service interruption when applying or restoring. The script stops the detected service and restarts it only if it was running beforehand.
- Keep backups outside the UMS `webapps` directory.

The default target is:

```text
C:\Program Files\IGEL\RemoteManager\rmguiserver\webapps\auth-service\WEB-INF\lib\login-ui-resource-12.14.103.jar
```

Only `templates/login.html` inside that JAR is modified. The script checks the expected template structure and rejects signed JARs or duplicate archive entries. Other versions need inspection and validation before use; changing the filename alone does not establish compatibility.

## Quick start

1. Copy this folder to the UMS server, for example `C:\temp\UMS-Login-Suffix`.
2. If you used an earlier version, retain its complete `ums-login-backups` folder beside the script, or supply its existing location with `-BackupDirectory`.
3. Open PowerShell as administrator under the appropriate domain account.
4. Launch the menu:

```powershell
Set-Location 'C:\temp\UMS-Login-Suffix'
.\Set-UmsLoginSuffix.ps1
```

```text
1 - Dry run
2 - Add UPNs
3 - Restore Original Backup
0 - Exit
```

Start with **Dry run**, check the service and suffix, then select **Add UPNs**. After UMS finishes starting, reload the login page.

## Menu actions

### Dry run

Displays the running account UPN, derived suffix, example username transformation, target JAR and template, backup location, service name, executable, current PID, and planned stop/restart actions. It checks template/archive compatibility for an unpatched installation and checks whether a matching original backup is available for a patched installation.

Dry run writes no files and changes no services. It does not prove that the account has permission to stop the service or replace the JAR. If the template is already patched, Add is reported as a no-op and the installed suffix is shown.

### Add UPNs

Stops the identified UMS service if running, then:

1. Copies the original JAR to a unique backup directory and verifies its SHA-256 hash.
2. Creates and patches a separate candidate copy.
3. Verifies that all archive entries except `templates/login.html` remain unchanged.
4. Saves a manifest containing paths, suffix, and hashes.
5. Stages the candidate beside the installed JAR and replaces the JAR atomically.
6. Verifies the installed hash and restarts the service if it was previously running.

An already patched template is left unchanged. To change the suffix, restore the original first and run Add under the account with the desired UPN suffix.

### Restore Original Backup

Finds a backup manifest whose target path and patched hash match the currently installed JAR, verifies the original backup hash, and confirms that its login template is unpatched. It saves the current patched JAR before restoring the original. Service handling is the same as Add.

Restoration refuses a missing, altered, or nonmatching backup. This also prevents automatically restoring an old JAR over an upgraded or otherwise modified installation. Keep the original `.original` file and its `manifest.json` together. Backups produced by the earlier script are supported when the installed JAR still matches their manifest.

## Login behaviour

For a configured suffix of `sub.domain.local`:

| Entered username | Use username as entered | Submitted username |
| --- | --- | --- |
| `admininitials` | Unchecked | `admininitials@sub.domain.local` |
| `administrator` | Checked | `administrator` |
| `admininitials@other.domain` | Either | Unchanged |
| `DOMAIN\admininitials` | Either | Unchanged |

Preserving a username format does not mean the UMS backend accepts it. Blank usernames are not suffixed. The checkbox starts unchecked on page load. The password is not modified. Username rewriting happens in the internal form's `formdata` handler, so it applies to both Login clicks and Enter submission without changing the visible input.

## Command-line actions

```powershell
.\Set-UmsLoginSuffix.ps1 -Action DryRun
.\Set-UmsLoginSuffix.ps1 -Action Add
.\Set-UmsLoginSuffix.ps1 -Action Restore
```

Override paths if needed:

```powershell
.\Set-UmsLoginSuffix.ps1 `
    -JarPath 'D:\IGEL\RemoteManager\rmguiserver\webapps\auth-service\WEB-INF\lib\login-ui-resource-12.14.103.jar' `
    -BackupDirectory 'D:\UMS-Backups\LoginSuffix'
```

If automatic service detection fails or is ambiguous, inspect the installed services:

```powershell
Get-CimInstance Win32_Service |
    Where-Object { $_.PathName -like '*IGEL*' -or $_.DisplayName -like '*IGEL*' } |
    Select-Object Name, DisplayName, State, ProcessId, PathName |
    Format-List
```

Then pass the exact service **Name** that owns this UMS installation:

```powershell
.\Set-UmsLoginSuffix.ps1 -ServiceName '<exact UMS service Name>'
```

The script does not kill processes directly or force-stop dependent services. Active dependent services block Add/Restore. A service already stopped is left stopped. The service restart is attempted in a `finally` block, including when the file operation fails; check both the reported error and service status after a failure. A running Windows service does not by itself confirm that UMS has finished starting.

The earlier `-PrepareOnly` option is also available:

```powershell
.\Set-UmsLoginSuffix.ps1 -PrepareOnly
```

Unlike Dry run, PrepareOnly creates a verified original backup, patched candidate, and manifest. It does not stop services or replace the installed JAR. Its displayed service plan describes the eventual Add operation.

## Validation and upgrades

After applying, verify the displayed suffix and test a short LDAP username, a full UPN, and a local account with the checkbox selected. Check both Login clicks and Enter. After restoring, confirm the original login page is back.

UMS upgrades may replace the JAR or change the template and component implementation. Reinspect the new installation before reapplying, and retain version-specific backups. Do not copy a backup JAR from an older UMS version over a newer installation.

Local development checks covered PowerShell parsing, dry runs without writes, repeated Add as a no-op, archive-entry preservation, exact original restoration, corrupt-backup rejection, and simulated service stop/work/start ordering. Live operation of the menu's service detection and stop/restart flow remains deployment-specific.
