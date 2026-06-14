# Cleanup-System.ps1
[CmdletBinding(SupportsShouldProcess)]
param(
    [switch]$CleanDism
)

Import-Module "$PSScriptRoot" -Force

Clear-System -CleanDism:$CleanDism -WhatIf:$WhatIfPreference