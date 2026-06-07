param(
    [int]$IntervalSeconds = 30,
    [int]$JiggleRadius    = 10
)

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

[System.Windows.Forms.Application]::SetHighDpiMode([System.Windows.Forms.HighDpiMode]::PerMonitorV2) | Out-Null

# Singleton enforcement: a named, machine-wide mutex. $createdNew is false if another
# instance already owns it — bail out before building any UI.
$createdNew = $false
$script:singletonMutex = New-Object System.Threading.Mutex($true, 'Global\MouseMover-SingleInstance', [ref]$createdNew)
if (-not $createdNew) {
    [System.Windows.Forms.MessageBox]::Show('Mouse Mover is already running.', 'Mouse Mover', 'OK', 'Information') | Out-Null
    exit
}

# Win32 API for getting cursor position and detecting movement.
# Guarded: Add-Type can't redefine a type already loaded in the runspace.
if (-not ([System.Management.Automation.PSTypeName]'MouseHelper').Type) {
Add-Type @"
using System;
using System.Runtime.InteropServices;
public class MouseHelper {
    [DllImport("user32.dll")]
    public static extern bool GetCursorPos(out POINT lpPoint);

    [DllImport("user32.dll")]
    public static extern uint SendInput(uint nInputs, INPUT[] pInputs, int cbSize);

    [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
    public static extern int ExtractIconEx(string lpszFile, int nIconIndex, IntPtr[] phiconLarge, IntPtr[] phiconSmall, int nIcons);

    [StructLayout(LayoutKind.Sequential)]
    public struct POINT { public int X; public int Y; }

    [StructLayout(LayoutKind.Sequential)]
    public struct MOUSEINPUT {
        public int dx;
        public int dy;
        public uint mouseData;
        public uint dwFlags;
        public uint time;
        public IntPtr dwExtraInfo;
    }

    [StructLayout(LayoutKind.Explicit)]
    public struct INPUT {
        [FieldOffset(0)] public int type;
        [FieldOffset(8)] public MOUSEINPUT mi;
    }
}
"@
}

# --- State ---
$script:running  = $false
$script:lastPos  = $null
$script:rng      = New-Object System.Random
$script:stopped  = $false

# --- Run-at-startup (per-user registry Run key, no admin required) ---
$startupRegPath   = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
$startupValueName = 'MouseMover'

# --- Form ---
$form = New-Object System.Windows.Forms.Form
$form.Text            = "Mouse Mover"
$form.AutoScaleMode   = [System.Windows.Forms.AutoScaleMode]::None
$form.AutoScaleDimensions = New-Object System.Drawing.SizeF(96, 96)
$form.Size            = New-Object System.Drawing.Size(200, 120)
$form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedSingle
$form.MaximizeBox     = $false
$form.StartPosition   = [System.Windows.Forms.FormStartPosition]::CenterScreen
$form.BackColor       = [System.Drawing.Color]::FromArgb(30, 30, 30)
$form.Padding         = New-Object System.Windows.Forms.Padding(15, 10, 15, 10)

$btn = New-Object System.Windows.Forms.Button
$btn.Text      = "Start"
$btn.Dock      = [System.Windows.Forms.DockStyle]::Fill
$btn.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
$btn.ForeColor = [System.Drawing.Color]::White
$btn.BackColor = [System.Drawing.Color]::FromArgb(0, 180, 100)
$btn.Font      = New-Object System.Drawing.Font("Segoe UI", 12, [System.Drawing.FontStyle]::Bold)
$btn.FlatAppearance.BorderSize = 0
$form.Controls.Add($btn)

# --- Timer (interval set later by Set-Interval, once the tray menu exists) ---
$timer = New-Object System.Windows.Forms.Timer

# Standard-normal sample scaled by $stdDev, via the Box-Muller transform — .NET's Random has
# no built-in Gaussian sampler. Symmetric about 0, so offsets land on either side equally often.
function Get-GaussianOffset([double]$stdDev) {
    $u1 = $script:rng.NextDouble()
    $u2 = $script:rng.NextDouble()
    $z  = [Math]::Sqrt(-2 * [Math]::Log($u1)) * [Math]::Cos(2 * [Math]::PI * $u2)
    return $z * $stdDev
}

$timer.Add_Tick({
    if (-not $script:running) { return }

    # Skip while the screen is locked: LogonUI.exe is the lock-screen process, and
    # there's no point jiggling the cursor (or fighting the unlock) when no one can see it.
    if (Get-Process -Name "LogonUI" -ErrorAction SilentlyContinue) { return }

    # Check whether the user moved the mouse since the last tick
    $p = New-Object MouseHelper+POINT
    [MouseHelper]::GetCursorPos([ref]$p) | Out-Null

    $moved = ($script:lastPos -ne $null) -and (($p.X -ne $script:lastPos.X) -or ($p.Y -ne $script:lastPos.Y))

    if (-not $moved) {
        $vd        = [System.Windows.Forms.SystemInformation]::VirtualScreen
        $targetX   = [Math]::Max($vd.Left, [Math]::Min($vd.Right  - 1, $p.X + [int](Get-GaussianOffset $JiggleRadius)))
        $targetY   = [Math]::Max($vd.Top,  [Math]::Min($vd.Bottom - 1, $p.Y + [int](Get-GaussianOffset $JiggleRadius)))

        $MOUSEEVENTF_MOVE        = 0x0001
        $MOUSEEVENTF_ABSOLUTE    = 0x8000
        $MOUSEEVENTF_VIRTUALDESK = 0x4000
        $mi = New-Object MouseHelper+MOUSEINPUT
        $mi.dx      = [int][Math]::Round(($targetX - $vd.Left) * 65535 / [Math]::Max(1, $vd.Width  - 1))
        $mi.dy      = [int][Math]::Round(($targetY - $vd.Top)  * 65535 / [Math]::Max(1, $vd.Height - 1))
        $mi.dwFlags = $MOUSEEVENTF_MOVE -bor $MOUSEEVENTF_ABSOLUTE -bor $MOUSEEVENTF_VIRTUALDESK

        $mouseInput = New-Object MouseHelper+INPUT
        $mouseInput.type = 0  # INPUT_MOUSE
        $mouseInput.mi   = $mi
        $inputSize = [System.Runtime.InteropServices.Marshal]::SizeOf([type][MouseHelper+INPUT])
        [MouseHelper]::SendInput(1, @($mouseInput), $inputSize) | Out-Null

        $p.X = $targetX
        $p.Y = $targetY
    }

    $script:lastPos = $p
})

# --- Tray status icons (green check / red X from shell32.dll) ---
function Get-ShellIcon([int]$index) {
    $small = New-Object IntPtr[] 1
    [MouseHelper]::ExtractIconEx("$env:SystemRoot\System32\shell32.dll", $index, $null, $small, 1) | Out-Null
    return [System.Drawing.Icon]::FromHandle($small[0])
}

$iconRunning = Get-ShellIcon 294
$iconStopped = Get-ShellIcon 131

# --- Start/Stop toggle (shared by the button and the tray menu) ---
function Switch-Running {
    $script:running = -not $script:running

    if ($script:running) {
        # Capture current position and start fresh timer
        $p = New-Object MouseHelper+POINT
        [MouseHelper]::GetCursorPos([ref]$p) | Out-Null
        $script:lastPos  = $p
        $timer.Start()

        $btn.Text         = "Stop"
        $btn.BackColor    = [System.Drawing.Color]::FromArgb(200, 60, 60)
        $menuToggle.Text  = "Stop"
        $trayIcon.Icon    = $iconRunning
    } else {
        $timer.Stop()
        $script:lastPos = $null

        $btn.Text         = "Start"
        $btn.BackColor    = [System.Drawing.Color]::FromArgb(0, 180, 100)
        $menuToggle.Text  = "Start"
        $trayIcon.Icon    = $iconStopped
    }
}

$btn.Add_Click({ Switch-Running })

# --- Tray icon + context menu ---
$trayMenu = New-Object System.Windows.Forms.ContextMenuStrip

$menuToggle = New-Object System.Windows.Forms.ToolStripMenuItem
$menuToggle.Text = "Start"
$menuToggle.Add_Click({ Switch-Running })
$trayMenu.Items.Add($menuToggle) | Out-Null

function Set-Interval([int]$seconds) {
    $wasRunning = $timer.Enabled
    if ($wasRunning) { $timer.Stop() }
    $timer.Interval = $seconds * 1000
    if ($wasRunning) { $timer.Start() }

    foreach ($item in $menuInterval.DropDownItems) {
        $item.Checked = ($item.Tag -eq $seconds)
    }
}

$menuInterval = New-Object System.Windows.Forms.ToolStripMenuItem
$menuInterval.Text = "Interval"
foreach ($seconds in 1, 2, 5, 10, 15, 30, 60, 120) {
    $item = New-Object System.Windows.Forms.ToolStripMenuItem
    $item.Text = "${seconds}s"
    $item.Tag  = $seconds
    $item.Add_Click({ Set-Interval $this.Tag })
    $menuInterval.DropDownItems.Add($item) | Out-Null
}
$trayMenu.Items.Add($menuInterval) | Out-Null
Set-Interval $IntervalSeconds

# --- Run-at-startup toggle (registers/unregisters MouseMover.vbs in the per-user Run key) ---
function Set-RunAtStartup([bool]$enabled) {
    if ($enabled) {
        Set-ItemProperty -Path $startupRegPath -Name $startupValueName -Value "`"$PSScriptRoot\MouseMover.vbs`""
    } else {
        Remove-ItemProperty -Path $startupRegPath -Name $startupValueName -ErrorAction SilentlyContinue
    }
    $menuStartup.Checked = $enabled
}

$menuStartup = New-Object System.Windows.Forms.ToolStripMenuItem
$menuStartup.Text = "Run at startup"
$menuStartup.Add_Click({ Set-RunAtStartup (-not $menuStartup.Checked) })
$trayMenu.Items.Add($menuStartup) | Out-Null

# Reflect current registry state without writing to it (avoids rewriting on every launch).
$menuStartup.Checked = [bool](Get-ItemProperty -Path $startupRegPath -Name $startupValueName -ErrorAction SilentlyContinue)

$trayMenu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator)) | Out-Null

$menuExit = New-Object System.Windows.Forms.ToolStripMenuItem
$menuExit.Text = "Exit"
$menuExit.Add_Click({ $form.Close() })
$trayMenu.Items.Add($menuExit) | Out-Null

$trayIcon = New-Object System.Windows.Forms.NotifyIcon
$trayIcon.Icon            = $iconStopped
$trayIcon.Text            = "Mouse Mover"
$trayIcon.ContextMenuStrip = $trayMenu
$trayIcon.Visible         = $true

$trayIcon.Add_DoubleClick({
    $form.Show()
    $form.WindowState = [System.Windows.Forms.FormWindowState]::Normal
    $form.Activate()
})

# --- Closing the window exits for real; minimizing hides to tray ---
function Stop-MouseMover {
    if ($script:stopped) { return }
    $timer.Stop()
    $timer.Dispose()
    $trayIcon.Visible = $false
    $trayIcon.Dispose()
    if ($script:singletonMutex) {
        $script:singletonMutex.ReleaseMutex()
        $script:singletonMutex.Dispose()
        $script:singletonMutex = $null
    }
    $script:stopped = $true
}

$form.Add_FormClosing({ Stop-MouseMover })

$script:formLoaded = $false
$form.Add_Shown({ $script:formLoaded = $true })

$form.Add_Resize({
    # WinForms can transiently report Minimized during initial layout; ignore until shown.
    if ($script:formLoaded -and $form.WindowState -eq [System.Windows.Forms.FormWindowState]::Minimized) {
        # Restore before hiding — hiding while still Minimized leaves a stuck taskbar entry.
        $form.WindowState = [System.Windows.Forms.FormWindowState]::Normal
        $form.Hide()
    }
})

try {
    [System.Windows.Forms.Application]::Run($form)
} finally {
    # Backstop: ensures teardown runs even on a crash, avoiding ghost tray icons.
    Stop-MouseMover
}
