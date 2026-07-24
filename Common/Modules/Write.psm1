<#
.SYNOPSIS
    Writes an empty line to the console output.

.DESCRIPTION
    This function outputs a blank line to the console using Write-Host. It is commonly used to add visual separation between sections of output in the build script.

.EXAMPLE
    PS> Write-EmptyLine
    # Outputs a single empty line to the console

.EXAMPLE
    PS> Write-Text "Starting build..." -ForegroundColor Cyan
    Write-EmptyLine
    Write-Text "Build completed." -ForegroundColor Green
    # Creates visual separation between status messages
#>
function Write-EmptyLine {
    [CmdletBinding()]
    param()

    Write-Host ""
}

<#
.SYNOPSIS
    Writes a text message to the console with customizable colors.

.DESCRIPTION
    This function outputs a text message to the console using Write-Host with customizable foreground and background colors. It provides a convenient wrapper for consistent console output formatting throughout the build script.

.PARAMETER Message
    The text message to write to the console.

.PARAMETER ForegroundColor
    The foreground (text) color for the message. Defaults to Gray. Accepts any valid ConsoleColor value.

.PARAMETER BackgroundColor
    The background color for the message. Defaults to Black. Accepts any valid ConsoleColor value.

.EXAMPLE
    PS> Write-Text "Build started" -ForegroundColor Cyan
    # Writes "Build started" in cyan text on a black background

.EXAMPLE
    PS> Write-Text "Error occurred" -ForegroundColor Red -BackgroundColor Yellow
    # Writes "Error occurred" in red text on a yellow background for high visibility
#>
function Write-Text {
    [CmdletBinding()]
    param(
        [string]$Message,
        [ConsoleColor]$ForegroundColor = [ConsoleColor]::Gray,
        [ConsoleColor]$BackgroundColor = [ConsoleColor]::Black
    )

    Write-Host $Message -ForegroundColor $ForegroundColor -BackgroundColor $BackgroundColor
}

<#
.SYNOPSIS
    Writes a success message to the console with green formatting.

.DESCRIPTION
    This function outputs a success message to the console with a "[SUCCESS]" prefix in green text. It automatically adds newlines before and after the message for visual separation, unless the NoNewlineBefore or NoNewlineAfter switches are specified.

.PARAMETER Message
    The success message to display. This parameter is mandatory.

.PARAMETER NoNewlineBefore
    If specified, suppresses the automatic newline before the success message. By default, a newline is added for visual separation.

.PARAMETER NoNewlineAfter
    If specified, suppresses the automatic newline after the success message. By default, a newline is added for visual separation.

.EXAMPLE
    PS> Write-Success "Build completed successfully"
    # Outputs "[SUCCESS] Build completed successfully" in green with surrounding newlines

.EXAMPLE
    PS> Write-Success "Package created" -NoNewlineBefore -NoNewlineAfter
    # Outputs "[SUCCESS] Package created" in green without surrounding newlines
#>
function Write-Success {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Message,
        [switch]$NoNewlineBefore,
        [switch]$NoNewlineAfter
    )

    if (-not $NoNewlineBefore) { Write-EmptyLine }
    Write-Host "[SUCCESS] $Message" -ForegroundColor Green
    if (-not $NoNewlineAfter) { Write-EmptyLine }
}

<#
.SYNOPSIS
    Writes a title message to the console with cyan formatting.

.DESCRIPTION
    This function outputs a title message to the console with customizable colors, defaulting to cyan text on a black background. It automatically adds a newline before the title for visual separation, unless the NoNewlineBefore switch is specified. This function is commonly used for section headers within the build output.

.PARAMETER Message
    The title message to display. This parameter is mandatory.

.PARAMETER ForegroundColor
    The foreground (text) color for the title. Defaults to Cyan. Accepts any valid ConsoleColor value.

.PARAMETER BackgroundColor
    The background color for the title. Defaults to Black. Accepts any valid ConsoleColor value.

.PARAMETER NoNewlineBefore
    If specified, suppresses the automatic newline before the title. By default, a newline is added for visual separation.

.EXAMPLE
    PS> Write-Title "Building ASR Library"
    # Outputs "Building ASR Library" in cyan with a preceding newline

.EXAMPLE
    PS> Write-Title "RESTORING PACKAGES" -ForegroundColor Yellow -NoNewlineBefore
    # Outputs "RESTORING PACKAGES" in yellow without a preceding newline
#>
function Write-Title {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Message,
        [ConsoleColor]$ForegroundColor = [ConsoleColor]::Cyan,
        [ConsoleColor]$BackgroundColor = [ConsoleColor]::Black,
        [switch]$NoNewlineBefore
    )

    if (-not $NoNewlineBefore) { Write-EmptyLine }
    Write-Host $Message -ForegroundColor $ForegroundColor -BackgroundColor $BackgroundColor
}

<#
.SYNOPSIS
    Writes a main title with separator lines to the console with magenta formatting.

.DESCRIPTION
    This function outputs a prominent main title to the console with horizontal separator lines above and below the message. The separators span the full width of the console buffer. By default, it uses magenta text on a black background and adds newlines before and after for visual separation. This function is commonly used for major section headers in the build output.

.PARAMETER Message
    The main title message to display. This parameter is mandatory.

.PARAMETER ForegroundColor
    The foreground (text) color for the title and separators. Defaults to Magenta. Accepts any valid ConsoleColor value.

.PARAMETER BackgroundColor
    The background color for the title and separators. Defaults to Black. Accepts any valid ConsoleColor value.

.PARAMETER NoNewlineBefore
    If specified, suppresses the automatic newline before the title. By default, a newline is added for visual separation.

.PARAMETER NoNewlineAfter
    If specified, suppresses the automatic newline after the title and separator. By default, a newline is added for visual separation.

.EXAMPLE
    PS> Write-MainTitle "BUILDING ASR SOLUTION"
    # Outputs a magenta title with separator lines above and below

.EXAMPLE
    PS> Write-MainTitle "PACKAGE PHASE" -ForegroundColor Cyan -NoNewlineAfter
    # Outputs a cyan title with separators, suppressing the trailing newline
#>
function Write-MainTitle {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Message,
        [ConsoleColor]$ForegroundColor = [ConsoleColor]::Magenta,
        [ConsoleColor]$BackgroundColor = [ConsoleColor]::Black,
        [switch]$NoNewlineBefore,
        [switch]$NoNewlineAfter
    )

    $Separator = "=" * $Host.UI.RawUI.BufferSize.Width

    if (-not $NoNewlineBefore) { Write-EmptyLine }
    Write-Text $Separator -ForegroundColor $ForegroundColor -BackgroundColor $BackgroundColor
    Write-Text $Message   -ForegroundColor $ForegroundColor -BackgroundColor $BackgroundColor
    Write-Text $Separator -ForegroundColor $ForegroundColor -BackgroundColor $BackgroundColor
    if (-not $NoNewlineAfter) { Write-EmptyLine }
}

<#
.SYNOPSIS
    Displays all entries in the PATH environment variable.

.DESCRIPTION
    This function splits the PATH environment variable by semicolons and displays each entry on a separate line using Write-Text. This is useful for debugging PATH-related issues when external commands cannot be found.

.EXAMPLE
    PS> Show-PathEntries
    # Displays all PATH entries, one per line

.EXAMPLE
    PS> Show-PathEntries | Select-String "MSBuild"
    # Filters PATH entries containing "MSBuild"
#>
function Show-PathEntries {
    $env:PATH -split ';' | ForEach-Object { Write-Text $_ }
}

Export-ModuleMember -Function @(
    'Write-EmptyLine',
    'Write-Text',
    'Write-Success',
    'Write-Title',
    'Write-MainTitle',
    'Show-PathEntries'
)
