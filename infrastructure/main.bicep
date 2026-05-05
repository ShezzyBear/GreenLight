// ─────────────────────────────────────────────────────────────────────────────
// Tee Time Alerts - Azure Function App Infrastructure
// Region: East US 2
//
// NOTE: Currently using B1 Basic plan due to Dynamic VM quota limit on
// Development subscription. When migrating to Production, revert the
// following two changes:
//   1. appServicePlan sku: change name='B1'/tier='Basic' back to name='Y1'/tier='Dynamic'
//   2. functionApp kind: change 'app' back to 'functionapp'
//   3. Restore these two appSettings entries:
//        { name: 'WEBSITE_CONTENTAZUREFILECONNECTIONSTRING', value: '...' }
//        { name: 'WEBSITE_CONTENTSHARE', value: toLower(functionAppName) }
//        { name: 'WEBSITE_RUN_FROM_PACKAGE', value: '1' }
// ─────────────────────────────────────────────────────────────────────────────

@description('Azure region for all resources')
param location string = 'eastus2'

@description('Function App name')
param functionAppName string

@description('Storage account name')
param storageAccountName string

@description('Telegram Bot Token (stored as secret)')
@secure()
param telegramBotToken string

@description('Telegram Chat ID')
param telegramChatId string

@description('Environment tag')
param environment string = 'Development'

// ─── Variables ───────────────────────────────────────────────────────────────

var appServicePlanName = 'asp-${functionAppName}'
var appInsightsName    = 'appi-${functionAppName}'
var tags = {
  Environment: environment
  Project:     'TeeTimeAlerts'
  ManagedBy:   'Bicep'
}

// ─── Storage Account ─────────────────────────────────────────────────────────

resource storageAccount 'Microsoft.Storage/storageAccounts@2023-01-01' = {
  name:     storageAccountName
  location: location
  tags:     tags
  sku: {
    name: 'Standard_LRS'
  }
  kind: 'StorageV2'
  properties: {
    supportsHttpsTrafficOnly:      true
    minimumTlsVersion:             'TLS1_2'
    allowBlobPublicAccess:         false
    networkAcls: {
      defaultAction: 'Allow'
      bypass:        'AzureServices'
    }
  }
}

// ─── Table Service (for active search state) ─────────────────────────────────

resource tableService 'Microsoft.Storage/storageAccounts/tableServices@2023-01-01' = {
  name:   'default'
  parent: storageAccount
}

resource activeSearchesTable 'Microsoft.Storage/storageAccounts/tableServices/tables@2023-01-01' = {
  name:   'ActiveSearches'
  parent: tableService
}

// ─── Application Insights ────────────────────────────────────────────────────

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

// ─── Basic App Service Plan (B1) ─────────────────────────────────────────────
// PRODUCTION REVERT: Change to name='Y1', tier='Dynamic' for Consumption plan

resource appServicePlan 'Microsoft.Web/serverfarms@2023-01-01' = {
  name:     appServicePlanName
  location: location
  tags:     tags
  sku: {
    name: 'B1'
    tier: 'Basic'
  }
  properties: {
    reserved: false   // false = Windows
  }
}

// ─── Function App ─────────────────────────────────────────────────────────────
// PRODUCTION REVERT: Change kind back to 'functionapp' and restore
// WEBSITE_CONTENTAZUREFILECONNECTIONSTRING, WEBSITE_CONTENTSHARE,
// and WEBSITE_RUN_FROM_PACKAGE app settings

resource functionApp 'Microsoft.Web/sites@2023-01-01' = {
  name:     functionAppName
  location: location
  tags:     tags
  kind:     'app'
  properties: {
    serverFarmId: appServicePlan.id
    httpsOnly:    true
    siteConfig: {
      powerShellVersion: '7.4'
      ftpsState:         'Disabled'
      minTlsVersion:     '1.2'
      appSettings: [
        {
          name:  'AzureWebJobsStorage'
          value: 'DefaultEndpointsProtocol=https;AccountName=${storageAccount.name};AccountKey=${storageAccount.listKeys().keys[0].value};EndpointSuffix=core.windows.net'
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

// ─── Outputs ─────────────────────────────────────────────────────────────────

output functionAppName     string = functionApp.name
output functionAppHostname string = functionApp.properties.defaultHostName
output storageAccountName  string = storageAccount.name
output webhookUrl          string = 'https://${functionApp.properties.defaultHostName}/api/TeeTimeBot'
