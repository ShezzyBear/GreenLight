# -----------------------------------------------------------------------------
# TeeTimeScheduler/run.ps1
# Timer Trigger - Runs every 30 minutes, checks all active searches and notifies
# -----------------------------------------------------------------------------

param($Timer)

# --- Config from App Settings -------------------------------------------------
$BotToken       = $env:TELEGRAM_BOT_TOKEN
$AuthChatId     = $env:TELEGRAM_CHAT_ID
$StorageAccount = $env:STORAGE_ACCOUNT_NAME
$StorageKey     = $env:STORAGE_ACCOUNT_KEY
$TableName      = 'ActiveSearches'

$WindowStart    = '08:30'
$WindowEnd      = '10:30'

$Courses = @(
    @{ Name = 'Rocky Point'; BookingClassId = 35; ScheduleId = 4171; BookingUrl = 'https://foreupsoftware.com/index.php/booking/a/20276/10#/teetimes' }
    @{ Name = 'Fox Hollow';  BookingClassId = 35; ScheduleId = 4170; BookingUrl = 'https://foreupsoftware.com/index.php/booking/a/20276/10#/teetimes' }
)

Write-Host "TeeTimeScheduler fired at $(Get-Date -Format 'o')"

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

# --- Helper: Get all active searches from Table Storage -----------------------
function Get-ActiveSearches {
    $StorageCtx = New-AzStorageContext -StorageAccountName $StorageAccount -StorageAccountKey $StorageKey
    $Table      = Get-AzStorageTable -Name $TableName -Context $StorageCtx

    $Query   = [Microsoft.Azure.Cosmos.Table.TableQuery]::new()
    $Filter  = [Microsoft.Azure.Cosmos.Table.TableQuery]::GenerateFilterCondition('Status', 'eq', 'active')
    $Query.FilterString = $Filter

    return @{ Table = $Table; Entities = $Table.CloudTable.ExecuteQuery($Query) }
}

# --- Helper: Update LastChecked timestamp and CheckCount ----------------------
function Update-SearchState {
    param($Table, $Entity, [int]$CheckCount)
    $Entity.Properties['LastChecked']  = [Microsoft.Azure.Cosmos.Table.EntityProperty]::GeneratePropertyForString((Get-Date -Format 'o'))
    $Entity.Properties['CheckCount']   = [Microsoft.Azure.Cosmos.Table.EntityProperty]::GeneratePropertyForInt($CheckCount)
    $Table.CloudTable.Execute([Microsoft.Azure.Cosmos.Table.TableOperation]::Replace($Entity)) | Out-Null
}

# --- Helper: Mark search as completed -----------------------------------------
function Complete-Search {
    param($Table, $Entity)
    $Entity.Properties['Status'] = [Microsoft.Azure.Cosmos.Table.EntityProperty]::GeneratePropertyForString('found')
    $Table.CloudTable.Execute([Microsoft.Azure.Cosmos.Table.TableOperation]::Replace($Entity)) | Out-Null
}

# --- Helper: Check ForeUp for available tee times ----------------------------
function Get-TeeTimeHits {
    param([string]$DateStr, [int]$Players)

    $Hits = @()

    foreach ($Course in $Courses) {
        $Uri = 'https://foreupsoftware.com/index.php/api/booking/times'
        $QueryString = [System.Web.HttpUtility]::ParseQueryString('')
        $QueryString.Add('time',           'all')
        $QueryString.Add('date',           $DateStr)
        $QueryString.Add('holes',          'all')
        $QueryString.Add('players',        $Players.ToString())
        $QueryString.Add('booking_class',  $Course.BookingClassId.ToString())
        $QueryString.Add('schedule_id',    $Course.ScheduleId.ToString())
        $QueryString.Add('schedule_ids[]', '4169')
        $QueryString.Add('schedule_ids[]', '4170')
        $QueryString.Add('schedule_ids[]', '4168')
        $QueryString.Add('schedule_ids[]', '4171')
        $QueryString.Add('schedule_ids[]', '4177')
        $QueryString.Add('specials_only',  '0')
        $QueryString.Add('api_key',        'no_limits')
        $QueryString.Add('is_aggregate',   'true')

        $FullUri = "$Uri`?$($QueryString.ToString())"
        $Headers = @{
            'X-Requested-With' = 'XMLHttpRequest'
            'User-Agent'       = 'Mozilla/5.0'
            'Referer'          = 'https://foreupsoftware.com/'
        }

        try {
            $Response = Invoke-RestMethod -Uri $FullUri -Method Get -Headers $Headers -TimeoutSec 15

            if ($Response -is [array]) {
                foreach ($Slot in $Response) {
                    try {
                        $SlotTime = $null
                        $TimeStr  = $Slot.time.Trim()

                        # Format 1: full datetime "2026-05-09 16:00"
                        if ($TimeStr -match '^\d{4}-\d{2}-\d{2} \d{2}:\d{2}$') {
                            try { $SlotTime = [datetime]::ParseExact($TimeStr, 'yyyy-MM-dd HH:mm', $null) } catch {}
                        }

                        # Format 2: 12-hour "9:00am" or "10:30am"
                        if ($null -eq $SlotTime) {
                            foreach ($fmt in @('h:mmtt', 'hh:mmtt', 'h:mm tt', 'hh:mm tt')) {
                                try {
                                    $SlotTime = [datetime]::ParseExact($TimeStr.ToLower(), $fmt, $null)
                                    break
                                } catch { continue }
                            }
                        }

                        if ($null -eq $SlotTime) {
                            Write-Host "Could not parse time: '$($Slot.time)' - skipping"
                            continue
                        }

                        $SlotStr = $SlotTime.ToString('HH:mm')
                        if ($SlotStr -ge $WindowStart -and $SlotStr -le $WindowEnd) {
                            $Hits += @{
                                Course  = $Course.Name
                                Time    = $SlotTime.ToString('h:mmtt').ToLower()
                                Holes   = $Slot.holes
                                Spots   = $Slot.available_spots
                                BookUrl = $Course.BookingUrl
                            }
                        }
                    } catch {
                        Write-Host "Slot parse error: $_"
                    }
                }
            }
        } catch {
            Write-Host "ForeUp error for $($Course.Name) on $DateStr : $_"
        }
    }

    return $Hits
}

# --- Main: fetch and process all active searches ------------------------------

$Result   = Get-ActiveSearches
$Table    = $Result.Table
$Searches = $Result.Entities

if ($null -eq $Searches -or @($Searches).Count -eq 0) {
    Write-Host "No active searches found. Nothing to check."
    return
}

Write-Host "Found $(@($Searches).Count) active search(es) to check."

foreach ($Search in $Searches) {
    $DateKey   = $Search.RowKey                          # yyyy-MM-dd
    $Players   = $Search.Properties['Players'].Int32Value
    $DateObj   = [datetime]::ParseExact($DateKey, 'yyyy-MM-dd', $null)
    $DateLabel = $DateObj.ToString('dddd, dd MMMM yyyy')
    $DateStr   = $DateObj.ToString('MM-dd-yyyy')         # ForeUp format

    # Read CheckCount - default to 0 if property does not exist yet
    $CheckCount = 0
    if ($Search.Properties.ContainsKey('CheckCount') -and $null -ne $Search.Properties['CheckCount'].Int32Value) {
        $CheckCount = $Search.Properties['CheckCount'].Int32Value
    }
    $CheckCount++

    Write-Host "Checking $DateKey for $Players player(s) (check #$CheckCount)..."

    # Skip if date has already passed
    if ($DateObj.Date -lt (Get-Date).Date) {
        Write-Host "Date $DateKey has passed - marking expired"
        $Search.Properties['Status'] = [Microsoft.Azure.Cosmos.Table.EntityProperty]::GeneratePropertyForString('expired')
        $Table.CloudTable.Execute([Microsoft.Azure.Cosmos.Table.TableOperation]::Replace($Search)) | Out-Null
        Send-TelegramMessage "The date you were watching ($DateLabel) has passed without a tee time being found. Send me a new date if you'd like to search again."
        continue
    }

    $Hits = Get-TeeTimeHits -DateStr $DateStr -Players $Players

    # Persist updated CheckCount and LastChecked regardless of result
    Update-SearchState -Table $Table -Entity $Search -CheckCount $CheckCount

    if ($Hits.Count -gt 0) {
        $Lines = @("Tee time found!", "", "$DateLabel - $Players player(s)", "")
        foreach ($Hit in $Hits) {
            $Lines += "- $($Hit.Course) @ $($Hit.Time)"
            $Lines += "  $($Hit.Holes) holes | $($Hit.Spots) spot(s) open"
            $Lines += "  Book: $($Hit.BookUrl)"
            $Lines += ""
        }
        $Lines += "Send ``Done`` or ``I've booked it`` once secured!"
        Send-TelegramMessage ($Lines -join "`n")

        # NOTE: We do NOT auto-complete the search here so you keep getting
        # alerts until you explicitly confirm you've booked it.
    } else {
        Write-Host "No hits for $DateKey - will check again next cycle."
    }
}

Write-Host "TeeTimeScheduler completed at $(Get-Date -Format 'o')"