# Cleanup-System.ps1
[CmdletBinding(SupportsShouldProcess)]
param(
    [switch]$CleanDism
)

Import-Module "C:\Users\joaom\Scripts\Cleanup" -Force

Clear-System -CleanDism:$CleanDism -WhatIf:$WhatIfPreference