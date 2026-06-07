param(
    [int]$IntervalSeconds = 60
)

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

[System.Windows.Forms.Application]::SetHighDpiMode([System.Windows.Forms.HighDpiMode]::PerMonitorV2) | Out-Null

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

# --- Timer (fires every $IntervalSeconds) ---
$timer          = New-Object System.Windows.Forms.Timer
$timer.Interval = $IntervalSeconds * 1000

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
        $screens   = [System.Windows.Forms.Screen]::AllScreens
        $primary   = $screens[0].Bounds
        $targetX   = $script:rng.Next($primary.Left, $primary.Right)
        $targetY   = $script:rng.Next($primary.Top,  $primary.Bottom)

        $MOUSEEVENTF_MOVE     = 0x0001
        $MOUSEEVENTF_ABSOLUTE = 0x8000
        $mi = New-Object MouseHelper+MOUSEINPUT
        $mi.dx      = [int](($targetX - $primary.Left) * 65535 / [Math]::Max(1, $primary.Width  - 1))
        $mi.dy      = [int](($targetY - $primary.Top)  * 65535 / [Math]::Max(1, $primary.Height - 1))
        $mi.dwFlags = $MOUSEEVENTF_MOVE -bor $MOUSEEVENTF_ABSOLUTE

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
    } else {
        $timer.Stop()
        $script:lastPos = $null

        $btn.Text         = "Start"
        $btn.BackColor    = [System.Drawing.Color]::FromArgb(0, 180, 100)
        $menuToggle.Text  = "Start"
    }
}

$btn.Add_Click({ Switch-Running })

# --- Tray icon + context menu ---
$trayMenu = New-Object System.Windows.Forms.ContextMenuStrip

$menuToggle = New-Object System.Windows.Forms.ToolStripMenuItem
$menuToggle.Text = "Start"
$menuToggle.Add_Click({ Switch-Running })
$trayMenu.Items.Add($menuToggle) | Out-Null

$menuExit = New-Object System.Windows.Forms.ToolStripMenuItem
$menuExit.Text = "Exit"
$menuExit.Add_Click({ $form.Close() })
$trayMenu.Items.Add($menuExit) | Out-Null

$trayIcon = New-Object System.Windows.Forms.NotifyIcon
$trayIcon.Icon            = [System.Drawing.SystemIcons]::Application
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
    $timer.Stop()
    $timer.Dispose()
    $trayIcon.Visible = $false
    $trayIcon.Dispose()
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
