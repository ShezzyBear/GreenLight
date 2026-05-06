# -----------------------------------------------------------------------------
# TeeTimeBot/run.ps1
# HTTP Trigger - Receives Telegram webhook messages and manages tee time searches
# -----------------------------------------------------------------------------

param($Request, $TriggerMetadata)

# --- Config from App Settings -------------------------------------------------
$BotToken       = $env:TELEGRAM_BOT_TOKEN
$AuthChatId     = $env:TELEGRAM_CHAT_ID
$StorageAccount = $env:STORAGE_ACCOUNT_NAME
$StorageKey     = $env:STORAGE_ACCOUNT_KEY
$SecretToken    = $env:TELEGRAM_SECRET_TOKEN
$TableName      = 'ActiveSearches'

$WindowStart    = '08:30'
$WindowEnd      = '10:30'

$Courses = @(
    @{ Name = 'Rocky Point'; BookingClassId = 35; ScheduleId = 4171; BookingUrl = 'https://foreupsoftware.com/index.php/booking/a/20276/10#/teetimes' }
    @{ Name = 'Fox Hollow';  BookingClassId = 35; ScheduleId = 4170; BookingUrl = 'https://foreupsoftware.com/index.php/booking/a/20276/10#/teetimes' }
)

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

# --- Helper: Get Storage Table context ----------------------------------------
function Get-TableContext {
    $StorageCtx = New-AzStorageContext -StorageAccountName $StorageAccount -StorageAccountKey $StorageKey
    return Get-AzStorageTable -Name $TableName -Context $StorageCtx
}

# --- Helper: Parse date from natural language ---------------------------------
function Parse-Date {
    param([string]$Text)

    # Try exact YYYY-MM-DD
    if ($Text -match '\b(\d{4}-\d{2}-\d{2})\b') {
        try { return [datetime]::ParseExact($Matches[1], 'yyyy-MM-dd', $null) } catch {}
    }

    # Strip ordinal suffixes directly after numbers (17th -> 17, 1st -> 1, etc.)
    $CleanText = $Text.ToLower() -replace '(\d+)(st|nd|rd|th)', '$1'

    $MonthNames = @{
        january=1; jan=1; february=2; feb=2; march=3; mar=3
        april=4; apr=4; may=5; june=6; jun=6; july=7; jul=7
        august=8; aug=8; september=9; sep=9; sept=9
        october=10; oct=10; november=11; nov=11; december=12; dec=12
    }

    foreach ($MonthName in $MonthNames.Keys) {
        # "May 17" pattern
        if ($CleanText -match "\b$MonthName\s+(\d{1,2})\b") {
            $Day   = [int]$Matches[1]
            $Month = $MonthNames[$MonthName]
            $Year  = (Get-Date).Year
            try {
                $Candidate = Get-Date -Year $Year -Month $Month -Day $Day -Hour 0 -Minute 0 -Second 0
                if ($Candidate.Date -lt (Get-Date).Date) { $Candidate = $Candidate.AddYears(1) }
                return $Candidate
            } catch { continue }
        }
        # "17 May" pattern
        if ($CleanText -match "\b(\d{1,2})\s+$MonthName\b") {
            $Day   = [int]$Matches[1]
            $Month = $MonthNames[$MonthName]
            $Year  = (Get-Date).Year
            try {
                $Candidate = Get-Date -Year $Year -Month $Month -Day $Day -Hour 0 -Minute 0 -Second 0
                if ($Candidate.Date -lt (Get-Date).Date) { $Candidate = $Candidate.AddYears(1) }
                return $Candidate
            } catch { continue }
        }
    }

    # Day-of-week fallback (e.g. "Sunday", "next Saturday")
    $DayNames = @{ sunday=0; monday=1; tuesday=2; wednesday=3; thursday=4; friday=5; saturday=6 }
    foreach ($DayName in $DayNames.Keys) {
        if ($CleanText -match "\b$DayName\b") {
            $TargetDow = $DayNames[$DayName]
            $Today     = (Get-Date).Date
            $DaysAhead = ($TargetDow - [int]$Today.DayOfWeek + 7) % 7
            if ($DaysAhead -eq 0) { $DaysAhead = 7 }
            return $Today.AddDays($DaysAhead)
        }
    }

    return $null
}

# --- Helper: Parse player count -----------------------------------------------
function Parse-Players {
    param([string]$Text)
    if ($Text -match '\b([1-4])\s*(player|people|person|golfer)s?\b') { return [int]$Matches[1] }
    if ($Text -match '\b(one|1)\b')   { return 1 }
    if ($Text -match '\b(two|2)\b')   { return 2 }
    if ($Text -match '\b(three|3)\b') { return 3 }
    if ($Text -match '\b(four|4)\b')  { return 4 }
    return 2  # default
}

# --- Helper: Check ForeUp availability ----------------------------------------
function Get-TeeTimeHits {
    param([datetime]$Date, [int]$Players)

    $DateStr = $Date.ToString('MM-dd-yyyy')
    $Hits    = @()

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
            Write-Host "ForeUp error for $($Course.Name): $_"
        }
    }
    return $Hits
}

# --- Helper: Save active search to Table Storage ------------------------------
function Save-ActiveSearch {
    param([datetime]$Date, [int]$Players)

    $Table  = Get-TableContext
    $Entity = New-Object Microsoft.Azure.Cosmos.Table.DynamicTableEntity
    $Entity.PartitionKey              = $AuthChatId
    $Entity.RowKey                    = $Date.ToString('yyyy-MM-dd')
    $Entity.Properties['Players']     = [Microsoft.Azure.Cosmos.Table.EntityProperty]::GeneratePropertyForInt($Players)
    $Entity.Properties['Status']      = [Microsoft.Azure.Cosmos.Table.EntityProperty]::GeneratePropertyForString('active')
    $Entity.Properties['LastChecked'] = [Microsoft.Azure.Cosmos.Table.EntityProperty]::GeneratePropertyForString((Get-Date -Format 'o'))

    $Table.CloudTable.Execute([Microsoft.Azure.Cosmos.Table.TableOperation]::InsertOrReplace($Entity)) | Out-Null
}

# --- Helper: Cancel all active searches ---------------------------------------
function Stop-ActiveSearches {
    $Table   = Get-TableContext
    $Query   = [Microsoft.Azure.Cosmos.Table.TableQuery]::new()
    $Filter  = [Microsoft.Azure.Cosmos.Table.TableQuery]::GenerateFilterCondition('PartitionKey', 'eq', $AuthChatId)
    $Filter2 = [Microsoft.Azure.Cosmos.Table.TableQuery]::GenerateFilterCondition('Status', 'eq', 'active')
    $Query.FilterString = [Microsoft.Azure.Cosmos.Table.TableQuery]::CombineFilters($Filter, 'and', $Filter2)

    $Entities = $Table.CloudTable.ExecuteQuery($Query)
    $Count    = 0
    foreach ($Entity in $Entities) {
        $Entity.Properties['Status'] = [Microsoft.Azure.Cosmos.Table.EntityProperty]::GeneratePropertyForString('cancelled')
        $Table.CloudTable.Execute([Microsoft.Azure.Cosmos.Table.TableOperation]::Replace($Entity)) | Out-Null
        $Count++
    }
    return $Count
}

# --- Helper: Get active search summary ----------------------------------------
function Get-ActiveSearchSummary {
    $Table   = Get-TableContext
    $Query   = [Microsoft.Azure.Cosmos.Table.TableQuery]::new()
    $Filter  = [Microsoft.Azure.Cosmos.Table.TableQuery]::GenerateFilterCondition('PartitionKey', 'eq', $AuthChatId)
    $Filter2 = [Microsoft.Azure.Cosmos.Table.TableQuery]::GenerateFilterCondition('Status', 'eq', 'active')
    $Query.FilterString = [Microsoft.Azure.Cosmos.Table.TableQuery]::CombineFilters($Filter, 'and', $Filter2)

    return $Table.CloudTable.ExecuteQuery($Query)
}

# --- Main logic ---------------------------------------------------------------

# Validate Telegram secret token header - return 200 regardless to prevent retries
$IncomingToken = $Request.Headers['X-Telegram-Bot-Api-Secret-Token']
if ($IncomingToken -ne $SecretToken) {
    Write-Host "Invalid or missing secret token - ignoring request"
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{ StatusCode = 200; Body = 'OK' })
    return
}

# Return 200 OK immediately so Telegram does not retry while we process
Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{ StatusCode = 200; Body = 'OK' })

# Parse incoming Telegram webhook body
$Body    = $Request.Body
$Message = $Body.message
$ChatId  = $Message.chat.id
$Text    = $Message.text

Write-Host "Message received from chat $ChatId : $Text"

# Security: only process messages from your own chat
if ([string]$ChatId -ne $AuthChatId) {
    Write-Host "Unauthorised chat ID $ChatId - ignoring"
    return
}

$TextLower = $Text.ToLower().Trim()

# -- STOP / DONE / BOOKED ------------------------------------------------------
if ($TextLower -match '\b(stop|done|cancel|booked|i.ve booked|i have booked)\b') {
    $Cancelled = Stop-ActiveSearches
    if ($Cancelled -gt 0) {
        Send-TelegramMessage "Enjoy your round! I've stopped checking for tee times."
    } else {
        Send-TelegramMessage "No active searches to stop."
    }
    return
}

# -- STATUS --------------------------------------------------------------------
if ($TextLower -match '\b(status|what are you watching|what are you checking)\b') {
    $Active = Get-ActiveSearchSummary
    if ($null -eq $Active -or @($Active).Count -eq 0) {
        Send-TelegramMessage "No active tee time searches right now. Send me a date and player count to start one!"
    } else {
        $Lines = @('Active searches:')
        foreach ($E in $Active) {
            $Date    = $E.RowKey
            $Players = $E.Properties['Players'].Int32Value
            $Checked = $E.Properties['LastChecked'].StringValue
            $Lines  += "  - $Date for $Players player(s) (last checked: $Checked)"
        }
        Send-TelegramMessage ($Lines -join "`n")
    }
    return
}

# -- HELP ----------------------------------------------------------------------
if ($TextLower -match '\b(help|commands|what can you do)\b') {
    $HelpText = @"
Tee Time Bot - Commands

To start a search:
  "Looking for a tee time on May 17th for 2 players"
  "Can you check Sunday for 4 players"

To check status:
  "Status"

To stop searching:
  "Stop", "Done", "I've booked it"

I check Rocky Point and Fox Hollow for 8:30-10:30 AM slots every 4 hours automatically.
"@
    Send-TelegramMessage $HelpText
    return
}

# -- NEW SEARCH REQUEST --------------------------------------------------------
$ParsedDate    = Parse-Date -Text $Text
$ParsedPlayers = Parse-Players -Text $Text

if ($null -eq $ParsedDate) {
    Send-TelegramMessage "I couldn't work out which date you meant. Try something like:`n`n  `"Looking for a tee time on May 17th for 2 players`"`n  `"Check Sunday for 4 players`""
    return
}

$DateLabel = $ParsedDate.ToString('dddd, dd MMMM yyyy')

Send-TelegramMessage "Got it! Checking Rocky Point and Fox Hollow for $DateLabel ($ParsedPlayers player(s)) in the 8:30-10:30 AM window..."

# Save the search so the scheduler picks it up going forward
Save-ActiveSearch -Date $ParsedDate -Players $ParsedPlayers

# Do an immediate check right now
$Hits = Get-TeeTimeHits -Date $ParsedDate -Players $ParsedPlayers

if ($Hits.Count -gt 0) {
    $Lines = @("Found $($Hits.Count) slot(s) on $DateLabel :`n")
    foreach ($Hit in $Hits) {
        $Lines += "- $($Hit.Course) @ $($Hit.Time) ($($Hit.Holes) holes, $($Hit.Spots) spot(s))`n  Book: $($Hit.BookUrl)"
    }
    $Lines += "`nSend ``Done`` or ``I've booked it`` once you've secured your slot!"
    Send-TelegramMessage ($Lines -join "`n")
} else {
    Send-TelegramMessage "No times available right now in the 8:30-10:30 AM window for $DateLabel.`n`nI'll keep checking every 4 hours and ping you when something opens up. Send ``Stop`` at any time to cancel."
}