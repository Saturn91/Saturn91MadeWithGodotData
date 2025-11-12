#!/usr/bin/env pwsh

# Run the validation script and show output in PowerShell
$bashPath = "C:\Program Files\Git\bin\bash.exe"

if (Test-Path $bashPath) {
    & $bashPath -c "./.scripts/validate-and-update.sh"
    exit $LASTEXITCODE
} else {
    Write-Host "Git Bash not found at $bashPath" -ForegroundColor Red
    Write-Host "Please install Git for Windows or update the path in this script" -ForegroundColor Yellow
    exit 1
}
