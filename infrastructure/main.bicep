// -----------------------------------------------------------------------------
// Tee Time Alerts - Azure Function App Infrastructure
// Region: East US
// Plan: Y1 Consumption
// -----------------------------------------------------------------------------

// --- Checkov Suppressions ----------------------------------------------------
// The following checks are suppressed via --skip-check in the pipeline.
// CKV_AZURE_43  : Storage account name is parameter-driven and follows Azure naming rules
// CKV_AZURE_59  : Storage networkAcls defaultAction set to Allow - Deny blocks Kudu filesystem access on Y1 Consumption plan (WEBSITE_CONTENTAZUREFILECONNECTIONSTRING file share becomes inaccessible)
// CKV_AZURE_206 : LRS replication is intentional for a low-cost development workload
// CKV_AZURE_225 : Zone redundancy is not supported on Y1 Consumption plan
// CKV_AZURE_16  : AAD authentication not required - webhook secured via Telegram secret token header
// CKV_AZURE_17  : Client certificates not applicable for a Telegram webhook receiver
// CKV_AZURE_71  : Managed identity migration is a backlog item - currently using storage account key
// CKV_AZURE_212 : Minimum instance count not configurable on Y1 Consumption plan
// CKV_AZURE_213 : Health check endpoint not warranted for this workload
// CKV_AZURE_222 : Public network access required for Telegram webhook delivery
// -----------------------------------------------------------------------------

@description('Azure region for all resources')
param location string = 'eastus'

@description('Function App name')
param functionAppName string

@description('Storage account name')
param storageAccountName string

@description('Telegram Bot Token (stored as secret)')
@secure()
param telegramBotToken string

@description('Telegram Chat ID')
param telegramChatId string

@description('Telegram webhook secret token')
@secure()
param telegramSecretToken string

@description('Environment tag')
param environment string = 'Development'

// --- Variables ---------------------------------------------------------------

var appServicePlanName = 'asp-use-green-light-dv'
var appInsightsName    = 'ais-use-green-light-dv'
var tags = {
  Environment: environment
  Project:     'TeeTimeAlerts'
  ManagedBy:   'Bicep'
}

// --- Storage Account ---------------------------------------------------------

resource storageAccount 'Microsoft.Storage/storageAccounts@2023-01-01' = {
  name:     storageAccountName
  location: location
  tags:     tags
  sku: {
    name: 'Standard_LRS'
  }
  kind: 'StorageV2'
  properties: {
    supportsHttpsTrafficOnly: true
    minimumTlsVersion:        'TLS1_2'
    allowBlobPublicAccess:    false
    networkAcls: {
      defaultAction: 'Allow'
      bypass:        'AzureServices'
    }
  }
}

// --- Table Service (for active search state) ---------------------------------

resource tableService 'Microsoft.Storage/storageAccounts/tableServices@2023-01-01' = {
  name:   'default'
  parent: storageAccount
}

resource activeSearchesTable 'Microsoft.Storage/storageAccounts/tableServices/tables@2023-01-01' = {
  name:   'ActiveSearches'
  parent: tableService
}

// --- Application Insights ----------------------------------------------------

resource appInsights 'Microsoft.Insights/components@2020-02-02' = {
  name:     appInsightsName
  location: location
  tags:     tags
  kind:     'web'
  properties: {
    Application_Type: 'web'
    RetentionInDays:  30
  }
}

// --- Y1 Consumption App Service Plan -----------------------------------------

resource appServicePlan 'Microsoft.Web/serverfarms@2023-01-01' = {
  name:     appServicePlanName
  location: location
  tags:     tags
  sku: {
    name: 'Y1'
    tier: 'Dynamic'
  }
}

// --- Function App ------------------------------------------------------------

resource functionApp 'Microsoft.Web/sites@2023-01-01' = {
  name:     functionAppName
  location: location
  tags:     tags
  kind:     'functionapp'
  properties: {
    serverFarmId: appServicePlan.id
    httpsOnly:    true
    siteConfig: {
      powerShellVersion: '7.5'
      ftpsState:         'Disabled'
      minTlsVersion:     '1.2'
      http20Enabled:     true
      appSettings: [
        {
          name:  'AzureWebJobsStorage'
          value: 'DefaultEndpointsProtocol=https;AccountName=${storageAccount.name};AccountKey=${storageAccount.listKeys().keys[0].value};EndpointSuffix=core.windows.net'
        }
        {
          name:  'WEBSITE_CONTENTAZUREFILECONNECTIONSTRING'
          value: 'DefaultEndpointsProtocol=https;AccountName=${storageAccount.name};AccountKey=${storageAccount.listKeys().keys[0].value};EndpointSuffix=core.windows.net'
        }
        {
          name:  'WEBSITE_CONTENTSHARE'
          value: functionAppName
        }
        {
          name:  'FUNCTIONS_EXTENSION_VERSION'
          value: '~4'
        }
        {
          name:  'FUNCTIONS_WORKER_RUNTIME'
          value: 'powershell'
        }
        {
          name:  'APPINSIGHTS_INSTRUMENTATIONKEY'
          value: appInsights.properties.InstrumentationKey
        }
        {
          name:  'APPLICATIONINSIGHTS_CONNECTION_STRING'
          value: appInsights.properties.ConnectionString
        }
        {
          name:  'TELEGRAM_BOT_TOKEN'
          value: telegramBotToken
        }
        {
          name:  'TELEGRAM_CHAT_ID'
          value: telegramChatId
        }
        {
          name:  'TELEGRAM_SECRET_TOKEN'
          value: telegramSecretToken
        }
        {
          name:  'STORAGE_ACCOUNT_NAME'
          value: storageAccount.name
        }
        {
          name:  'STORAGE_ACCOUNT_KEY'
          value: storageAccount.listKeys().keys[0].value
        }
      ]
    }
  }
}

// --- Outputs -----------------------------------------------------------------

output functionAppName     string = functionApp.name
output functionAppHostname string = functionApp.properties.defaultHostName
output storageAccountName  string = storageAccount.name
output webhookUrl          string = 'https://${functionApp.properties.defaultHostName}/api/TeeTimeBot'
