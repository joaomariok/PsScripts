function Write-Text
{
    [CmdletBinding()]
    param(
        [string]$Message,
        [ConsoleColor]$ForegroundColor = [ConsoleColor]::Gray,
        [ConsoleColor]$BackgroundColor = [ConsoleColor]::Black
    )

    Write-Host $Message -ForegroundColor $ForegroundColor -BackgroundColor $BackgroundColor
}

function Write-Title
{
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Message,
        [ConsoleColor]$ForegroundColor = [ConsoleColor]::Cyan,
        [ConsoleColor]$BackgroundColor = [ConsoleColor]::Black,
        [switch]$NoNewlineBefore
    )

    if (-not $NoNewlineBefore) { Write-Host "" }
    Write-Host $Message -ForegroundColor $ForegroundColor -BackgroundColor $BackgroundColor
}

function Write-MainTitle
{
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Message,
        [ConsoleColor]$ForegroundColor = [ConsoleColor]::Magenta,
        [ConsoleColor]$BackgroundColor = [ConsoleColor]::Black,
        [switch]$NoNewlineBefore,
        [switch]$NoNewlineAfter
    )

    $Separator = "=" * $Message.Length

    if (-not $NoNewlineBefore) { Write-Host "" }
    Write-Text $Separator -ForegroundColor $ForegroundColor -BackgroundColor $BackgroundColor
    Write-Text $Message   -ForegroundColor $ForegroundColor -BackgroundColor $BackgroundColor
    Write-Text $Separator -ForegroundColor $ForegroundColor -BackgroundColor $BackgroundColor
    if (-not $NoNewlineAfter) { Write-Host "" }
}

Export-ModuleMember -Function @(
    'Write-Text',
    'Write-Title',
    'Write-MainTitle'
)
