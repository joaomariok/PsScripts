# config.ps1
$RemoteName  = 'MEGA:'
$DriveLetter = 'M:'
$LogFile     = "$env:USERPROFILE\rclone_mega.log"
$RcAddress   = '127.0.0.1:5572'
$LogLevel    = 'INFO'   # set to 'DEBUG' when troubleshooting
$PidFile     = "$PSScriptRoot\.rclone_mega.pid"
