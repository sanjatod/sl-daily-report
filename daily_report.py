#!/usr/bin/env python3
"""SL Daily Scrum Master Report — Python version for cloud/remote execution."""

import base64
import json
import os
import sys
import urllib.request
import urllib.parse
from datetime import datetime, timezone, timedelta

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------
JIRA_EMAIL  = "sanja.todorovic@intelisale.com"
JIRA_TOKEN  = os.environ.get("JIRA_API_TOKEN", "")
if not JIRA_TOKEN:
    print("ERROR: JIRA_API_TOKEN environment variable not set", file=sys.stderr)
    sys.exit(1)
JIRA_BASE   = "https://intelisale.atlassian.net"

WEBHOOK_PROD   = "https://default4b8aa2e8b91c4c9f864e9a227c90af.6b.environment.api.powerplatform.com:443/powerautomate/automations/direct/workflows/ff8e760fb4a44012ae8a475b966d7f38/triggers/manual/paths/invoke?api-version=1&sp=%2Ftriggers%2Fmanual%2Frun&sv=1.0&sig=GP041TA0L5M2WHM8ZeM4UaI8u5nsEuamtweRpYnx6hI"
WEBHOOK_MOBILE = "https://intelisaledoo.webhook.office.com/webhookb2/ee71c70c-320b-423a-9a50-5e4145905196@4b8aa2e8-b91c-4c9f-864e-9a227c90af6b/IncomingWebhook/61f73bf4ecd14158916d5615bf8eea33/f9c5a9b1-bf15-46c9-9031-ee66fa1f906f/V2YStZZ6SCh-zS_SYzSsA-iV7z1Gezs_WixDpJ1alMy7E1"

TEST_MODE = "--test" in sys.argv or "-TestMode" in sys.argv
WEBHOOK = WEBHOOK_MOBILE if TEST_MODE else WEBHOOK_PROD

# ---------------------------------------------------------------------------
# Auth header
# ---------------------------------------------------------------------------
_creds = base64.b64encode(f"{JIRA_EMAIL}:{JIRA_TOKEN}".encode()).decode()
HEADERS = {"Authorization": f"Basic {_creds}", "Accept": "application/json"}

# ---------------------------------------------------------------------------
# Serbian public holidays — skip report
# ---------------------------------------------------------------------------
HOLIDAYS = {"01-01","01-02","01-07","02-15","02-16","05-01","05-02","11-11"}
now_belgrade = datetime.now(timezone(timedelta(hours=2)))  # CEST (UTC+2)
today_mmdd = now_belgrade.strftime("%m-%d")
if today_mmdd in HOLIDAYS:
    print(f"Skipped - public holiday {today_mmdd}")
    sys.exit(0)

# ---------------------------------------------------------------------------
# Lookback: Mon = -72h, else -24h
# ---------------------------------------------------------------------------
weekday = now_belgrade.weekday()  # 0=Mon
if weekday == 0:
    LOOKBACK = "-72h"
    label = "od petka"
else:
    LOOKBACK = "-24h"
    label = "juce"

# ---------------------------------------------------------------------------
# Serbian date label
# ---------------------------------------------------------------------------
MONTHS = ["","januar","februar","mart","april","maj","jun",
          "jul","avgust","septembar","oktobar","novembar","decembar"]
datum_sr = f"{now_belgrade.day}. {MONTHS[now_belgrade.month]} {now_belgrade.year}."

# ---------------------------------------------------------------------------
# Jira search helper
# ---------------------------------------------------------------------------
def jira_search(jql, fields):
    issues = []
    page_token = None
    page = 0
    while page < 20:
        params = {
            "jql": jql,
            "maxResults": "100",
            "fields": ",".join(fields),
        }
        if page_token:
            params["nextPageToken"] = page_token
        url = f"{JIRA_BASE}/rest/api/3/search/jql?" + urllib.parse.urlencode(params)
        req = urllib.request.Request(url, headers=HEADERS)
        try:
            with urllib.request.urlopen(req, timeout=30) as resp:
                data = json.loads(resp.read())
        except Exception as e:
            print(f"ERROR Jira page {page}: {e}", file=sys.stderr)
            break
        issues.extend(data.get("issues", []))
        page += 1
        if data.get("isLast") or not data.get("nextPageToken"):
            break
        page_token = data["nextPageToken"]
    return issues

# ---------------------------------------------------------------------------
# Fetch data
# ---------------------------------------------------------------------------
print("Fetching support tickets...")
all_b = jira_search(
    f'project = SLR AND "Help Desk[Dropdown]" = "Support issue" AND created >= "{LOOKBACK}" ORDER BY created DESC',
    ["summary","status","assignee","priority"]
)
print(f"  B: {len(all_b)}")

print("Fetching new in sprint...")
all_c = jira_search(
    f'project = SLR AND sprint in openSprints() AND fixVersion is not EMPTY AND created >= "{LOOKBACK}" ORDER BY created DESC',
    ["summary","status","issuetype"]
)
print(f"  C: {len(all_c)}")

print("Fetching blocked >7d...")
all_e_raw = jira_search(
    'project = SLR AND sprint in openSprints() AND issuetype in subTaskIssueTypes() '
    'AND status in ("On Hold","On Hold Dev","On Hold - Development","On Hold Testing","On Hold - Testing") '
    'AND updated <= "-7d" AND ("Help Desk[Dropdown]" is EMPTY OR NOT "Help Desk[Dropdown]" = "Support issue") '
    'ORDER BY updated ASC',
    ["summary","status","assignee","updated"]
)
today_date = now_belgrade.date()
all_e = []
for e in all_e_raw:
    updated = e["fields"]["updated"][:10]  # "2026-05-01T..."
    days = (today_date - datetime.strptime(updated, "%Y-%m-%d").date()).days
    e["_days"] = days
    all_e.append(e)
all_e.sort(key=lambda x: x["_days"], reverse=True)
print(f"  E: {len(all_e)}")

# ---------------------------------------------------------------------------
# Build Adaptive Card body
# ---------------------------------------------------------------------------
def tb(text, **kwargs):
    return {"type": "TextBlock", "text": text, "wrap": True, **kwargs}

body = [
    tb(f"\U0001f4ca SL Daily Snapshot - {datum_sr}", size="Large", weight="Bolder", color="Accent"),
    tb(f"Podaci: {label}"),
]

# --- Support ---
body.append(tb("\U0001f198 Support (Help Desk):", weight="Bolder", spacing="Medium"))
if not all_b:
    body.append(tb("Nema novih", isSubtle=True))
else:
    PRI = {"Critical":"🔴 Critical","High":"🟠 High","Medium":"🟡 Medium","Low":"🔵 Low","Trivial":"⚪ Trivial"}
    for t in all_b:
        key = t["key"]
        s = t["fields"]["summary"].strip()[:80]
        pri = t["fields"].get("priority", {}).get("name", "")
        pri_tag = PRI.get(pri, pri)
        body.append(tb(f"* [{key} - {s}]({JIRA_BASE}/browse/{key}) — {pri_tag}"))

# --- New in sprint ---
body.append(tb(f"\U0001f195 Novi u sprintu ({label}):", weight="Bolder", spacing="Small"))
if not all_c:
    body.append(tb("Nema novih", isSubtle=True))
else:
    for t in all_c:
        key = t["key"]
        s = t["fields"]["summary"].strip()[:80]
        body.append(tb(f"* [{key} - {s}]({JIRA_BASE}/browse/{key})"))

# --- Blocked >7d ---
total_e = len(all_e)
body.append(tb(f"\U0001f6a8 Blokirano >7 dana ({total_e} subtaskova):", weight="Bolder", spacing="Medium"))
if not all_e:
    body.append(tb("Nema blokiranih", isSubtle=True))
else:
    for e in all_e:
        key = e["key"]
        s = e["fields"]["summary"].strip()[:55]
        st = e["fields"]["status"]["name"]
        oh_tag = "OH-Test" if "Testing" in st else "OH-Dev"
        asgn = e["fields"].get("assignee") or {}
        asgn_str = f" @{asgn['displayName']}" if asgn else ""
        body.append(tb(f"* [{key} - {s}]({JIRA_BASE}/browse/{key}) - {e['_days']}d [{oh_tag}{asgn_str}]"))

# ---------------------------------------------------------------------------
# Send to Teams
# ---------------------------------------------------------------------------
card = {
    "type": "message",
    "attachments": [{
        "contentType": "application/vnd.microsoft.card.adaptive",
        "content": {
            "$schema": "http://adaptivecards.io/schemas/adaptive-card.json",
            "type": "AdaptiveCard",
            "version": "1.2",
            "body": body,
        }
    }]
}

payload = json.dumps(card, ensure_ascii=False).encode("utf-8")
req = urllib.request.Request(WEBHOOK, data=payload,
                              headers={"Content-Type": "application/json; charset=utf-8"},
                              method="POST")
try:
    with urllib.request.urlopen(req, timeout=30) as resp:
        result = resp.read().decode()
    print(f"OK - support={len(all_b)} novi={len(all_c)} blocked={total_e} | Teams={result}")
except Exception as e:
    print(f"ERROR sending to Teams: {e}", file=sys.stderr)
    sys.exit(1)
