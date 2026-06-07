Import-Module "$PSScriptRoot\Write.psm1" -Force

function Test-Elevated
{
    $CurrentIdentity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $Principal = [Security.Principal.WindowsPrincipal]::new($CurrentIdentity)
    $IsAdmin = $Principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

    if (-not $IsAdmin)
    {
        Write-Warning "Administrator privileges are required. Please run as Administrator."
        Write-Text ""
    }

    return $IsAdmin
}

Export-ModuleMember -Function @(
    'Test-Elevated'
)
