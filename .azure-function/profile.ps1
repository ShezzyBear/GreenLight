# profile.ps1 - Runs on Function App cold start
# Azure Functions PowerShell profile

# Import bundled Az modules explicitly rather than relying on managed dependencies
Import-Module "$PSScriptRoot/Modules/Az.Accounts/5.4.0/Az.Accounts.psd1" -Force
Import-Module "$PSScriptRoot/Modules/Az.Storage/6.0.1/Az.Storage.psd1" -Force

# Set error preference
$ErrorActionPreference = 'Stop'