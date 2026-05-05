# ─────────────────────────────────────────────────────────────────────────────
# TeeTimeScheduler/run.ps1
# Timer Trigger - Runs every 4 hours, checks all active searches and notifies
# ─────────────────────────────────────────────────────────────────────────────

param($Timer)

# ─── Config ──────────────────────────────────────────────────────────────────
$BotToken       = $env:TELEGRAM_BOT_TOKEN
$AuthChatId     = $env:TELEGRAM_CHAT_ID
$StorageAccount = $env:STORAGE_ACCOUNT_NAME
$StorageKey     = $env:STORAGE_ACCOUNT_KEY
$TableName      = 'ActiveSearches'

$WindowStart    = '08:30'
$WindowEnd      = '10:30'

$Courses = @(
    @{ Name = 'Rocky Point'; BookingClassId = 20276; ScheduleId = 10;   BookingUrl = 'https://foreupsoftware.com/index.php/booking/a/20276/10'    }
    @{ Name = 'Fox Hollow';  BookingClassId = 19563; ScheduleId = $null; BookingUrl = 'https://foreupsoftware.com/index.php/booking/index/19563' }
)

Write-Host "TeeTimeScheduler fired at $(Get-Date -Format 'o')"

# ─── Helper: Send Telegram message ───────────────────────────────────────────
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

# ─── Helper: Get all active searches from Table Storage ───────────────────────
function Get-ActiveSearches {
    $StorageCtx = New-AzStorageContext -StorageAccountName $StorageAccount -StorageAccountKey $StorageKey
    $Table      = Get-AzStorageTable -Name $TableName -Context $StorageCtx

    $Query   = [Microsoft.Azure.Cosmos.Table.TableQuery]::new()
    $Filter  = [Microsoft.Azure.Cosmos.Table.TableQuery]::GenerateFilterCondition('Status', 'eq', 'active')
    $Query.FilterString = $Filter

    return @{ Table = $Table; Entities = $Table.CloudTable.ExecuteQuery($Query) }
}

# ─── Helper: Update LastChecked timestamp ─────────────────────────────────────
function Update-LastChecked {
    param($Table, $Entity)
    $Entity.Properties['LastChecked'] = [Microsoft.Azure.Cosmos.Table.EntityProperty]::GeneratePropertyForString((Get-Date -Format 'o'))
    $Table.CloudTable.Execute([Microsoft.Azure.Cosmos.Table.TableOperation]::Replace($Entity)) | Out-Null
}

# ─── Helper: Mark search as completed ────────────────────────────────────────
function Complete-Search {
    param($Table, $Entity)
    $Entity.Properties['Status'] = [Microsoft.Azure.Cosmos.Table.EntityProperty]::GeneratePropertyForString('found')
    $Table.CloudTable.Execute([Microsoft.Azure.Cosmos.Table.TableOperation]::Replace($Entity)) | Out-Null
}

# ─── Helper: Check ForeUp for available tee times ────────────────────────────
function Get-TeeTimeHits {
    param([string]$DateStr, [int]$Players)

    $Hits = @()

    foreach ($Course in $Courses) {
        $Uri    = 'https://foreupsoftware.com/index.php/api/booking/times'
        $Params = @{
            time          = 'all'
            date          = $DateStr
            holes         = 'all'
            players       = $Players
            booking_class = $Course.BookingClassId
            specials_only = 0
            api_key       = 'no_limits'
        }
        if ($Course.ScheduleId) { $Params['schedule_id'] = $Course.ScheduleId }

        try {
            $Headers  = @{ 'X-Requested-With' = 'XMLHttpRequest' }
            $Response = Invoke-RestMethod -Uri $Uri -Method Get -Body $Params -Headers $Headers -TimeoutSec 15

            if ($Response -is [array]) {
                foreach ($Slot in $Response) {
                    try {
                        $SlotTime = [datetime]::ParseExact($Slot.time.Trim().ToLower(), 'h:mmtt', $null)
                        $SlotStr  = $SlotTime.ToString('HH:mm')
                        if ($SlotStr -ge $WindowStart -and $SlotStr -le $WindowEnd) {
                            $Hits += @{
                                Course  = $Course.Name
                                Time    = $Slot.time
                                Holes   = $Slot.holes
                                Spots   = $Slot.available_spots
                                BookUrl = $Course.BookingUrl
                            }
                        }
                    } catch { continue }
                }
            }
        } catch {
            Write-Host "ForeUp error for $($Course.Name) on $DateStr : $_"
        }
    }

    return $Hits
}

# ─── Main: fetch and process all active searches ──────────────────────────────

$Result = Get-ActiveSearches
$Table    = $Result.Table
$Searches = $Result.Entities

if ($null -eq $Searches -or @($Searches).Count -eq 0) {
    Write-Host "No active searches found. Nothing to check."
    return
}

Write-Host "Found $(@($Searches).Count) active search(es) to check."

foreach ($Search in $Searches) {
    $DateKey   = $Search.RowKey                         # yyyy-MM-dd
    $Players   = $Search.Properties['Players'].Int32Value
    $DateObj   = [datetime]::ParseExact($DateKey, 'yyyy-MM-dd', $null)
    $DateLabel = $DateObj.ToString('dddd, dd MMMM yyyy')
    $DateStr   = $DateObj.ToString('MM-dd-yyyy')        # ForeUp format

    Write-Host "Checking $DateKey for $Players player(s)..."

    # Skip if date has already passed
    if ($DateObj.Date -lt (Get-Date).Date) {
        Write-Host "Date $DateKey has passed - marking inactive"
        $Search.Properties['Status'] = [Microsoft.Azure.Cosmos.Table.EntityProperty]::GeneratePropertyForString('expired')
        $Table.CloudTable.Execute([Microsoft.Azure.Cosmos.Table.TableOperation]::Replace($Search)) | Out-Null
        Send-TelegramMessage "The date you were watching ($DateLabel) has passed without a tee time being found. Send me a new date if you'd like to search again."
        continue
    }

    $Hits = Get-TeeTimeHits -DateStr $DateStr -Players $Players

    Update-LastChecked -Table $Table -Entity $Search

    if ($Hits.Count -gt 0) {
        $Lines = @("Tee time found!", "", "$DateLabel - $Players player(s)", "")
        foreach ($Hit in $Hits) {
            $Lines += "- $($Hit.Course) @ $($Hit.Time)"
            $Lines += "  $($Hit.Holes) holes | $($Hit.Spots) spot(s) open"
            $Lines += "  Book: $($Hit.BookUrl)"
            $Lines += ""
        }
        $Lines += "Send `"Done`" or `"I've booked it`" once secured!"
        Send-TelegramMessage ($Lines -join "`n")

        # NOTE: We do NOT auto-complete the search here so you keep getting
        # alerts until you explicitly confirm you've booked it.
    } else {
        Write-Host "No hits for $DateKey - will check again next cycle."
    }
}

Write-Host "TeeTimeScheduler completed at $(Get-Date -Format 'o')"
