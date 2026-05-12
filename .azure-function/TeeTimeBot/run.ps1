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

$PendingCancelKey = 'pending-cancel'

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

# --- Helper: Convert UTC ISO string to Eastern time label ---------------------
function Format-EasternTime {
    param([string]$UtcIsoString)
    try {
        $Utc     = [datetime]::Parse($UtcIsoString, $null, [System.Globalization.DateTimeStyles]::RoundtripKind)
        $Eastern = [System.TimeZoneInfo]::ConvertTimeBySystemTimeZoneId($Utc, 'America/New_York')
        return $Eastern.ToString('dddd, dd MMMM yyyy') + ' at ' + $Eastern.ToString('h:mm tt') + ' ET'
    } catch {
        return $UtcIsoString
    }
}

# --- Helper: Build a readable date label from a RowKey (yyyy-MM-dd) -----------
function Format-DateLabel {
    param([string]$RowKey)
    $D = [datetime]::ParseExact($RowKey, 'yyyy-MM-dd', $null)
    return $D.ToString('dddd, dd MMMM yyyy')
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

# --- Helper: Get all active search entities -----------------------------------
function Get-ActiveSearchEntities {
    param($Table)
    $Query   = [Microsoft.Azure.Cosmos.Table.TableQuery]::new()
    $Filter  = [Microsoft.Azure.Cosmos.Table.TableQuery]::GenerateFilterCondition('PartitionKey', 'eq', $AuthChatId)
    $Filter2 = [Microsoft.Azure.Cosmos.Table.TableQuery]::GenerateFilterCondition('Status', 'eq', 'active')
    $Query.FilterString = [Microsoft.Azure.Cosmos.Table.TableQuery]::CombineFilters($Filter, 'and', $Filter2)
    return @($Table.CloudTable.ExecuteQuery($Query))
}

# --- Helper: Cancel a single entity -------------------------------------------
function Cancel-Entity {
    param($Table, $Entity)
    $Entity.Properties['Status'] = [Microsoft.Azure.Cosmos.Table.EntityProperty]::GeneratePropertyForString('cancelled')
    $Table.CloudTable.Execute([Microsoft.Azure.Cosmos.Table.TableOperation]::Replace($Entity)) | Out-Null
}

# --- Helper: Write pending-cancel flag to table -------------------------------
function Set-PendingCancel {
    param($Table)
    $Entity              = New-Object Microsoft.Azure.Cosmos.Table.DynamicTableEntity
    $Entity.PartitionKey = $AuthChatId
    $Entity.RowKey       = $PendingCancelKey
    $Table.CloudTable.Execute([Microsoft.Azure.Cosmos.Table.TableOperation]::InsertOrReplace($Entity)) | Out-Null
}

# --- Helper: Remove pending-cancel flag from table ----------------------------
function Clear-PendingCancel {
    param($Table)
    try {
        $Entity = $Table.CloudTable.Execute(
            [Microsoft.Azure.Cosmos.Table.TableOperation]::Retrieve($AuthChatId, $PendingCancelKey)
        ).Result
        if ($null -ne $Entity) {
            $Table.CloudTable.Execute([Microsoft.Azure.Cosmos.Table.TableOperation]::Delete($Entity)) | Out-Null
        }
    } catch {
        Write-Host "Clear-PendingCancel: $_"
    }
}

# --- Helper: Check if pending-cancel flag is set ------------------------------
function Test-PendingCancel {
    param($Table)
    $Result = $Table.CloudTable.Execute(
        [Microsoft.Azure.Cosmos.Table.TableOperation]::Retrieve($AuthChatId, $PendingCancelKey)
    ).Result
    return $null -ne $Result
}

# --- Helper: Check if an active search already exists for a given date --------
function Test-DuplicateSearch {
    param($Table, [string]$RowKey)
    $Result = $Table.CloudTable.Execute(
        [Microsoft.Azure.Cosmos.Table.TableOperation]::Retrieve($AuthChatId, $RowKey)
    ).Result
    if ($null -eq $Result) { return $false }
    $Status = $Result.Properties['Status'].StringValue
    return $Status -eq 'active'
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

# Get a single table reference reused throughout this invocation
$Table = Get-TableContext

# -- NEVERMIND / FORGET IT -----------------------------------------------------
# Checked before everything else - clears pending-cancel and confirms no changes made
if ($TextLower -match '\b(nevermind|never mind|forget it|forget that|no thanks|nope)\b') {
    Clear-PendingCancel -Table $Table
    Send-TelegramMessage "No changes made - all your searches are still active. Send ``Status`` to see what I'm watching."
    return
}

# -- PENDING CANCEL REPLY ------------------------------------------------------
# If a multi-search prompt was sent in a previous message, treat this as the date reply
if (Test-PendingCancel -Table $Table) {
    Write-Host "Pending cancel state active - treating message as cancellation reply"

    # "Stop all" still works here
    if ($TextLower -match '\ball\b') {
        $Entities = Get-ActiveSearchEntities -Table $Table
        foreach ($Entity in $Entities) { Cancel-Entity -Table $Table -Entity $Entity }
        Clear-PendingCancel -Table $Table
        Send-TelegramMessage "All searches stopped. Enjoy your round!"
        return
    }

    $ParsedDate = Parse-Date -Text $Text

    if ($null -ne $ParsedDate) {
        $TargetKey    = $ParsedDate.ToString('yyyy-MM-dd')
        $DateLabel    = Format-DateLabel -RowKey $TargetKey
        $Entities     = Get-ActiveSearchEntities -Table $Table
        $MatchedEntry = @($Entities | Where-Object { $_.RowKey -eq $TargetKey })

        Clear-PendingCancel -Table $Table

        if ($MatchedEntry.Count -eq 0) {
            Send-TelegramMessage "I don't have an active search for $DateLabel. Send ``Status`` to see what I'm currently watching."
        } else {
            Cancel-Entity -Table $Table -Entity $MatchedEntry[0]
            Send-TelegramMessage "Stopped searching for $DateLabel. Send me a new date any time you'd like to search again."
        }
    } else {
        # Could not parse a date from the reply - prompt again
        Send-TelegramMessage "I couldn't work out which date you meant. Please reply with the date you want to cancel, say ``Stop all`` to cancel everything, or say ``Nevermind`` to keep all searches active."
    }
    return
}

# -- STOP / DONE / BOOKED ------------------------------------------------------
if ($TextLower -match '\b(stop|done|cancel|booked|i.ve booked|i have booked)\b') {

    $Entities = Get-ActiveSearchEntities -Table $Table

    if ($Entities.Count -eq 0) {
        Send-TelegramMessage "No active searches to stop."
        return
    }

    # "Stop all" - cancel everything unconditionally
    if ($TextLower -match '\ball\b') {
        foreach ($Entity in $Entities) { Cancel-Entity -Table $Table -Entity $Entity }
        Send-TelegramMessage "All searches stopped. Enjoy your round!"
        return
    }

    # Try to parse a date from the message
    $ParsedDate = Parse-Date -Text $Text

    if ($null -ne $ParsedDate) {
        $TargetKey    = $ParsedDate.ToString('yyyy-MM-dd')
        $DateLabel    = Format-DateLabel -RowKey $TargetKey
        $MatchedEntry = @($Entities | Where-Object { $_.RowKey -eq $TargetKey })

        if ($MatchedEntry.Count -eq 0) {
            Send-TelegramMessage "I don't have an active search for $DateLabel. Send ``Status`` to see what I'm currently watching."
        } else {
            Cancel-Entity -Table $Table -Entity $MatchedEntry[0]
            Send-TelegramMessage "Stopped searching for $DateLabel. Send me a new date any time you'd like to search again."
        }
        return
    }

    # No date in message - single active search, cancel without prompting
    if ($Entities.Count -eq 1) {
        $DateLabel = Format-DateLabel -RowKey $Entities[0].RowKey
        Cancel-Entity -Table $Table -Entity $Entities[0]
        Send-TelegramMessage "Stopped searching for $DateLabel. Enjoy your round!"
        return
    }

    # No date in message - multiple active searches, set pending flag and prompt
    Set-PendingCancel -Table $Table
    $Lines = @('You have multiple active searches. Which date would you like to stop?', '')
    foreach ($E in $Entities) {
        $Lines += '  - ' + (Format-DateLabel -RowKey $E.RowKey)
    }
    $Lines += ''
    $Lines += 'Reply with the date you want to cancel, or say "Stop all" to cancel everything.'
    $Lines += 'Say "Nevermind" if you don''t want to make any changes.'
    Send-TelegramMessage ($Lines -join "`n")
    return
}

# -- STATUS --------------------------------------------------------------------
if ($TextLower -match '\b(status|what are you watching|what are you checking)\b') {
    Clear-PendingCancel -Table $Table
    $Entities = Get-ActiveSearchEntities -Table $Table
    if ($Entities.Count -eq 0) {
        Send-TelegramMessage "No active tee time searches right now. Send me a date and player count to start one!"
    } else {
        $Lines = @('Active searches:')
        foreach ($E in $Entities) {
            $DateLabel      = Format-DateLabel -RowKey $E.RowKey
            $Players        = $E.Properties['Players'].Int32Value
            $LastCheckedRaw = $E.Properties['LastChecked'].StringValue
            $LastCheckedET  = Format-EasternTime -UtcIsoString $LastCheckedRaw
            $Lines += "  - $DateLabel for $Players player(s)"
            $Lines += "    Last checked: $LastCheckedET"
        }
        Send-TelegramMessage ($Lines -join "`n")
    }
    return
}

# -- HELP ----------------------------------------------------------------------
if ($TextLower -match '\b(help|commands|what can you do)\b') {
    Clear-PendingCancel -Table $Table
    $HelpText = @"
Green Light Bot - Commands

To start a search:
  "Looking for a tee time on May 17th for 2 players"
  "Can you check Sunday for 4 players"

To check status:
  "Status"

To stop a specific search:
  "Stop May 17th"
  "Stop Sunday"
  "Done May 16th"

To stop all searches:
  "Stop all"

To stop when only one search is active:
  "Stop", "Done", "I've booked it"

To back out without making changes:
  "Nevermind", "Never mind", "Forget it"

I check Rocky Point and Fox Hollow for 8:30-10:30 AM slots every 30 minutes automatically.
"@
    Send-TelegramMessage $HelpText
    return
}

# -- NEW SEARCH REQUEST --------------------------------------------------------
# Clear any stale pending-cancel flag before processing a new search
Clear-PendingCancel -Table $Table

$ParsedDate    = Parse-Date -Text $Text
$ParsedPlayers = Parse-Players -Text $Text

if ($null -eq $ParsedDate) {
    Send-TelegramMessage "I couldn't work out which date you meant. Try something like:`n`n  ``Looking for a tee time on May 17th for 2 players```n  ``Check Sunday for 4 players``"
    return
}

$DateLabel  = $ParsedDate.ToString('dddd, dd MMMM yyyy')
$TargetKey  = $ParsedDate.ToString('yyyy-MM-dd')

# Duplicate search protection - check before saving
if (Test-DuplicateSearch -Table $Table -RowKey $TargetKey) {
    $ExistingEntity  = $Table.CloudTable.Execute(
        [Microsoft.Azure.Cosmos.Table.TableOperation]::Retrieve($AuthChatId, $TargetKey)
    ).Result
    $ExistingPlayers = $ExistingEntity.Properties['Players'].Int32Value
    Send-TelegramMessage "You're already watching $DateLabel for $ExistingPlayers player(s). Send ``Stop $DateLabel`` if you'd like to cancel that search and start a new one."
    return
}

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
    $Lines += "`nSend ``Done [date]`` or ``Stop [date]`` once you've secured your slot!"
    Send-TelegramMessage ($Lines -join "`n")
} else {
    Send-TelegramMessage "No times available right now in the 8:30-10:30 AM window for $DateLabel.`n`nI'll keep checking every 30 minutes and ping you when something opens up. Send ``Stop`` at any time to cancel."
}