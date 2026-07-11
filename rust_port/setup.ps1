# One-time setup: fetch DXC + Agility SDK binaries into tools/ (gitignored).
# -ExcludeVersion gives stable paths (tools/Microsoft.Direct3D.DXC/...) so build.rs
# and docs never chase version numbers; re-run to update to latest.
$ErrorActionPreference = 'Stop'
$tools = Join-Path $PSScriptRoot 'tools'

nuget install Microsoft.Direct3D.DXC   -ExcludeVersion -NonInteractive -OutputDirectory $tools
nuget install Microsoft.Direct3D.D3D12 -ExcludeVersion -NonInteractive -OutputDirectory $tools

"`nInstalled:"
Get-ChildItem "$tools\Microsoft.Direct3D.DXC\build\native\bin\x64\*.dll",
              "$tools\Microsoft.Direct3D.D3D12\build\native\bin\x64\*.dll" |
    Select-Object FullName
