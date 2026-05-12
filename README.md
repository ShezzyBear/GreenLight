# Green Light

A Telegram bot that monitors two Baltimore County golf courses for available tee times and alerts you the moment a slot opens in your target window. Set it and forget it — Green Light checks every hour and messages you directly when it finds something.

---

## What It Does

- Monitors **Rocky Point** and **Fox Hollow** via the ForeUp booking API
- Watches for tee times between **8:30 AM and 10:30 AM**
- Accepts natural language requests — "Looking for a tee time on May 17th for 2 players"
- Sends an immediate check when a new search is created, then continues checking every hour
- Sends a still-searching notification every 6 hours so you know it's alive
- Supports multiple concurrent searches (e.g. Saturday and Sunday at the same time)
- Stops a specific search by date, or all searches at once
- Marks expired searches automatically when the date passes

---

## Repository Structure

```
GreenLight/
├── .github/workflows/
│   └── deploy-greenlight.yml     (IaC pipeline - validate, Checkov, deploy)
├── .azure-function/
│   ├── host.json
│   ├── profile.ps1               (imports Az modules from bundled Modules folder)
│   ├── requirements.psd1         (empty @{} - modules are bundled directly)
│   ├── Modules/
│   │   ├── Az.Accounts/
│   │   │   └── 5.4.0/
│   │   └── Az.Storage/
│   │       └── 6.0.1/
│   ├── TeeTimeBot/
│   │   ├── function.json         (HTTP trigger, authLevel: anonymous)
│   │   └── run.ps1               (handles incoming Telegram webhook messages)
│   └── TeeTimeScheduler/
│       ├── function.json         (Timer trigger - every hour)
│       └── run.ps1               (polls active searches, sends alerts)
├── infrastructure/
│   ├── main.bicep                (Y1 Consumption App Service Plan)
│   └── parameters.json
└── pipelines/
    └── deploy-greenlight.yml     (copy of workflow for reference)
```

---

## Bot Commands

| What you say | What happens |
|---|---|
| "Looking for a tee time on May 17th for 2 players" | Starts a new search for that date and player count |
| "Can you check Sunday for 4 players" | Starts a search using day-of-week |
| `Status` | Lists all active searches with last checked time (Eastern) |
| `Stop May 17th` | Cancels the search for that specific date |
| `Stop Sunday` | Cancels the search for the next upcoming Sunday |
| `Stop all` | Cancels all active searches |
| `Stop` / `Done` / `I've booked it` | Cancels the only active search, or prompts to specify if multiple |
| `Nevermind` / `Forget it` | Backs out of a multi-search cancel prompt with no changes made |
| `Help` | Lists all commands |

---

## Architecture

### TeeTimeBot (HTTP Trigger)
Receives incoming Telegram webhook messages. Validates the `X-Telegram-Bot-Api-Secret-Token` header and returns `200 OK` immediately to prevent Telegram retry loops. Handles all user commands, saves new searches to Azure Table Storage, and performs an immediate ForeUp API check on new search requests.

### TeeTimeScheduler (Timer Trigger)
Fires every hour. Reads all active searches from Table Storage, calls the ForeUp API for each, and sends a Telegram alert if tee times are found in the target window. Increments a `CheckCount` on each entity and sends a still-searching notification every 6 checks (6 hours). Automatically expires searches whose dates have passed.

### Azure Table Storage
Single table `ActiveSearches` stores search state. Each entity uses `PartitionKey = ChatId` and `RowKey = yyyy-MM-dd`. A reserved `RowKey` of `pending-cancel` tracks multi-search cancel prompt state between messages.

### ForeUp API
```
GET https://foreupsoftware.com/index.php/api/booking/times
```
Required parameters: `schedule_ids[]` array, `is_aggregate=true`, `Referer` header. Time format returned is `yyyy-MM-dd HH:mm`.

### Course Configuration
```powershell
$Courses = @(
    @{ Name = 'Rocky Point'; BookingClassId = 35; ScheduleId = 4171; BookingUrl = 'https://foreupsoftware.com/index.php/booking/a/20276/10#/teetimes' }
    @{ Name = 'Fox Hollow';  BookingClassId = 35; ScheduleId = 4170; BookingUrl = 'https://foreupsoftware.com/index.php/booking/a/20276/10#/teetimes' }
)
```

---

## Infrastructure

Deployed via Bicep to Azure on a Y1 Consumption (Dynamic) App Service Plan. Infrastructure is defined in `infrastructure/main.bicep` and deployed via the GitHub Actions pipeline.

### Required Azure Resources
| Resource | Type |
|---|---|
| Resource Group | Container for all resources |
| Function App | PowerShell 7.4, Y1 Consumption |
| Storage Account | StorageV2, Standard LRS |
| App Service Plan | Y1 Dynamic (Consumption) |
| Application Insights | Web, 30-day retention |

---

## Deploying Your Own Instance

### Prerequisites
- Azure subscription with Contributor access
- GitHub repository with Actions enabled
- Telegram bot token from [@BotFather](https://t.me/botfather)
- Azure CLI installed locally (for initial setup)

### GitHub Actions Secrets
The following secrets must be configured in your repository under **Settings → Secrets and variables → Actions**:

| Secret | Description |
|---|---|
| `AZURE_CREDENTIALS` | Service principal credentials JSON for your Azure subscription |
| `TELEGRAM_BOT_TOKEN` | Bot token provided by BotFather |
| `TELEGRAM_CHAT_ID` | Your Telegram chat ID (the bot will only respond to this ID) |
| `TELEGRAM_SECRET_TOKEN` | A secret string of your choosing used to validate webhook requests |

### parameters.json
Update `infrastructure/parameters.json` with your desired resource names and location before deploying.

### Pipeline
The three-stage GitHub Actions pipeline is defined in `.github/workflows/deploy-greenlight.yml`:

1. **Validate** — Bicep dry run and what-if preview
2. **Security Scan** — Checkov static analysis on the Bicep template, SARIF report uploaded to GitHub
3. **Deploy** — Bicep infrastructure deployment, Function App zip deploy, Telegram webhook registration

The deploy stage runs on `workflow_dispatch` only and must be triggered manually from the Actions tab.

---

## Security

- Function auth level: `anonymous` — security is handled at the application layer
- Every incoming webhook request is validated against the `X-Telegram-Bot-Api-Secret-Token` header
- `200 OK` is returned immediately after token validation to prevent Telegram retry loops
- The bot only processes messages from the configured `TELEGRAM_CHAT_ID`
- All secrets are stored as Azure Function App settings and GitHub Actions secrets — never in source code

---

## Module Loading

Az.Accounts (5.4.0) and Az.Storage (6.0.1) are bundled directly in `.azure-function/Modules/` and imported explicitly in `profile.ps1` on cold start. This approach is used in place of managed dependencies for reliability on the Y1 Consumption plan.

---

## Planned Enhancements

1. **Configurable search window** — per-search time window override (e.g. "around noon")
2. **Course filtering** — scope a search to a single course (e.g. "Rocky Point only")
3. **Duplicate search protection** — warn when a search for an already-watched date is submitted
4. **Daily morning summary** — 7 AM digest of all active searches
5. **Holes preference** — capture 9 vs 18 hole preference per search

---

## Local Development

A `local.settings.json` file is required for local testing and is gitignored. It should contain:

```json
{
  "IsEncrypted": false,
  "Values": {
    "AzureWebJobsStorage": "<connection string>",
    "FUNCTIONS_WORKER_RUNTIME": "powershell",
    "TELEGRAM_BOT_TOKEN": "<token>",
    "TELEGRAM_CHAT_ID": "<chat id>",
    "TELEGRAM_SECRET_TOKEN": "<secret>",
    "STORAGE_ACCOUNT_NAME": "<account name>",
    "STORAGE_ACCOUNT_KEY": "<account key>"
  }
}
```