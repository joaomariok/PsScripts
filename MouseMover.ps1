param(
    [int]$IntervalSeconds = 60
)

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

[System.Windows.Forms.Application]::SetHighDpiMode([System.Windows.Forms.HighDpiMode]::PerMonitorV2) | Out-Null

# Win32 API for getting cursor position and detecting movement
Add-Type @"
using System;
using System.Runtime.InteropServices;
public class MouseHelper {
    [DllImport("user32.dll")]
    public static extern bool GetCursorPos(out POINT lpPoint);

    [DllImport("user32.dll")]
    public static extern bool SetCursorPos(int X, int Y);

    [StructLayout(LayoutKind.Sequential)]
    public struct POINT { public int X; public int Y; }
}
"@

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

    # Check whether the user moved the mouse since the last tick
    $p = New-Object MouseHelper+POINT
    [MouseHelper]::GetCursorPos([ref]$p) | Out-Null

    $moved = ($script:lastPos -ne $null) -and (($p.X -ne $script:lastPos.X) -or ($p.Y -ne $script:lastPos.Y))

    if (-not $moved) {
        $screens   = [System.Windows.Forms.Screen]::AllScreens
        $primary   = $screens[0].Bounds
        $targetX   = $script:rng.Next($primary.Left, $primary.Right)
        $targetY   = $script:rng.Next($primary.Top,  $primary.Bottom)
        [MouseHelper]::SetCursorPos($targetX, $targetY) | Out-Null
        $p.X = $targetX
        $p.Y = $targetY
    }

    $script:lastPos = $p
})

# --- Button click ---
$btn.Add_Click({
    $script:running = -not $script:running

    if ($script:running) {
        # Capture current position and start fresh timer
        $p = New-Object MouseHelper+POINT
        [MouseHelper]::GetCursorPos([ref]$p) | Out-Null
        $script:lastPos  = $p
        $timer.Start()

        $btn.Text      = "Stop"
        $btn.BackColor = [System.Drawing.Color]::FromArgb(200, 60, 60)
    } else {
        $timer.Stop()
        $script:lastPos = $null

        $btn.Text      = "Start"
        $btn.BackColor = [System.Drawing.Color]::FromArgb(0, 180, 100)
    }
})

# --- Cleanup on close ---
$form.Add_FormClosing({
    $timer.Stop()
    $timer.Dispose()
})

[System.Windows.Forms.Application]::Run($form)
