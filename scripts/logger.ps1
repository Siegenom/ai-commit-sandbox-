# This script provides a shared logging function for other scripts to use.

# Set the log file path relative to the main script's location.
$Global:LogFile = Join-Path -Path $PSScriptRoot -ChildPath "full_debug_log.txt"

# Define a global function so it can be called from the script that sources this file.
function Write-Log {
    param([string]$Message)
    
    $Timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss.fff"
    $LogEntry = "[$Timestamp] $Message"
    
    # Use Add-Content for appending to the file.
    try {
        $LogEntry | Add-Content -Path $Global:LogFile -Encoding UTF8 -ErrorAction Stop
    }
    catch {
        # If logging fails, write to the console as a fallback.
        Write-Host "LOGGING FAILED: $LogEntry" -ForegroundColor Red
    }
}

# Announce that the logger has been initialized.
# This message will appear in the log file itself.
Write-Log "--- LOGGER INITIALIZED ---"
