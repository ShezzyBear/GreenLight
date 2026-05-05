# profile.ps1 - Runs on Function App cold start
# Azure Functions PowerShell profile

# Uncomment to enable Az module authentication via managed identity
# if ($env:MSI_ENDPOINT) {
#     Connect-AzAccount -Identity
# }

# Set error preference
$ErrorActionPreference = 'Stop'
