#requires -Version 5.1
<#
.SYNOPSIS
Build webapp#sso.war using only PowerShell and .NET.
.EXAMPLE
.\Build-SSOAutoLaunch.ps1
.EXAMPLE
.\Build-SSOAutoLaunch.ps1 -OutputPath C:\temp\webapp#sso.war
#>
param([string]$OutputPath = (Join-Path $PSScriptRoot 'dist\webapp#sso.war'))

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

$files = @(
    @{ File = 'src/index.html'; Entry = 'index.html' },
    @{ File = 'src/sso.js'; Entry = 'sso.js' },
    @{ File = 'src/WEB-INF/web.xml'; Entry = 'WEB-INF/web.xml' }
)

$destination = [IO.Path]::GetFullPath($OutputPath)
$directory = [IO.Path]::GetDirectoryName($destination)
if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
    New-Item -ItemType Directory -Path $directory -Force | Out-Null
}
foreach ($file in $files) {
    $source = Join-Path $PSScriptRoot ($file.File.Replace('/', '\'))
    if (-not (Test-Path -LiteralPath $source -PathType Leaf)) {
        throw "Missing source: $source"
    }
}

$temp = "$destination.building"
if (Test-Path -LiteralPath $temp) {
    throw "Incomplete build already exists: $temp"
}
try {
    $archive = [IO.Compression.ZipFile]::Open($temp, [IO.Compression.ZipArchiveMode]::Create)
    try {
        foreach ($file in $files) {
            $source = Join-Path $PSScriptRoot ($file.File.Replace('/', '\'))
            [IO.Compression.ZipFileExtensions]::CreateEntryFromFile(
                $archive, $source, $file.Entry,
                [IO.Compression.CompressionLevel]::Optimal
            ) | Out-Null
        }
    }
    finally { $archive.Dispose() }

    $check = [IO.Compression.ZipFile]::OpenRead($temp)
    try {
        $names = @($check.Entries | ForEach-Object { $_.FullName })
        foreach ($file in $files) {
            if ($names -cnotcontains $file.Entry) {
                throw "Missing WAR entry: $($file.Entry)"
            }
        }
        if ($names.Count -ne $files.Count) {
            throw "Unexpected WAR contents: $($names -join ', ')"
        }
    }
    finally { $check.Dispose() }

    Move-Item -LiteralPath $temp -Destination $destination -Force
}
catch {
    if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Force }
    throw
}
Write-Host "Built: $destination"
Get-FileHash -LiteralPath $destination -Algorithm SHA256 |
    Format-List Path, Hash
