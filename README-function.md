# Tee Time Bot - Azure Function

An Azure Function App that acts as a conversational Telegram bot for monitoring
tee time availability at Rocky Point and Fox Hollow (Baltimore County, MD).

## Architecture

```
Telegram Message
      |
      v
Azure Function (HTTP Trigger) - TeeTimeBot
      |
      |-- Parses date + players from natural language
      |-- Saves active search to Azure Storage Table
      |-- Runs immediate ForeUp availability check
      |-- Sends result back via Telegram
      |
Azure Function (Timer Trigger) - TeeTimeScheduler [every 4 hours]
      |
      |-- Reads all active searches from Storage Table
      |-- Checks ForeUp for each
      |-- Sends Telegram alert if tee time found
```

## Bot Commands

| Message | Action |
|---|---|
| `"Looking for a tee time on May 17th for 2 players"` | Starts a new search |
| `"Check Sunday for 4 players"` | Starts a search for next Sunday |
| `"Status"` | Lists all active searches |
| `"Stop"` / `"Done"` / `"I've booked it"` | Cancels all active searches |
| `"Help"` | Shows command reference |

## Infrastructure

| Resource | Name | SKU |
|---|---|---|
| Resource Group | RGP-USE2-TEE-TIME-ALERTS-DV | - |
| Function App | fun-use2-tee-time-alerts | Consumption (Y1) |
| Storage Account | stoteetime | Standard_LRS |
| App Insights | appi-fun-use2-tee-time-alerts | - |
| Storage Table | ActiveSearches | - |

## Deploy Pipeline Stages

1. **Validate** - `az deployment group validate` + what-if preview
2. **Security Scan** - Checkov against Bicep templates
3. **Deploy** - Infrastructure + Function code + Telegram webhook registration

## GitHub Secrets Required

| Secret | Description |
|---|---|
| `AZURE_CREDENTIALS` | Service principal JSON from `az ad sp create-for-rbac` |
| `TELEGRAM_BOT_TOKEN` | Bot token from @BotFather |
| `TELEGRAM_CHAT_ID` | Your personal Telegram chat ID |

## Initial Setup

### 1. Create Azure Service Principal

```bash
az ad sp create-for-rbac \
  --name "sp-tee-time-alerts-deploy" \
  --role Contributor \
  --scopes /subscriptions/22a583cb-68c9-4cda-a1b0-4b838a5ea729 \
  --sdk-auth
```

Copy the full JSON output and save it as the `AZURE_CREDENTIALS` GitHub secret.

### 2. Add GitHub Secrets

Go to: **Settings -> Secrets and variables -> Actions -> New repository secret**

Add `AZURE_CREDENTIALS`, `TELEGRAM_BOT_TOKEN`, and `TELEGRAM_CHAT_ID`.

### 3. Trigger the pipeline

Push to `main` or trigger manually via **Actions -> Deploy Tee Time Bot -> Run workflow**.

## Courses Monitored

| Course | ForeUp ID | Time Window |
|---|---|---|
| Rocky Point | 20276 | 8:30 AM - 10:30 AM |
| Fox Hollow | 19563 | 8:30 AM - 10:30 AM |
