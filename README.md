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
│   ├── profile.ps1               (imports Az.Accounts and Az.Storage from bundled Modules)
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
Required parameters: `schedule_ids[]` array (4169, 4170, 4168, 4171, 4177), `is_aggregate=true`, `Referer` header. Time format returned is `yyyy-MM-dd HH:mm`.

### Course Configuration
```powershell
$Courses = @(
    @{ Name = 'Rocky Point'; BookingClassId = 35; ScheduleId = 4171; BookingUrl = 'https://foreupsoftware.com/index.php/booking/a/20276/10#/teetimes' }
    @{ Name = 'Fox Hollow';  BookingClassId = 35; ScheduleId = 4170; BookingUrl = 'https://foreupsoftware.com/index.php/booking/a/20276/10#/teetimes' }
)
```

---

## Infrastructure

Deployed via Bicep to Azure. Target is a Y1 Consumption (Dynamic) App Service Plan.

### Active Deployment (Development Subscription)
| Resource | Name |
|---|---|
| Subscription | Development (22a583cb-68c9-4cda-a1b0-4b838a5ea729) |
| Resource Group | RGP-USE-GREEN-LIGHT-DV |
| Function App | fun-use-green-light |
| Storage Account | stousegreenlightdv |
| App Service Plan | asp-fun-use-green-light |
| App Insights | ais-fun-use-green-light |
| Location | East US |

---

## Pipeline

Three-stage GitHub Actions pipeline defined in `.github/workflows/deploy-greenlight.yml`:

1. **Validate** — Bicep dry run and what-if against the Development subscription
2. **Security Scan** — Checkov scan on the Bicep template, SARIF report uploaded to GitHub
3. **Deploy** — Bicep infrastructure deployment, Function App zip deploy, Telegram webhook registration. Runs on `workflow_dispatch` only — never triggered automatically on push.

### Required GitHub Actions Secrets
| Secret | Purpose |
|---|---|
| `AZURE_CREDENTIALS` | Service principal credentials for Development subscription |
| `TELEGRAM_BOT_TOKEN` | Bot token from BotFather |
| `TELEGRAM_CHAT_ID` | Your Telegram chat ID |
| `TELEGRAM_SECRET_TOKEN` | Webhook validation token |

### Service Principal
- Name: `appreg-tee-time-alerts-dv`
- Object ID: `b7bb9f16-9816-4120-adfe-a1acc0c9af53`
- Role: Contributor on Development subscription

### Checkov Suppressions
The following checks are suppressed via `--skip-check` in the pipeline:

| Check | Reason |
|---|---|
| CKV_AZURE_43 | Storage account name is parameter-driven and follows Azure naming rules |
| CKV_AZURE_206 | LRS replication is intentional for a low-cost development workload |
| CKV_AZURE_225 | Zone redundancy not supported on Y1 Consumption plan |
| CKV_AZURE_16 | AAD authentication not required — webhook secured via Telegram secret token header |
| CKV_AZURE_17 | Client certificates not applicable for a Telegram webhook receiver |
| CKV_AZURE_71 | Managed identity migration is a backlog item — currently using storage account key |
| CKV_AZURE_212 | Minimum instance count not configurable on Y1 Consumption plan |
| CKV_AZURE_213 | Health check endpoint not warranted for this workload |
| CKV_AZURE_222 | Public network access required for Telegram webhook delivery |
| CKV_AZURE_59 | Storage networkAcls defaultAction reverted to Allow — Deny blocks Kudu filesystem access on Y1 Consumption plan |

---

## Security

- Function auth level: `anonymous`
- Telegram webhook validates `X-Telegram-Bot-Api-Secret-Token` header on every request
- `200 OK` returned immediately after token validation before any processing
- Bot only processes messages from the authorised `TELEGRAM_CHAT_ID`
- All secrets stored as Azure Function App settings and GitHub Actions secrets — never in code

---

## Module Loading

Managed dependencies (`requirements.psd1`) proved unreliable on the Y1 Consumption plan on this subscription. Az.Accounts (5.4.0) and Az.Storage (6.0.1) are bundled directly in `.azure-function/Modules/` and imported explicitly in `profile.ps1` on cold start. Managed dependencies were retested after the Development subscription deployment was stabilised and confirmed still unreliable — bundled modules are retained permanently for this workload.

---

## Backlog

| # | Item | Status |
|---|---|---|
| 1 | Production migration — move from Development to Production subscription | Pending |

---

## Phase 2 Feature Enhancements

1. **Configurable search window** — allow per-search time window override (e.g. "around noon") stored on the table entity
2. **Course filtering** — allow searches scoped to a single course (e.g. "Rocky Point only")
3. **Duplicate search protection** — detect and warn when a search for an already-watched date is submitted
4. **Daily morning summary** — 7 AM digest of all active searches via a second timer trigger
5. **Holes preference** — capture 9 vs 18 hole preference per search and pass through to ForeUp API filter

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