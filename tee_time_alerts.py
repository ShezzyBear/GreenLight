"""
Baltimore County Tee Time Checker
==================================
Polls Rocky Point and Fox Hollow (via ForeUp) for available tee times
between 8:30 AM and 10:30 AM.

Usage (interactive):
    python tee_time_checker.py

Usage (non-interactive / scheduled):
    python tee_time_checker.py --date 2026-05-24 --players 2
    python tee_time_checker.py --date 2026-05-24 --players 4 --days 7

Arguments:
    --date      Date to start checking from (YYYY-MM-DD). Defaults to today.
    --players   Number of players (1-4). Prompted if not supplied.
    --days      How many days ahead to scan from --date (default: 1, i.e. that day only).
"""

import argparse
import json
import requests
from datetime import datetime, timedelta

# ─────────────────────────────────────────────────────────────────────────────
# COURSE CONFIGURATION
# ─────────────────────────────────────────────────────────────────────────────

COURSES = {
    "Rocky Point": {
        "booking_class_id": 20276,
        "schedule_id":      10,       # from the /a/20276/10 URL segment
        "booking_url":      "https://foreupsoftware.com/index.php/booking/a/20276/10",
    },
    "Fox Hollow": {
        "booking_class_id": 19563,
        "schedule_id":      None,
        "booking_url":      "https://foreupsoftware.com/index.php/booking/index/19563",
    },
}

# Time window to watch (24-hour, inclusive)
WINDOW_START = "08:30"
WINDOW_END   = "10:30"

# ─────────────────────────────────────────────────────────────────────────────
# TELEGRAM CONFIGURATION  <-- fill these in before running
# ─────────────────────────────────────────────────────────────────────────────

TELEGRAM_BOT_TOKEN = "YOUR_BOT_TOKEN"   # from @BotFather
TELEGRAM_CHAT_ID   = "YOUR_CHAT_ID"     # your personal chat ID

# ─────────────────────────────────────────────────────────────────────────────
# FOREUP API
# ─────────────────────────────────────────────────────────────────────────────

FOREUP_API_URL = "https://foreupsoftware.com/index.php/api/booking/times"

HEADERS = {
    "User-Agent":        "Mozilla/5.0",
    "Accept":            "application/json, text/javascript, */*; q=0.01",
    "X-Requested-With":  "XMLHttpRequest",
    "Referer":           "https://foreupsoftware.com/",
}


def fetch_times(course_name, config, date_str, num_players):
    """
    Call the ForeUp availability API for one course on one date.
    date_str must be in MM-DD-YYYY format (what ForeUp expects).
    Returns a list of slot dicts, or [] on any error.
    """
    params = {
        "time":          "all",
        "date":          date_str,
        "holes":         "all",
        "players":       str(num_players),
        "booking_class": str(config["booking_class_id"]),
        "schedule_id":   str(config["schedule_id"]) if config["schedule_id"] else "",
        "specials_only": "0",
        "api_key":       "no_limits",
    }

    try:
        resp = requests.get(FOREUP_API_URL, params=params, headers=HEADERS, timeout=15)
        resp.raise_for_status()
        data = resp.json()
        # ForeUp returns a list on success, or a dict with an error key
        return data if isinstance(data, list) else []
    except requests.RequestException as e:
        print(f"  [ERROR] {course_name} on {date_str}: {e}")
        return []
    except (json.JSONDecodeError, ValueError):
        print(f"  [ERROR] {course_name} on {date_str}: unexpected response format")
        return []


def in_window(time_str):
    """
    Return True if time_str (e.g. '9:00am') falls within WINDOW_START..WINDOW_END.
    """
    formats = ["%I:%M%p", "%I:%M %p"]
    for fmt in formats:
        try:
            t = datetime.strptime(time_str.strip().lower(), fmt).strftime("%H:%M")
            return WINDOW_START <= t <= WINDOW_END
        except ValueError:
            continue
    return False


def check_courses(start_date, num_players, days_ahead):
    """
    Check all courses across the requested date range.
    Returns a list of hit dicts.
    """
    hits = []

    for course_name, config in COURSES.items():
        for offset in range(days_ahead):
            check_date = start_date + timedelta(days=offset)
            date_str   = check_date.strftime("%m-%d-%Y")

            print(f"  Checking {course_name} on {date_str}...")
            slots = fetch_times(course_name, config, date_str, num_players)

            for slot in slots:
                slot_time = slot.get("time", "")
                if in_window(slot_time):
                    hits.append({
                        "course":      course_name,
                        "date_obj":    check_date,
                        "date_label":  check_date.strftime("%A, %d %B %Y"),
                        "time":        slot_time,
                        "holes":       slot.get("holes", "?"),
                        "spots":       slot.get("available_spots", "?"),
                        "booking_url": config["booking_url"],
                    })

    return hits


# ─────────────────────────────────────────────────────────────────────────────
# TELEGRAM NOTIFICATION
# ─────────────────────────────────────────────────────────────────────────────

def build_telegram_message(hits, num_players, start_date, days_ahead):
    now = datetime.now().strftime("%d %b %Y %H:%M")

    if days_ahead == 1:
        date_range = start_date.strftime("%A, %d %B %Y")
    else:
        end_date   = start_date + timedelta(days=days_ahead - 1)
        date_range = f"{start_date.strftime('%d %b')} - {end_date.strftime('%d %b %Y')}"

    lines = [
        "⛳ Tee Time Alert",
        f"Checked: {now}",
        f"Looking for: {num_players} player(s)  |  {WINDOW_START}-{WINDOW_END}",
        f"Date range: {date_range}",
        "",
    ]

    if hits:
        lines.append(f"✅ Found {len(hits)} slot(s):\n")
        for h in hits:
            lines.append(
                f"📍 {h['course']}\n"
                f"📅 {h['date_label']}  @  {h['time']}\n"
                f"🕳️  {h['holes']} holes  |  {h['spots']} spot(s) available\n"
                f"🔗 Book: {h['booking_url']}\n"
            )
    else:
        lines.append("❌ No tee times found in the 8:30-10:30 AM window.")
        lines.append("Check again later or try different dates.")

    return "\n".join(lines)


def send_telegram(message):
    url  = f"https://api.telegram.org/bot{TELEGRAM_BOT_TOKEN}/sendMessage"
    data = {"chat_id": TELEGRAM_CHAT_ID, "text": message}
    try:
        resp = requests.post(url, data=data, timeout=10)
        resp.raise_for_status()
        print("  Telegram notification sent successfully.")
    except requests.RequestException as e:
        print(f"  [Telegram ERROR] {e}")


# ─────────────────────────────────────────────────────────────────────────────
# INPUT HELPERS
# ─────────────────────────────────────────────────────────────────────────────

def prompt_date():
    """Interactively ask for a date, defaulting to today."""
    today_str = datetime.today().strftime("%Y-%m-%d")
    while True:
        raw = input(f"  Date to check (YYYY-MM-DD) [default: {today_str}]: ").strip()
        if not raw:
            return datetime.today().replace(hour=0, minute=0, second=0, microsecond=0)
        try:
            return datetime.strptime(raw, "%Y-%m-%d")
        except ValueError:
            print("  Invalid format. Please use YYYY-MM-DD (e.g. 2026-06-01).")


def prompt_players():
    """Interactively ask for number of players."""
    while True:
        raw = input("  Number of players (1-4): ").strip()
        if raw.isdigit() and 1 <= int(raw) <= 4:
            return int(raw)
        print("  Please enter a number between 1 and 4.")


def prompt_days():
    """Interactively ask how many days ahead to scan."""
    while True:
        raw = input("  How many days to scan from that date? [default: 1]: ").strip()
        if not raw:
            return 1
        if raw.isdigit() and int(raw) >= 1:
            return int(raw)
        print("  Please enter a positive number.")


def parse_args():
    parser = argparse.ArgumentParser(
        description="Check ForeUp tee time availability for Baltimore County golf courses."
    )
    parser.add_argument(
        "--date", "-d",
        type=str,
        default=None,
        help="Start date to check (YYYY-MM-DD). Defaults to today.",
    )
    parser.add_argument(
        "--players", "-p",
        type=int,
        choices=[1, 2, 3, 4],
        default=None,
        help="Number of players (1-4).",
    )
    parser.add_argument(
        "--days",
        type=int,
        default=None,
        help="Number of days to scan from --date (default: 1).",
    )
    return parser.parse_args()


# ─────────────────────────────────────────────────────────────────────────────
# MAIN
# ─────────────────────────────────────────────────────────────────────────────

if __name__ == "__main__":
    args = parse_args()
    interactive = args.date is None and args.players is None

    print()
    print("=" * 60)
    print("  Baltimore County Golf  -  Tee Time Checker")
    print("  Rocky Point  &  Fox Hollow  (8:30 AM - 10:30 AM)")
    print("=" * 60)

    # ── Resolve inputs ──────────────────────────────────────────────────────
    if interactive:
        print("\n  Enter your search criteria:\n")
        start_date  = prompt_date()
        num_players = prompt_players()
        days_ahead  = prompt_days()
    else:
        if args.date:
            try:
                start_date = datetime.strptime(args.date, "%Y-%m-%d")
            except ValueError:
                print(f"  [ERROR] Invalid --date format '{args.date}'. Use YYYY-MM-DD.")
                exit(1)
        else:
            start_date = datetime.today().replace(hour=0, minute=0, second=0, microsecond=0)

        if args.players:
            num_players = args.players
        else:
            print("\n  Number of players not supplied via --players, prompting:\n")
            num_players = prompt_players()

        days_ahead = args.days if args.days else 1

    # ── Summary ─────────────────────────────────────────────────────────────
    print()
    print(f"  Start date : {start_date.strftime('%A, %d %B %Y')}")
    print(f"  Days ahead : {days_ahead}")
    print(f"  Players    : {num_players}")
    print(f"  Window     : {WINDOW_START} - {WINDOW_END}")
    print("-" * 60)

    # ── Check courses ────────────────────────────────────────────────────────
    hits = check_courses(start_date, num_players, days_ahead)

    # ── Report & notify ──────────────────────────────────────────────────────
    print()
    if hits:
        print(f"  Found {len(hits)} available slot(s) in the target window!")
    else:
        print("  No tee times found in the target window.")

    message = build_telegram_message(hits, num_players, start_date, days_ahead)
    print("\n--- Telegram message preview ---")
    print(message)
    print("--------------------------------\n")

    send_telegram(message)
