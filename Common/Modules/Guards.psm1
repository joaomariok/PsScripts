Import-Module "$PSScriptRoot\Write.psm1" -Force

<#
.SYNOPSIS
    Prompts the user for confirmation before proceeding with an action.

.DESCRIPTION
    This function displays a choice dialog to the user with Yes/No options using the PowerShell host UI. It allows customization of the message, caption, and default choice. The function returns $true if the user selects "Yes" and $false if "No" is selected. This is commonly used before destructive operations like cache cleaning.

.PARAMETER Message
    The confirmation message to display to the user. This parameter is mandatory.

.PARAMETER Caption
    The caption/title for the confirmation dialog. Defaults to "Confirm".

.PARAMETER DefaultChoice
    The default selection when the dialog appears. 0 = Yes (proceed), 1 = No (cancel). Defaults to 1 (No) to favor safety.

.EXAMPLE
    PS> Confirm-Action -Message "Are you sure you want to delete all build artifacts?"
    # Displays confirmation dialog with default caption "Confirm"

.EXAMPLE
    PS> if (Confirm-Action -Message "Delete packages folder?" -Caption "Cleanup" -DefaultChoice 0) {
    >>     Remove-Item -Path $PackagesFolder -Recurse -Force
    >> }
    # Displays confirmation with custom caption and Yes as default choice
#>
function Confirm-Action {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Message,

        [string]$Caption = "Confirm",

        [int]$DefaultChoice = 1  # 0 = Yes, 1 = No
    )

    $choices = @(
        [System.Management.Automation.Host.ChoiceDescription]::new("&Yes", "Proceed with the action."),
        [System.Management.Automation.Host.ChoiceDescription]::new("&No", "Cancel the action.")
    )

    $result = $Host.UI.PromptForChoice($Caption, $Message, $choices, $DefaultChoice)

    return $result -eq 0  # $true if Yes, $false if No
}

<#
.SYNOPSIS
    Tests whether the current session is running with Administrator privileges.

.DESCRIPTION
    This function checks the current Windows identity against the built-in Administrator role using WindowsIdentity/WindowsPrincipal. If the session is not elevated, it writes a warning (via Write-Warning and Write-Text) explaining that Administrator privileges are required. Returns $true if elevated, $false otherwise. Commonly used as a guard at the start of scripts that require admin rights.

.EXAMPLE
    PS> Test-Elevated
    # Returns $true if running as Administrator, $false otherwise (with a warning)

.EXAMPLE
    PS> if (-not (Test-Elevated)) { throw "Administrator privileges are required." }
    # Guards a script so it stops immediately when not run elevated
#>
function Test-Elevated {
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

<#
.SYNOPSIS
    Tests whether an external command is available on the system.

.DESCRIPTION
    This function checks if a specified external command (executable) is available in the system PATH using Get-Command. If the command is not found, it throws an exception. This function implements the fail-early strategy by validating tool availability before attempting build operations.

.PARAMETER CommandName
    The name of the external command to check (e.g., 'MSBuild', 'nuget', 'dotnet'). This parameter is mandatory.

.EXAMPLE
    PS> Test-ExternalCommand -CommandName 'MSBuild'
    # Returns silently if MSBuild is available, throws if not

.EXAMPLE
    PS> Test-ExternalCommand -CommandName 'nuget'
    # Validates that the nuget CLI is installed and accessible
#>
function Test-ExternalCommand {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [string]$CommandName
    )

    if (-not $(Get-Command -Name $CommandName -ErrorAction SilentlyContinue)) {
        throw "Required command '$CommandName' is not available."
    }
}

Export-ModuleMember -Function @(
    'Confirm-Action',
    'Test-Elevated',
    'Test-ExternalCommand'
)
