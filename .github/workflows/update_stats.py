"""
FieldX weekly stats update.

Runs on GitHub Actions. After every game of the latest NFL week is final and in
nflverse's data, it computes each player's season PPR points per game and adds
one new row to the stats_versions table ("Week N"). Prices update for everyone
and the market reopens. It never edits old rows, so past trades keep their prices.

Safe to run as often as you like: if that week's update already exists, it stops.
Needs two GitHub secrets: SUPABASE_URL and SUPABASE_SECRET_KEY.
"""
import csv, io, json, os, sys, urllib.request, urllib.error
from collections import defaultdict

SEASON = 2026
FIRST_WEEK = 8   # the game opened with stats through the Week 8 Thursday game
STATS_URL = f"https://github.com/nflverse/nflverse-data/releases/download/stats_player/stats_player_week_{SEASON}.csv"
GAMES_URL = "https://github.com/nflverse/nfldata/raw/master/data/games.csv"

# FieldX ticker -> nflverse player_id
PLAYER_IDS = {
    "JSN": "00-0038543",
    "GIBB": "00-0039139",
    "ALLN": "00-0034857",
    "LAMB": "00-0036358",
    "LOVE": "00-0036264",
    "KW3": "00-0038134",
    "WATS": "00-0038124",
    "PRDY": "00-0037834",
    "BIJN": "00-0038542",
    "CMC": "00-0033280",
    "MAYE": "00-0039851",
    "JT": "00-0036223",
    "KYRN": "00-0037840",
    "GOFF": "00-0033106",
    "CHUB": "00-0036555",
    "GLDN": "00-0040667",
    "COUS": "00-0029604",
    "JAVO": "00-0036997",
    "MCBR": "00-0037744",
    "BURR": "00-0036442",
    "CJS": "00-0039163",
    "ARSB": "00-0036963",
    "DAK": "00-0033077",
    "BRYC": "00-0039150",
    "SHOU": "00-0040743",
    "OLAV": "00-0037239",
    "STAF": "00-0026498",
    "SWIF": "00-0036275",
    "HENR": "00-0032764",
    "FLOW": "00-0039064",
    "JEAN": "00-0040122",
    "NABE": "00-0039337",
    "WARR": "00-0037228",
    "LAWR": "00-0036971",
    "PUKA": "00-0039075",
    "COOK": "00-0037248",
    "LIKE": "00-0037838",
    "RODG": "00-0023459",
    "IRVI": "00-0039361",
    "MCMI": "00-0040124",
    "LOND": "00-0037238",
    "BRIS": "00-0033119",
    "DWAT": "00-0033537",
    "GENO": "00-0030565",
    "KITT": "00-0033288",
    "HIGG": "00-0036410",
    "ADAM": "00-0031381",
    "MAHO": "00-0033873",
    "TUCK": "00-0038563",
    "WILS": "00-0037740",
    "PICK": "00-0037247",
    "CHAS": "00-0036900",
    "BURD": "00-0040735",
    "NIX": "00-0039732",
    "BOWR": "00-0039338",
    "WASH": "00-0038606",
    "EVNS": "00-0031408",
    "KRAF": "00-0038996",
    "TUTE": "00-0040719",
    "POLL": "00-0035261",
    "STEV": "00-0036875",
    "WILL": "00-0038128",
    "VELE": "00-0039424",
    "JD5": "00-0039910",
    "PENI": "00-0039917",
    "JAMO": "00-0037240",
    "CALB": "00-0039918",
    "MWIL": "00-0038559",
    "COKE": "00-0039491",
    "HURT": "00-0036389",
    "JUDK": "00-0040784",
    "LAPO": "00-0039065",
    "LJ8": "00-0034796",
    "TATE": "00-0041438",
    "BOST": "00-0041037",
    "METC": "00-0035640",
    "ALLE": "00-0039794",
    "COLL": "00-0036554",
    "DARN": "00-0034869",
    "BROW": "00-0038597",
    "EWIL": "00-0038797",
    "WARD": "00-0040676",
    "AJON": "00-0033293",
    "JJET": "00-0036322",
    "EGBU": "00-0040129",
    "SKAT": "00-0040715",
    "KELC": "00-0030506",
    "TWAR": "00-0040128",
    "CORU": "00-0039738",
    "DIGG": "00-0031588",
    "DEVO": "00-0036912",
    "HHEN": "00-0033090",
    "JOHN": "00-0036040",
    "FREI": "00-0036894",
    "HARV": "00-0040730",
    "MMAY": "00-0039066",
    "NOEL": "00-0040138",
    "FANN": "00-0040663",
    "KAMA": "00-0033906",
    "COLE": "00-0039901",
    "CDOU": "00-0041523"
}


def fetch(url):
    req = urllib.request.Request(url, headers={"User-Agent": "fieldx-stats-updater"})
    with urllib.request.urlopen(req, timeout=120) as r:
        return r.read().decode("utf-8")


def supabase(method, path, body=None):
    url = os.environ["SUPABASE_URL"].rstrip("/") + "/rest/v1/" + path
    key = os.environ["SUPABASE_SECRET_KEY"]
    headers = {"apikey": key, "Content-Type": "application/json", "Prefer": "return=representation"}
    if key.startswith("eyJ"):  # legacy service_role key
        headers["Authorization"] = "Bearer " + key
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, method=method, headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            return json.loads(r.read().decode() or "null")
    except urllib.error.HTTPError as e:
        sys.exit(f"Supabase {method} {path} failed: {e.code} {e.read().decode()}")


def main():
    games = [g for g in csv.DictReader(io.StringIO(fetch(GAMES_URL)))
             if g["season"] == str(SEASON) and g["game_type"] == "REG"]
    by_week = defaultdict(list)
    for g in games:
        by_week[int(g["week"])].append(g)
    done_weeks = [w for w, gs in by_week.items() if w >= FIRST_WEEK and gs and all(g["result"] != "" for g in gs)]
    if not done_weeks:
        print("No completed week yet. Nothing to do.")
        return
    week = max(done_weeks)
    label = f"Week {week}"

    existing = supabase("GET", "stats_versions?select=label")
    if any(r["label"] == label for r in existing):
        print(f"{label} update already published. Nothing to do.")
        return

    rows = list(csv.DictReader(io.StringIO(fetch(STATS_URL))))
    stat_games = {r["game_id"] for r in rows if r["week"] == str(week)}
    missing = [g["game_id"] for g in by_week[week] if g["game_id"] not in stat_games]
    if missing:
        print(f"{label}: games are final but stats aren't loaded yet for {missing}. Will try again later.")
        return

    pts, gp = defaultdict(float), defaultdict(int)
    for r in rows:
        if r["season_type"] == "REG" and int(r["week"]) <= week:
            pts[r["player_id"]] += float(r["fantasy_points_ppr"] or 0)
            gp[r["player_id"]] += 1

    ppg = {}
    for tk, pid in PLAYER_IDS.items():
        if gp[pid]:
            ppg[tk] = round(pts[pid] / gp[pid], 4)
    if len(ppg) < 80 or any(not (0 <= v <= 60) for v in ppg.values()):
        sys.exit(f"Sanity check failed ({len(ppg)} players found). Not publishing.")

    supabase("POST", "stats_versions", {"label": label, "ppg": ppg})
    top = sorted(ppg.items(), key=lambda kv: -kv[1])[:5]
    print(f"Published {label} for {len(ppg)} players. Top PPG: {top}")


if __name__ == "__main__":
    main()
