<#
.SYNOPSIS
    Generates a guarded IGEL UMS SQL Console statement for assigning the
    standard folder ACL to an imported AD group.

.DESCRIPTION
    Uses System.DirectoryServices, so the ActiveDirectory PowerShell module is
    not required. The script resolves the group's distinguished name from its
    sAMAccountName, builds the exact UMS directory path, and opens the generated
    SQL in a copyable window.

    Edit the Environment configuration section once for each UMS environment.

.PARAMETER SamAccountName
    Optional non-GUI override for the AD group sAMAccountName.

.PARAMETER FolderPath
    Optional non-GUI folder path. Supply 2-4 comma-separated parts:
    Country,Site[,Building[,Line]].

.PARAMETER UmsRoot
    Overrides $DefaultRootFolder for this run.

.PARAMETER LdapServer
    Overrides $Domain for this run. This can be an AD DNS domain or a domain
    controller host name.

.PARAMETER SearchBase
    Optional LDAP search base DN. Normally discovered from RootDSE.

.PARAMETER NoGui
    Uses the supplied command-line parameters instead of the input form.
#>
[CmdletBinding()]
param(
    [Parameter()]
    [string] $SamAccountName,

    [Parameter()]
    [string] $FolderPath,

    [Parameter()]
    [string] $UmsRoot,

    [Parameter()]
    [AllowEmptyString()]
    [string] $LdapServer,

    [Parameter()]
    [AllowEmptyString()]
    [string] $SearchBase,

    [Parameter()]
    [switch] $NoGui
)

# ============================================================================
# Environment configuration - edit these values for each UMS environment
# ============================================================================
$Domain = 'domain.local'          # AD DNS domain or domain controller hostname
$DefaultRootFolder = 'Devices'   # First REAL folder stored in UMS DIRECTORIES
# ============================================================================

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$BaselinePermissions = 'AA---------AAAAAAAAAA--AA--A---AA-----A-A--'
$RequiredSchemaMajor = 12
$RequiredSchemaMinor = 13

# Explicit command-line parameters take precedence over the configuration.
if (-not $PSBoundParameters.ContainsKey('UmsRoot')) {
    $UmsRoot = $DefaultRootFolder
}
if (-not $PSBoundParameters.ContainsKey('LdapServer')) {
    $LdapServer = $Domain
}

function Escape-LdapFilterValue {
    param([Parameter(Mandatory)][string] $Value)

    $builder = New-Object System.Text.StringBuilder
    foreach ($character in $Value.ToCharArray()) {
        switch ([int][char]$character) {
            0      { [void]$builder.Append('\00') }
            40     { [void]$builder.Append('\28') }
            41     { [void]$builder.Append('\29') }
            42     { [void]$builder.Append('\2a') }
            92     { [void]$builder.Append('\5c') }
            default { [void]$builder.Append($character) }
        }
    }
    $builder.ToString()
}

function Escape-SqlLiteral {
    param([Parameter(Mandatory)][string] $Value)
    $Value.Replace("'", "''")
}

function Resolve-AdGroupDistinguishedName {
    param(
        [Parameter(Mandatory)][string] $GroupSamAccountName,
        [AllowEmptyString()][string] $Server,
        [AllowEmptyString()][string] $BaseDn
    )

    Add-Type -AssemblyName System.DirectoryServices

    $serverPrefix = if ([string]::IsNullOrWhiteSpace($Server)) { '' } else { $Server.Trim() + '/' }
    $rootDse = $null
    $searchRoot = $null
    $searcher = $null
    $results = $null

    try {
        if ([string]::IsNullOrWhiteSpace($BaseDn)) {
            $rootDse = New-Object System.DirectoryServices.DirectoryEntry("LDAP://${serverPrefix}RootDSE")
            $BaseDn = [string]$rootDse.Properties['defaultNamingContext'].Value
            if ([string]::IsNullOrWhiteSpace($BaseDn)) {
                throw 'Active Directory did not return a defaultNamingContext.'
            }
        }

        $searchRoot = New-Object System.DirectoryServices.DirectoryEntry("LDAP://${serverPrefix}${BaseDn}")
        $searcher = New-Object System.DirectoryServices.DirectorySearcher($searchRoot)
        $escapedSam = Escape-LdapFilterValue $GroupSamAccountName.Trim()
        $searcher.Filter = "(&(objectCategory=group)(sAMAccountName=$escapedSam))"
        $searcher.SearchScope = [System.DirectoryServices.SearchScope]::Subtree
        $searcher.PageSize = 500
        [void]$searcher.PropertiesToLoad.Add('distinguishedName')
        $results = $searcher.FindAll()

        if ($results.Count -eq 0) {
            throw "AD group '$GroupSamAccountName' was not found in '$BaseDn'."
        }
        if ($results.Count -gt 1) {
            throw "AD group '$GroupSamAccountName' is ambiguous: $($results.Count) matches were found."
        }

        $dnValues = $results[0].Properties['distinguishedname']
        if ($dnValues.Count -ne 1 -or [string]::IsNullOrWhiteSpace([string]$dnValues[0])) {
            throw "AD returned an invalid distinguishedName for '$GroupSamAccountName'."
        }
        [string]$dnValues[0]
    }
    finally {
        if ($null -ne $results) { $results.Dispose() }
        if ($null -ne $searcher) { $searcher.Dispose() }
        if ($null -ne $searchRoot) { $searchRoot.Dispose() }
        if ($null -ne $rootDse) { $rootDse.Dispose() }
    }
}

function New-IgelAclSql {
    param(
        [Parameter(Mandatory)][string] $GroupSamAccountName,
        [Parameter(Mandatory)][string] $GroupDistinguishedName,
        [Parameter(Mandatory)][string[]] $DirectoryParts
    )

    $lastIndex = $DirectoryParts.Count - 1
    $fromLines = New-Object System.Collections.Generic.List[string]
    $whereLines = New-Object System.Collections.Generic.List[string]
    $fromLines.Add('    FROM dbo.DIRECTORIES AS D0')

    for ($index = 1; $index -le $lastIndex; $index++) {
        $fromLines.Add("    JOIN dbo.DIRECTORIES AS D$index ON D$index.MEMBEROF = D$($index - 1).DIRID")
    }
    for ($index = 0; $index -le $lastIndex; $index++) {
        $name = Escape-SqlLiteral $DirectoryParts[$index]
        $prefix = if ($index -eq 0) { '    WHERE' } else { '      AND' }
        $whereLines.Add("$prefix D$index.NAME = N'$name' AND D$index.MOVEDTOBIN IS NULL")
    }

    $safeSam = $GroupSamAccountName.Replace('*/', '* /')
    $safeDn = Escape-SqlLiteral $GroupDistinguishedName
    $displayPath = ($DirectoryParts -join '/')
    $fromSql = $fromLines -join "`r`n"
    $whereSql = $whereLines -join "`r`n"

    @"
/*
    IGEL UMS direct ACL assignment
    AD group:   $safeSam
    LDAP DN:    $GroupDistinguishedName
    Folder:     $displayPath
    Permissions: $BaselinePermissions

    Generated for UMS schema $RequiredSchemaMajor.$RequiredSchemaMinor.
    Folder names are case sensitive and must match UMS exactly.
    Missing/ambiguous groups or folders, schema mismatch, and an existing ACE
    intentionally raise a SQL conversion error instead of changing data.
*/
WITH FolderCandidates AS
(
    SELECT D$lastIndex.DIRID
$fromSql
$whereSql
),
FolderStats AS
(
    SELECT COUNT_BIG(*) AS MatchCount, MAX(DIRID) AS DIRID
    FROM FolderCandidates
),
GroupCandidates AS
(
    SELECT T.ID
    FROM dbo.TRUSTEES AS T
    JOIN dbo.TRUSTEEGROUP AS TG ON TG.ID = T.ID
    WHERE T.NAME = N'$safeDn'
      AND T.TRUSTEETYPE = 1
),
GroupStats AS
(
    SELECT COUNT_BIG(*) AS MatchCount, MAX(ID) AS ID
    FROM GroupCandidates
),
SchemaStats AS
(
    SELECT COUNT_BIG(*) AS MatchCount
    FROM dbo.SCHEMAVERSION
    WHERE MAJORVERSION = $RequiredSchemaMajor
      AND MINORVERSION = $RequiredSchemaMinor
),
Resolved AS
(
    SELECT
        CASE
            WHEN V.MatchCount <> 1 THEN
                CONVERT(int, 'ERROR_SCHEMA_${RequiredSchemaMajor}_${RequiredSchemaMinor}_MATCH_COUNT_' + CONVERT(varchar(20), V.MatchCount))
            WHEN F.MatchCount = 1 THEN F.DIRID
            ELSE
                CONVERT(int, 'ERROR_FOLDER_MATCH_COUNT_' + CONVERT(varchar(20), F.MatchCount))
        END AS OBJECTID,
        CASE
            WHEN G.MatchCount = 1 THEN G.ID
            ELSE
                CONVERT(int, 'ERROR_GROUP_MATCH_COUNT_' + CONVERT(varchar(20), G.MatchCount))
        END AS TRUSTEE
    FROM FolderStats AS F
    CROSS JOIN GroupStats AS G
    CROSS JOIN SchemaStats AS V
),
ExistingAceStats AS
(
    SELECT COUNT_BIG(A.OBJECTID) AS MatchCount
    FROM Resolved AS R
    LEFT JOIN dbo.ACE AS A
        ON A.OBJECTID = R.OBJECTID
       AND A.TRUSTEE = R.TRUSTEE
),
SourceRow AS
(
    SELECT
        CASE
            WHEN E.MatchCount = 0 THEN R.OBJECTID
            ELSE
                CONVERT(int, 'ERROR_ACE_ALREADY_EXISTS_COUNT_' + CONVERT(varchar(20), E.MatchCount))
        END AS OBJECTID,
        R.TRUSTEE,
        CAST('-' AS varchar(1)) AS ACCESSTYPE,
        CAST('$BaselinePermissions' AS varchar(100)) AS PERMISSIONS
    FROM Resolved AS R
    CROSS JOIN ExistingAceStats AS E
)
INSERT INTO dbo.ACE (OBJECTID, TRUSTEE, ACCESSTYPE, PERMISSIONS)
SELECT OBJECTID, TRUSTEE, ACCESSTYPE, PERMISSIONS
FROM SourceRow
"@
}

function Show-AclInputDialog {
    param([Parameter(Mandatory)][string] $InitialUmsRoot)

    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    [System.Windows.Forms.Application]::EnableVisualStyles()

    $form = New-Object System.Windows.Forms.Form
    $form.Text = 'IGEL UMS ACL Generator'
    $form.StartPosition = 'CenterScreen'
    $form.ClientSize = New-Object System.Drawing.Size(670, 570)
    $form.FormBorderStyle = 'FixedDialog'
    $form.MaximizeBox = $false
    $form.MinimizeBox = $false
    $form.Font = New-Object System.Drawing.Font('Segoe UI', 9)
    $form.BackColor = [System.Drawing.Color]::White

    $title = New-Object System.Windows.Forms.Label
    $title.Text = 'Generate folder permissions'
    $title.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 16)
    $title.AutoSize = $true
    $title.Location = New-Object System.Drawing.Point(28, 22)
    $form.Controls.Add($title)

    $intro = New-Object System.Windows.Forms.Label
    $intro.Text = 'Enter the imported AD group and its exact UMS directory path.'
    $intro.ForeColor = [System.Drawing.Color]::DimGray
    $intro.AutoSize = $true
    $intro.Location = New-Object System.Drawing.Point(31, 58)
    $form.Controls.Add($intro)

    function Add-Field {
        param([string]$Label, [int]$Y, [string]$Value, [bool]$Required, [string]$Warning)
        $labelControl = New-Object System.Windows.Forms.Label
        $suffix = if ($Required) { ' *' } else { ' (optional)' }
        $labelControl.Text = $Label + $suffix
        $labelControl.AutoSize = $true
        $labelControl.Location = New-Object System.Drawing.Point(32, $Y)
        $form.Controls.Add($labelControl)

        $textBox = New-Object System.Windows.Forms.TextBox
        $textBox.Text = $Value
        $textBox.Size = New-Object System.Drawing.Size(600, 25)
        $textBox.Location = New-Object System.Drawing.Point(34, ($Y + 21))
        $form.Controls.Add($textBox)

        $warningControl = New-Object System.Windows.Forms.Label
        $warningControl.Text = $Warning
        $warningControl.ForeColor = [System.Drawing.Color]::FromArgb(176, 91, 0)
        $warningControl.AutoSize = $true
        $warningControl.Location = New-Object System.Drawing.Point(34, ($Y + 49))
        $form.Controls.Add($warningControl)
        $textBox
    }

    $groupBox = Add-Field 'AD group sAMAccountName' 92 '' $true 'Not case sensitive. Enter only the sAMAccountName; the LDAP DN is resolved automatically.'
    $rootBox = Add-Field 'UMS root folder' 164 $InitialUmsRoot $true 'Case sensitive. Must be the first real folder stored in UMS, not a virtual UI label.'
    $countryBox = Add-Field 'Country' 236 '' $true 'Case sensitive. Must match the UMS directory name exactly.'
    $siteBox = Add-Field 'Site' 308 '' $true 'Case sensitive. Must match the UMS directory name exactly.'
    $buildingBox = Add-Field 'Building' 380 '' $false 'Case sensitive when supplied. Leave empty if this folder level is not used.'
    $lineBox = Add-Field 'Line' 452 '' $false 'Case sensitive when supplied. Building is required before a Line can be used.'

    $generateButton = New-Object System.Windows.Forms.Button
    $generateButton.Text = 'Generate SQL'
    $generateButton.Size = New-Object System.Drawing.Size(120, 34)
    $generateButton.Location = New-Object System.Drawing.Point(386, 522)
    $generateButton.BackColor = [System.Drawing.Color]::FromArgb(0, 102, 178)
    $generateButton.ForeColor = [System.Drawing.Color]::White
    $generateButton.FlatStyle = 'Flat'
    $generateButton.DialogResult = [System.Windows.Forms.DialogResult]::OK
    $form.Controls.Add($generateButton)

    $cancelButton = New-Object System.Windows.Forms.Button
    $cancelButton.Text = 'Cancel'
    $cancelButton.Size = New-Object System.Drawing.Size(120, 34)
    $cancelButton.Location = New-Object System.Drawing.Point(514, 522)
    $cancelButton.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $form.Controls.Add($cancelButton)

    $form.AcceptButton = $generateButton
    $form.CancelButton = $cancelButton

    while ($form.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        $group = $groupBox.Text.Trim()
        $root = $rootBox.Text.Trim()
        $country = $countryBox.Text.Trim()
        $site = $siteBox.Text.Trim()
        $building = $buildingBox.Text.Trim()
        $line = $lineBox.Text.Trim()

        $validationError = $null
        if ([string]::IsNullOrWhiteSpace($group)) { $validationError = 'AD group sAMAccountName is required.' }
        elseif ([string]::IsNullOrWhiteSpace($root)) { $validationError = 'UMS root folder is required.' }
        elseif ([string]::IsNullOrWhiteSpace($country)) { $validationError = 'Country is required.' }
        elseif ([string]::IsNullOrWhiteSpace($site)) { $validationError = 'Site is required.' }
        elseif (-not [string]::IsNullOrWhiteSpace($line) -and [string]::IsNullOrWhiteSpace($building)) {
            $validationError = 'Building must be supplied when Line is supplied.'
        }

        if ($null -ne $validationError) {
            [void][System.Windows.Forms.MessageBox]::Show($validationError, 'Check the fields', 'OK', 'Warning')
            continue
        }

        $form.Hide()
        return [pscustomobject]@{
            SamAccountName = $group
            UmsRoot = $root
            FolderParts = @($country, $site, $building, $line) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
        }
    }
    $null
}

function Show-SqlViewer {
    param(
        [Parameter(Mandatory)][string] $Sql,
        [Parameter(Mandatory)][string] $SavedPath
    )

    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing

    $viewer = New-Object System.Windows.Forms.Form
    $viewer.Text = 'IGEL UMS SQL - Review and Copy'
    $viewer.StartPosition = 'CenterScreen'
    $viewer.ClientSize = New-Object System.Drawing.Size(950, 700)
    $viewer.MinimumSize = New-Object System.Drawing.Size(760, 560)
    $viewer.Font = New-Object System.Drawing.Font('Segoe UI', 9)

    $message = New-Object System.Windows.Forms.Label
    $message.Text = "Review the SQL, then copy it into the IGEL UMS SQL Console.`r`nSaved to: $SavedPath"
    $message.AutoSize = $true
    $message.Location = New-Object System.Drawing.Point(18, 14)
    $viewer.Controls.Add($message)

    $sqlBox = New-Object System.Windows.Forms.TextBox
    $sqlBox.Multiline = $true
    $sqlBox.ScrollBars = 'Both'
    $sqlBox.WordWrap = $false
    $sqlBox.AcceptsReturn = $true
    $sqlBox.AcceptsTab = $true
    $sqlBox.Font = New-Object System.Drawing.Font('Consolas', 10)
    $sqlBox.Text = $Sql
    $sqlBox.ReadOnly = $true
    $sqlBox.Anchor = 'Top,Bottom,Left,Right'
    $sqlBox.Location = New-Object System.Drawing.Point(18, 58)
    $sqlBox.Size = New-Object System.Drawing.Size(914, 582)
    $viewer.Controls.Add($sqlBox)

    $copyButton = New-Object System.Windows.Forms.Button
    $copyButton.Text = 'Copy SQL'
    $copyButton.Size = New-Object System.Drawing.Size(120, 34)
    $copyButton.Location = New-Object System.Drawing.Point(680, 651)
    $copyButton.Anchor = 'Bottom,Right'
    $copyButton.Add_Click({
        [System.Windows.Forms.Clipboard]::SetText($Sql)
        $copyButton.Text = 'Copied!'
    })
    $viewer.Controls.Add($copyButton)

    $closeButton = New-Object System.Windows.Forms.Button
    $closeButton.Text = 'Close'
    $closeButton.Size = New-Object System.Drawing.Size(120, 34)
    $closeButton.Location = New-Object System.Drawing.Point(812, 651)
    $closeButton.Anchor = 'Bottom,Right'
    $closeButton.Add_Click({ $viewer.Close() })
    $viewer.Controls.Add($closeButton)

    $viewer.Add_Shown({ $sqlBox.Select(0, 0); $sqlBox.Focus() })
    [void]$viewer.ShowDialog()
}

try {
    if (-not $NoGui) {
        $inputValues = Show-AclInputDialog -InitialUmsRoot $UmsRoot
        if ($null -eq $inputValues) { return }
        $SamAccountName = $inputValues.SamAccountName
        $UmsRoot = $inputValues.UmsRoot
        $folderParts = @($inputValues.FolderParts)
    }
    else {
        if ([string]::IsNullOrWhiteSpace($SamAccountName)) { throw '-SamAccountName is required with -NoGui.' }
        if ([string]::IsNullOrWhiteSpace($UmsRoot)) { throw '$DefaultRootFolder or -UmsRoot must contain a value.' }
        if ([string]::IsNullOrWhiteSpace($FolderPath)) { throw '-FolderPath is required with -NoGui.' }
        $folderParts = @($FolderPath.Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ })
        if ($folderParts.Count -lt 2 -or $folderParts.Count -gt 4) {
            throw '-FolderPath must contain 2-4 values: Country,Site[,Building[,Line]].'
        }
    }

    $groupDn = Resolve-AdGroupDistinguishedName -GroupSamAccountName $SamAccountName -Server $LdapServer -BaseDn $SearchBase
    $allDirectoryParts = @($UmsRoot) + @($folderParts)
    $sql = New-IgelAclSql -GroupSamAccountName $SamAccountName -GroupDistinguishedName $groupDn -DirectoryParts $allDirectoryParts

    $desktop = [Environment]::GetFolderPath('Desktop')
    if ([string]::IsNullOrWhiteSpace($desktop) -or -not (Test-Path -LiteralPath $desktop)) {
        $desktop = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
    }
    $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $safeFileGroup = $SamAccountName -replace '[^A-Za-z0-9_.-]', '_'
    $sqlPath = Join-Path $desktop "IGEL-ACL-$safeFileGroup-$timestamp.sql"
    [System.IO.File]::WriteAllText($sqlPath, $sql, (New-Object System.Text.UTF8Encoding($false)))

    if (-not $NoGui) {
        Show-SqlViewer -Sql $sql -SavedPath $sqlPath
    }
    else {
        $sql
        Write-Warning "Generated SQL remains available at '$sqlPath'."
    }
}
catch {
    if (-not $NoGui) {
        Add-Type -AssemblyName System.Windows.Forms
        [void][System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'IGEL UMS ACL Generator', 'OK', 'Error')
    }
    else {
        throw
    }
}
