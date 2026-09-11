# IGEL UMS ACL Generator

A small PowerShell utility for generating guarded SQL statements that assign a predefined IGEL UMS folder ACL to an imported Active Directory group.

The tool is intended to reduce repetitive manual permission configuration when the same administrator permission set needs to be applied to many AD groups across different parts of an IGEL UMS device hierarchy.

> **Important:** This project uses an internal UMS database representation and is **not an IGEL-supported or IGEL-endorsed way of managing UMS permissions**. Use it only in environments where you understand and accept the risks of direct database changes. Test it against your exact UMS version before wider use.

## Why this exists

In a typical delegated administration setup, AD groups are imported into UMS through LDAP or LDAPS. The group then needs to be given object permissions on the appropriate UMS device folder.

UMS does not currently provide the desired reusable role model for object permissions, where a reusable permission definition can be assigned independently to a group and a folder.

The desired model is essentially:

```text
AD group + reusable role + folder scope

Example:

SITE-A-IT       -> Supporter -> Devices/Site-A
SITE-B-IT       -> Supporter -> Devices/Site-B
SITE-C-IT       -> Supporter -> Devices/Site-C
```

Without a reusable object-permission role, an administrator normally has to open the permissions page and manually select the required permissions for every new group and scope.

That becomes increasingly error-prone as the number of sites, groups and delegated folders grows. The same baseline can easily be configured slightly differently by different administrators, resulting in missing access or excessive access.

This project is a workaround for that problem.

## What the workaround does

The tool does not create a real UMS role. Instead, it uses a previously validated permission vector and generates the SQL required to create the corresponding ACL entry for a selected group and folder.

In the tested UMS 12.13.110 environment, the ACL permission state is represented in the `ACE` table by a positional string. The observed format contains 43 positions:

```text
A = Allow
D = Deny
- = Not Set
```

Our validated Supporter baseline is currently:

```text
AA---------AAAAAAAAAA--AA--A---AA-----A-A--
```

The permission string is treated as a version-specific template. The tool also checks for the expected UMS schema version before generating a statement for that version.

The basic workflow is:

```text
AD sAMAccountName
        |
        v
LDAP lookup
        |
        v
Distinguished Name
        |
        +--------------------+
        |                    |
        v                    v
UMS folder path       Supporter ACL template
        |                    |
        +---------+----------+
                  |
                  v
             Generated SQL
                  |
                  v
        UMS Java Console SQL Console
                  |
                  v
             ACE entry
```

## What the script does

The current PowerShell script:

1. Collects the AD group and exact UMS folder hierarchy through a small Windows Forms GUI.
2. Resolves the group's distinguished name from its `sAMAccountName` using `System.DirectoryServices`.
3. Builds the UMS folder path from the supplied hierarchy.
4. Generates a single SQL statement for the UMS SQL Console.
5. Includes checks for:
   - expected UMS schema version
   - missing or ambiguous folder matches
   - missing or ambiguous trustee group matches
   - an existing ACE for the same object and trustee
6. Saves the generated SQL to the Windows desktop.
7. Opens the statement in a review window so it can be inspected and copied into the UMS SQL Console.

The script does **not** connect to the UMS database itself. SQL execution is a deliberate manual step performed by the administrator in the UMS Java Console.

## Requirements

### Client

- Windows
- Windows PowerShell 5.1 or later
- .NET Framework components available to PowerShell 5.1
- Access to Active Directory through LDAP/LDAPS
- `System.DirectoryServices`

The script does not require the ActiveDirectory PowerShell module.

### UMS

- Access to the UMS Java Console
- Permission to use the built-in UMS SQL Console
- A tested UMS database version matching the permission template used by the script

The current script is explicitly guarded for UMS schema version:

```text
12.13
```

The tested environment is UMS 12.13.110. The permission string should **not** be assumed to be compatible with another UMS release without validation.

## Files

```text
New-IgelUmsAclSql.ps1   Main PowerShell utility
README.md               This documentation
```

## Configuration

Open the script and review the environment configuration section near the top:

```powershell
$Domain = 'domain.local'
$DefaultRootFolder = 'Devices'
```

`$Domain` should be the AD DNS domain or a domain controller hostname that can be used for the LDAP lookup.

`$DefaultRootFolder` must be the **first real directory stored in the UMS `DIRECTORIES` table**, not a virtual label shown elsewhere in the user interface.

For example, depending on the UMS folder structure it could be a root such as:

```text
NOVOPROD
```

or:

```text
LAB
```

Use the exact value that exists in your UMS database.

Folder names are case-sensitive in the generated SQL.

## Using the GUI

Run the script normally:

```powershell
.\New-IgelUmsAclSql.ps1
```

The GUI asks for the following values.

### AD group sAMAccountName

Enter only the group's `sAMAccountName`.

Example:

```text
DOT-Admins
```

The script performs the LDAP lookup automatically and resolves the group's distinguished name.

### UMS root folder

The first real UMS directory in the path.

Example:

```text
LAB
```

### Country

The next folder level in the UMS hierarchy.

Example:

```text
DENMARK
```

### Site

The site folder.

Example:

```text
CPH
```

### Building

Optional. Leave blank when the building level is not used.

Example:

```text
FAB1
```

### Line

Optional. A line can only be supplied when a building is supplied.

Example:

```text
Line-01
```

Once the required values are entered, select **Generate SQL**.

The script resolves the group, creates the folder path, and displays the generated SQL for review and copying.

## Example

Suppose the AD group is:

```text
DOT-Admins
```

and the UMS hierarchy is:

```text
LAB / DENMARK / CPH / FAB1
```

The resulting target is conceptually:

```text
DOT-Admins
    -> LAB/DENMARK/CPH/FAB1
    -> Supporter baseline
```

The generated SQL then resolves the corresponding UMS trustee ID and directory ID and prepares an ACE entry using the predefined permission vector.

## Command-line mode

The script also supports non-GUI execution.

Example:

```powershell
.\New-IgelUmsAclSql.ps1 `
    -NoGui `
    -SamAccountName 'DOT-Admins' `
    -FolderPath 'DENMARK,CPH,FAB1' `
    -UmsRoot 'LAB' `
    -LdapServer 'dc01.domain.local'
```

`FolderPath` accepts 2 to 4 comma-separated levels:

```text
Country,Site
Country,Site,Building
Country,Site,Building,Line
```

Optional parameters include:

```text
-SamAccountName
-FolderPath
-UmsRoot
-LdapServer
-SearchBase
-NoGui
```

## Permission baseline

The current Supporter baseline grants the following object permissions.

| Object permission | Setting | Purpose |
|---|---|---|
| Browse | **Allow** | The group can see the approved device folder and its path. |
| Read | **Allow** | The group can read device attributes and folder contents. |
| Move | **Not Set** | Device movement is not delegated by this baseline. |
| Edit Configuration | **Allow** | Permits approved device-specific configuration work. |
| Write | **Not Set** | Avoids general object and folder modification through this baseline. |
| Edit System Information | **Allow** | Permits approved device information maintenance. |
| Dual Boot Control | **Not Set** | Currently not set. Confirm against the controlling entitlement matrix before changing. |
| Access Control | **Not Set** | The delegated group must not change its own permissions. |
| Assign | **Not Set** | Broad assignment authority is not delegated. |
| Assign Profile | **Not Set** | Profile assignment is not included in the baseline. |
| Assign Priority Profile | **Not Set** | Priority-profile assignment remains restricted. |
| Assign Persona Profile | **Not Set** | Persona profile assignment is not included in the baseline. |
| Assign File | **Not Set** | File assignment remains restricted. |
| Assign base system / firmware update | **Allow** | Permits the approved update-assignment action for this scope. |
| Assign CIC | **Not Set** | Corporate identity customization assignment remains restricted. |
| Assign template value / value group | **Not Set** | Template-value assignment remains restricted. |
| Power Control | **Allow** | Permits approved power actions on devices in this folder. |
| Firmware Control | **Allow** | Permits approved firmware and update control operations shown by the validated role. |
| Settings Control | **Not Set** | Not included in the baseline. |
| UMS -> Device | **Allow** | Permits sending the UMS configuration to the device. |
| Device -> UMS | **Not Set** | Prevents this baseline from importing device-local configuration into UMS. |
| Remote Access | **Allow** | Permits approved Shadow/Secure VNC support. |
| Send Message | **Allow** | Permits approved administrator messages to the device. |

### Permission vector

The current baseline is:

```text
AA---------AAAAAAAAAA--AA--A---AA-----A-A--
```

Because the permission vector is positional, the exact mapping of every character must be treated as **version-specific**. Do not copy this string into another UMS version without first validating the permission order and semantics in that version.

## How the SQL is generated

The generated SQL works with the UMS database objects that were identified during testing, including:

```text
DIRECTORIES
TRUSTEES
TRUSTEEGROUP
SCHEMAVERSION
ACE
```

The directory path is resolved by joining the directory hierarchy through `MEMBEROF` relationships until the requested folder is reached.

The AD group's distinguished name is then matched against the corresponding UMS trustee group.

Before the ACE is inserted, the generated SQL checks that:

```text
Schema match        = exactly 1
Folder match        = exactly 1
Group match         = exactly 1
Existing ACE        = 0
```

The statement intentionally fails closed when a required condition is not satisfied.

For example, entering a folder name incorrectly can result in a generic `SQLServerException` in the UMS SQL Console because the generated validation expression deliberately converts an error marker into an integer. This is intended to prevent an incorrect object from being modified.

A common example is an incomplete folder path. If the requested hierarchy does not resolve to exactly one real UMS directory, the statement does not insert an ACE.

## Important operational note

The UMS SQL Console reports some SQL Server failures only as a generic message such as:

```text
An error occurred on the server: SQLServerException
Please see server-logs for more details.
```

When that happens, first verify the supplied UMS root and folder hierarchy exactly matches the real `DIRECTORIES` hierarchy. In particular:

- Folder names are case-sensitive.
- Every required hierarchy level must be present.
- The root must be a real UMS directory.
- The AD group must already exist in UMS as a trustee group.
- An existing ACE will intentionally prevent another insert.

## Recommended workflow

For a new environment, use the following process:

1. Import the AD groups through the normal UMS LDAP/LDAPS process.
2. Validate the Supporter permissions manually on one test group and folder in the UMS UI.
3. Confirm the resulting permission vector in the lab database.
4. Record the UMS version and schema version.
5. Configure the script's AD domain and UMS root.
6. Generate SQL for a test group and folder.
7. Review the SQL carefully.
8. Execute it manually in the UMS SQL Console.
9. Confirm the result in UMS Access Control and, where available, Effective Rights.
10. Only then use the generator for additional groups and scopes.

## Security and safety considerations

This tool is deliberately conservative, but it is still direct database manipulation.

### Not supported by IGEL

This project should be considered an administrative workaround, not a supported UMS API or extension mechanism.

Changes to the internal UMS database can have consequences that are not visible from the SQL statement itself, including authorization caching, indexing, audit behavior, or compatibility with future versions.

Do not assume that a successful SQL execution means the procedure is supported by IGEL.

### Test before production

Use a lab or non-production UMS system first.

Create disposable test groups and folders, apply the ACL, and confirm the effective permissions in the UMS user interface.

### Back up before use

Maintain a current and restorable database backup before performing direct database changes in any environment that matters.

### Review every generated statement

The tool generates SQL for you, but the administrator remains responsible for reviewing the target group, target folder, and permissions before execution.

### Do not bypass the safeguards

The generated statement is intentionally guarded against ambiguous matches and existing ACEs. Do not remove those checks simply to force an operation through.

## Versioning the permission template

The permission string is effectively a version-specific ACL template.

When upgrading UMS, treat the permission vector as invalid until it has been revalidated.

A recommended validation process is:

```text
1. Record UMS version
2. Record SCHEMAVERSION
3. Create a disposable group
4. Create a disposable folder
5. Apply the desired permissions through the normal UMS UI
6. Read the corresponding ACE
7. Compare the resulting permission vector
8. Update the script only after successful validation
```

The current script expects:

```text
Major version: 12
Minor version: 13
```

and uses the Supporter permission vector validated for the tested environment.

## Limitations

This project currently has several deliberate limitations:

- It creates ACL entries rather than reusable UMS role objects.
- It depends on the internal UMS database schema.
- It is tied to the validated permission-vector ordering.
- It currently targets one predefined permission baseline.
- It requires manual execution of the generated SQL.
- It does not provide a rollback operation.
- It does not attempt to manipulate UMS permission caches or internal indexes beyond the tested ACE insertion path.
- It should not be assumed to work against other UMS releases without validation.

## Troubleshooting

### `AD group was not found`

Check the `sAMAccountName`, LDAP server, and search base. The group must be visible from the machine running the script.

### `AD group is ambiguous`

The LDAP query found more than one matching group. Verify the AD environment and, if required, supply an explicit search base.

### Generic `SQLServerException` in the UMS SQL Console

Check the generated SQL first. The most common cause is that the supplied folder hierarchy did not resolve to exactly one UMS directory.

Verify:

```text
UMS root
Country
Site
Building
Line
```

against the actual UMS directory structure.

Also check whether an ACE already exists for the same trustee and object.

### Existing ACE

The generator intentionally refuses to create another ACL for the same object and trustee. Review the existing permission in UMS before deciding what should happen next.

## Project status

This is a practical lab-tested workaround for a specific operational requirement: applying a consistent, predefined UMS object-permission baseline to many AD groups and folder scopes.

It should be treated as an evolving utility rather than a replacement for native UMS authorization features.

The long-term preferred solution would be native support for reusable object-permission roles, for example:

```text
Role: Supporter
        |
        +-- Browse
        +-- Read
        +-- Edit Configuration
        +-- Power Control
        +-- Firmware Control
        +-- UMS -> Device
        +-- Remote Access
        +-- Send Message
        |
        v
Assign role to AD group
        |
        v
Apply role to UMS folder scope
```

That would separate the three concepts cleanly:

```text
Permission definition
AD group
Scope
```

and would remove the need to reproduce the same permission configuration manually for every new delegated group.

## Disclaimer

This project is community knowledge sharing and automation based on observed UMS database behavior.

It is **not affiliated with, supported by, or endorsed by IGEL Technology** unless explicitly stated otherwise by IGEL.

Use at your own risk. Always validate the behavior against the exact UMS release being used, maintain appropriate backups, and follow your organization's change-control and security procedures.
