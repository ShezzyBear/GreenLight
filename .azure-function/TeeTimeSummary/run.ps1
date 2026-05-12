# -----------------------------------------------------------------------------
# TeeTimeSummary/run.ps1
# Timer Trigger - Fires daily at 8 AM Eastern (13:00 UTC / EDT offset)
# Sends a morning digest of all active searches. Silent exit if none.
# -----------------------------------------------------------------------------

param($Timer)

# --- Config from App Settings -------------------------------------------------
$BotToken       = $env:TELEGRAM_BOT_TOKEN
$AuthChatId     = $env:TELEGRAM_CHAT_ID
$StorageAccount = $env:STORAGE_ACCOUNT_NAME
$StorageKey     = $env:STORAGE_ACCOUNT_KEY
$TableName      = 'ActiveSearches'

Write-Host "TeeTimeSummary fired at $(Get-Date -Format 'o')"

# --- Helper: Send Telegram message --------------------------------------------
function Send-TelegramMessage {
    param([string]$Text)
    $Uri  = "https://api.telegram.org/bot$BotToken/sendMessage"
    $Body = @{ chat_id = $AuthChatId; text = $Text }
    try {
        Invoke-RestMethod -Uri $Uri -Method Post -Body $Body | Out-Null
    } catch {
        Write-Host "Telegram send error: $_"
    }
}

# --- Helper: Convert UTC ISO string to Eastern time label ---------------------
function Format-EasternTime {
    param([string]$UtcIsoString)
    try {
        $Utc     = [datetime]::Parse($UtcIsoString, $null, [System.Globalization.DateTimeStyles]::RoundtripKind)
        $Eastern = [System.TimeZoneInfo]::ConvertTimeBySystemTimeZoneId($Utc, 'America/New_York')
        return $Eastern.ToString('h:mm tt') + ' ET'
    } catch {
        return $UtcIsoString
    }
}

# --- Main: fetch active searches and send digest ------------------------------

$StorageCtx = New-AzStorageContext -StorageAccountName $StorageAccount -StorageAccountKey $StorageKey
$Table      = Get-AzStorageTable -Name $TableName -Context $StorageCtx

$Query   = [Microsoft.Azure.Cosmos.Table.TableQuery]::new()
$Filter  = [Microsoft.Azure.Cosmos.Table.TableQuery]::GenerateFilterCondition('PartitionKey', 'eq', $AuthChatId)
$Filter2 = [Microsoft.Azure.Cosmos.Table.TableQuery]::GenerateFilterCondition('Status', 'eq', 'active')
$Query.FilterString = [Microsoft.Azure.Cosmos.Table.TableQuery]::CombineFilters($Filter, 'and', $Filter2)

$Searches = @($Table.CloudTable.ExecuteQuery($Query))

if ($Searches.Count -eq 0) {
    Write-Host "No active searches - skipping summary."
    return
}

Write-Host "Sending morning summary for $($Searches.Count) active search(es)."

$Lines = @('Good morning! Here''s what I''m watching today:', '')

foreach ($Search in $Searches) {
    $DateKey        = $Search.RowKey
    $DateObj        = [datetime]::ParseExact($DateKey, 'yyyy-MM-dd', $null)
    $DateLabel      = $DateObj.ToString('dddd, dd MMMM yyyy')
    $Players        = $Search.Properties['Players'].Int32Value
    $LastCheckedRaw = $Search.Properties['LastChecked'].StringValue
    $LastCheckedET  = Format-EasternTime -UtcIsoString $LastCheckedRaw

    $Lines += "- $DateLabel — $Players player(s)"
    $Lines += "  Last checked: $LastCheckedET"
    $Lines += ''
}

$Lines += "I'll keep checking every 30 minutes and alert you the moment a slot opens up."

Send-TelegramMessage ($Lines -join "`n")

Write-Host "TeeTimeSummary completed at $(Get-Date -Format 'o')"