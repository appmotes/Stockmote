"""Builds Sources/Stockmote/Resources/Indices.json.

Called by update-indices.sh, which first downloads the US sources into a
working directory. Run it through that script, not directly.

US indices
    S&P 500     github.com/datasets/s-and-p-500-companies (GICS)
    Nasdaq 100  api.nasdaq.com/api/quote/list-type/nasdaq100
    Dow Jones   the Wikipedia template listing the members
    Market cap comes from Nasdaq's screener inside the app, not from here.

European indices
    Members     the ticker table in the Wikipedia article
    Sector      Yahoo's search (v1/finance/search), mapped to GICS names
    Size        Yahoo's fundamentals time series (trailingMarketCap) in local
                currency, plus the price at the same point, so the app can
                scale the market cap by the current price.
    Neither of the two Yahoo calls needs a crumb or cookie.
"""

import concurrent.futures
import csv
import datetime
import html
import json
import re
import sys
import time
import urllib.parse
import urllib.request

work, out = sys.argv[1], sys.argv[2]
old_path = sys.argv[3] if len(sys.argv) > 3 else None

UA = "Mozilla/5.0"
warnings = []

# ---------------------------------------------------------------------------
# Network

def get(url, attempts=7):
    # Yahoo answers 429 in bursts when you ask a lot. Back off longer each time.
    delay = 2.0
    for attempt in range(attempts):
        try:
            req = urllib.request.Request(url, headers={"User-Agent": UA})
            with urllib.request.urlopen(req, timeout=30) as r:
                return r.read()
        except urllib.error.HTTPError as e:
            if e.code in (429, 500, 502, 503) and attempt < attempts - 1:
                time.sleep(delay)
                delay *= 2
                continue
            raise
        except Exception:
            if attempt < attempts - 1:
                time.sleep(delay)
                continue
            raise


def get_json(url):
    return json.loads(get(url))


# ---------------------------------------------------------------------------
# USA

# GICS for Nasdaq 100 companies outside the S&P 500.
OVERRIDES = {
    "ASML": ("ASML Holding", "Information Technology", "Semiconductor Materials & Equipment"),
    "MSTR": ("Strategy", "Information Technology", "Application Software"),
    "ALNY": ("Alnylam Pharmaceuticals", "Health Care", "Biotechnology"),
    "MELI": ("MercadoLibre", "Consumer Discretionary", "Broadline Retail"),
    "NBIS": ("Nebius Group", "Information Technology", "Internet Services & Infrastructure"),
    "SHOP": ("Shopify", "Information Technology", "Internet Services & Infrastructure"),
    "CCEP": ("Coca-Cola Europacific Partners", "Consumer Staples", "Soft Drinks & Non-alcoholic Beverages"),
    "PDD":  ("PDD Holdings", "Consumer Discretionary", "Broadline Retail"),
    "RKLB": ("Rocket Lab", "Industrials", "Aerospace & Defense"),
    "ARM":  ("Arm Holdings", "Information Technology", "Semiconductors"),
    "TRI":  ("Thomson Reuters", "Industrials", "Research & Consulting Services"),
    "FER":  ("Ferrovial", "Industrials", "Construction & Engineering"),
    "ALAB": ("Astera Labs", "Information Technology", "Semiconductors"),
    "CRWV": ("CoreWeave", "Information Technology", "Internet Services & Infrastructure"),
    "SPCX": ("SpaceX", "Industrials", "Aerospace & Defense"),
}

# The Wikipedia template only gives company names. Name -> ticker.
DOW = {
    "3M": "MMM", "Alphabet": "GOOGL", "Amazon": "AMZN", "American Express": "AXP",
    "Amgen": "AMGN", "Apple": "AAPL", "Boeing": "BA", "Caterpillar": "CAT",
    "Chevron": "CVX", "Cisco": "CSCO", "Coca-Cola": "KO", "Disney": "DIS",
    "Goldman Sachs": "GS", "Home Depot": "HD", "Honeywell": "HON",
    "Honeywell Technologies": "HON", "IBM": "IBM", "Johnson & Johnson": "JNJ",
    "JPMorgan Chase": "JPM", "McDonald's": "MCD", "Merck": "MRK",
    "Microsoft": "MSFT", "Nike": "NKE", "Nvidia": "NVDA",
    "Procter & Gamble": "PG", "Salesforce": "CRM", "Sherwin-Williams": "SHW",
    "Travelers": "TRV", "UnitedHealth": "UNH", "Visa": "V", "Walmart": "WMT",
    "Verizon": "VZ", "Intel": "INTC", "Dow": "DOW", "Walgreens": "WBA",
    "Amazon.com": "AMZN",
}

NASDAQ_SECTOR = {
    "Technology": "Information Technology", "Telecommunications": "Communication Services",
    "Finance": "Financials", "Basic Materials": "Materials",
}

stocks = {}
sp500 = []
for row in csv.DictReader(open(f"{work}/sp500.csv")):
    sym = row["Symbol"].strip()
    sp500.append(sym)
    stocks[sym] = {"symbol": sym, "name": row["Security"].strip(),
                   "sector": row["GICS Sector"].strip(), "industry": row["GICS Sub-Industry"].strip(),
                   "currency": "USD"}

screener = {r["symbol"].replace("/", "."): r for r in json.load(open(f"{work}/screener.json"))["data"]["rows"]}

ndx = []
for r in json.load(open(f"{work}/ndx.json"))["data"]["data"]["rows"]:
    sym = r["symbol"].strip().replace("/", ".")
    ndx.append(sym)
    if sym in stocks:
        continue
    if sym in OVERRIDES:
        name, sector, industry = OVERRIDES[sym]
    else:
        s = screener.get(sym, {})
        name = r.get("companyName") or s.get("name") or sym
        sector = NASDAQ_SECTOR.get(s.get("sector", ""), s.get("sector") or "Øvrige")
        industry = s.get("industry") or "Øvrige"
        warnings.append(f"{sym} ({name}) mangler i OVERRIDES — bruger Nasdaq's '{sector} / {industry}'")
    stocks[sym] = {"symbol": sym, "name": name, "sector": sector, "industry": industry, "currency": "USD"}

text = json.load(open(f"{work}/dow.json"))["parse"]["text"]
text = re.sub(r"<style.*?</style>", "", text, flags=re.S)
# The template's own documentation sits below the navbox and has <li>s too.
text = text.split("Template documentation")[0]
names = [re.sub(r"<[^>]+>", "", html.unescape(c)).strip() for c in re.findall(r"<li>(.*?)</li>", text, re.S)]
dow = []
for name in names:
    if not name or "{{" in name:
        continue
    sym = DOW.get(name)
    if sym is None:
        warnings.append(f"Dow: kender ikke tickeren for '{name}' — tilføj den i DOW")
        continue
    if sym not in stocks:
        warnings.append(f"Dow: {sym} ({name}) er ikke i S&P 500-listen")
        continue
    if sym not in dow:
        dow.append(sym)
if len(dow) != 30:
    warnings.append(f"Dow har {len(dow)} selskaber, ikke 30")

US_HOURS = {"timezone": "America/New_York", "open": "09:30", "close": "16:00"}
indices = [
    {"id": "sp500", "name": "S&P 500", "region": "us", "flag": "🇺🇸", "benchmark": "^GSPC", **US_HOURS, "symbols": sp500},
    {"id": "ndx", "name": "Nasdaq 100", "region": "us", "flag": "🇺🇸", "benchmark": "^NDX", **US_HOURS, "symbols": ndx},
    {"id": "dji", "name": "Dow Jones", "region": "us", "flag": "🇺🇸", "benchmark": "^DJI", **US_HOURS, "symbols": dow},
]

# ---------------------------------------------------------------------------
# Europe

def yahoo_plain(t):
    return t.strip()

def yahoo_suffix(suffix):
    """'MAERSK B' -> 'MAERSK-B.CO', 'BT.A' -> 'BT-A.L', 'RR.' -> 'RR.L'."""
    def convert(t):
        t = t.strip().rstrip(".")
        t = re.sub(r"^[A-Z]+:\s*", "", t)          # "OSE: AKRBP"
        t = t.replace(" ", "-").replace(".", "-")
        return f"{t}.{suffix}"
    return convert

EUROPE = [
    # id, name, flag, Wikipedia page, benchmark, time zone, opens, closes, ticker conversion
    ("c25", "C25", "🇩🇰", "OMX_Copenhagen_25", "^OMXC25", "Europe/Copenhagen", "09:00", "17:00", yahoo_suffix("CO")),
    ("dax", "DAX", "🇩🇪", "DAX", "^GDAXI", "Europe/Berlin", "09:00", "17:30", yahoo_plain),
    ("sx5e", "Euro Stoxx 50", "🇪🇺", "EURO_STOXX_50", "^STOXX50E", "Europe/Berlin", "09:00", "17:30", yahoo_plain),
    ("ftse", "FTSE 100", "🇬🇧", "FTSE_100_Index", "^FTSE", "Europe/London", "08:00", "16:30", yahoo_suffix("L")),
    ("cac", "CAC 40", "🇫🇷", "CAC_40", "^FCHI", "Europe/Paris", "09:00", "17:30", yahoo_plain),
    ("omxs30", "OMXS30", "🇸🇪", "OMX_Stockholm_30", "^OMX", "Europe/Stockholm", "09:00", "17:30", yahoo_plain),
    ("obx", "OBX", "🇳🇴", "OBX_Index", "OBX.OL", "Europe/Oslo", "09:00", "16:20", yahoo_suffix("OL")),
    ("omxh25", "OMXH25", "🇫🇮", "OMX_Helsinki_25", "^OMXH25", "Europe/Helsinki", "10:00", "18:30", yahoo_plain),
    ("smi", "SMI", "🇨🇭", "Swiss_Market_Index", "^SSMI", "Europe/Zurich", "09:00", "17:30", yahoo_suffix("SW")),
    ("aex", "AEX", "🇳🇱", "AEX_index", "^AEX", "Europe/Amsterdam", "09:00", "17:30", yahoo_plain),
]

# Yahoo's sectors -> the GICS names, so all indices speak the same language.
YAHOO_SECTOR = {
    "Technology": "Information Technology", "Healthcare": "Health Care",
    "Financial Services": "Financials", "Consumer Cyclical": "Consumer Discretionary",
    "Consumer Defensive": "Consumer Staples", "Basic Materials": "Materials",
    "Industrials": "Industrials", "Energy": "Energy", "Utilities": "Utilities",
    "Real Estate": "Real Estate", "Communication Services": "Communication Services",
}


def cells(row):
    return [html.unescape(re.sub(r"<[^>]+>", "", c)).strip()
            for c in re.findall(r"<t[hd][^>]*>(.*?)</t[hd]>", row, re.S)]


def wiki_members(page):
    data = get_json("https://en.wikipedia.org/w/api.php?action=parse&prop=text&format=json"
                    f"&formatversion=2&redirects=1&page={page}")
    text = data["parse"]["text"]
    for m in re.finditer(r"<table[^>]*wikitable[^>]*>", text):
        table = text[m.start():].split("</table>")[0]
        rows = table.split("</tr>")
        header = cells(rows[0])
        ticker_cols = [i for i, h in enumerate(header) if "icker" in h]
        if not ticker_cols:
            continue
        col = ticker_cols[0]
        tickers = []
        for row in rows[1:]:
            c = cells(row)
            if len(c) > col and c[col]:
                tickers.append(re.sub(r"\[.*?\]", "", c[col]).strip())
        return tickers
    return []


def clean_industry(text):
    return (text or "Øvrige").replace("—", " – ")


def profile(symbol):
    """Name, sector and industry from Yahoo's search."""
    q = urllib.parse.quote(symbol)
    data = get_json(f"https://query2.finance.yahoo.com/v1/finance/search?q={q}&quotesCount=5&newsCount=0")
    for quote in data.get("quotes", []):
        if quote.get("symbol") == symbol:
            return quote
    return None


def market_cap(symbol):
    """Latest trailingMarketCap in local currency."""
    q = urllib.parse.quote(symbol)
    start = int(time.time()) - 120 * 86400
    data = get_json("https://query2.finance.yahoo.com/ws/fundamentals-timeseries/v1/finance/timeseries/"
                    f"{q}?type=trailingMarketCap&period1={start}&period2={int(time.time())}")
    for result in data.get("timeseries", {}).get("result", []):
        values = [v for v in result.get("trailingMarketCap", []) or [] if v]
        if values:
            last = values[-1]
            return last["reportedValue"]["raw"], last.get("currencyCode")
    return None, None


def spark(symbols):
    """Price and currency for up to 20 symbols."""
    joined = urllib.parse.quote(",".join(symbols), safe=",")
    data = get_json(f"https://query2.finance.yahoo.com/v7/finance/spark?symbols={joined}&range=1d&interval=1d")
    out = {}
    for item in (data.get("spark") or {}).get("result") or []:
        meta = (item.get("response") or [{}])[0].get("meta") or {}
        out[item["symbol"]] = (meta.get("regularMarketPrice"), meta.get("currency"))
    return out


# Tickers where Wikipedia and Yahoo disagree.
YAHOO_RENAMES = {"NDA.CO": "NDA-DK.CO"}

europe_members = {}
for idx_id, name, flag, page, bench, tz, open_, close, convert in EUROPE:
    tickers = [YAHOO_RENAMES.get(convert(t), convert(t)) for t in wiki_members(page)]
    tickers = list(dict.fromkeys(t for t in tickers if t and not t.startswith(".")))
    if not tickers:
        warnings.append(f"{name}: fandt ingen tickertabel på Wikipedia ({page})")
    europe_members[idx_id] = tickers
    print(f"    {name}: {len(tickers)} tickers fra Wikipedia", flush=True)

european = sorted({t for ts in europe_members.values() for t in ts})
print(f"==> Slår {len(european)} europæiske aktier op hos Yahoo", flush=True)

prices = {}
for i in range(0, len(european), 20):
    try:
        prices.update(spark(european[i:i + 20]))
    except Exception as e:
        warnings.append(f"Kurser for {european[i]} … fejlede: {e}")
    time.sleep(0.3)


def lookup(symbol):
    try:
        p = profile(symbol)
    except Exception as e:
        p = None
    try:
        cap, cap_currency = market_cap(symbol)
    except Exception:
        cap, cap_currency = None, None
    return symbol, p, cap, cap_currency


with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
    results = list(pool.map(lookup, european))

for symbol, p, cap, cap_currency in results:
    price, currency = prices.get(symbol, (None, None))
    if price is None:
        warnings.append(f"{symbol}: Yahoo kender ikke symbolet — springes over")
        continue
    if p is None:
        warnings.append(f"{symbol}: ingen sektor hos Yahoo")
    if cap is None:
        warnings.append(f"{symbol}: ingen markedsværdi hos Yahoo")
    sector = YAHOO_SECTOR.get((p or {}).get("sector", ""), (p or {}).get("sector") or "Øvrige")
    stocks[symbol] = {
        "symbol": symbol,
        "name": (p or {}).get("longname") or (p or {}).get("shortname") or symbol,
        "sector": sector,
        "industry": clean_industry((p or {}).get("industry")),
        "currency": currency or "EUR",
        "cap": cap,
        "capCurrency": cap_currency or currency,
        "capPrice": price,
    }

# Share classes (MAERSK A/B etc.) each get the whole company's market cap.
# Split it between them, so the company doesn't take up double the space.
by_name = {}
for symbol in european:
    if symbol in stocks:
        by_name.setdefault(stocks[symbol]["name"], []).append(symbol)
for name, symbols in by_name.items():
    if len(symbols) > 1:
        caps = {stocks[s]["cap"] for s in symbols}
        if len(caps) == 1 and None not in caps:
            for s in symbols:
                stocks[s]["cap"] = stocks[s]["cap"] / len(symbols)

for idx_id, name, flag, page, bench, tz, open_, close, convert in EUROPE:
    members = [t for t in europe_members[idx_id] if t in stocks]
    if members:
        indices.append({"id": idx_id, "name": name, "region": "eu", "flag": flag, "benchmark": bench,
                        "timezone": tz, "open": open_, "close": close, "symbols": members})

# ---------------------------------------------------------------------------

used = {s for idx in indices for s in idx["symbols"]}
payload = {
    "updated": datetime.date.today().isoformat(),
    "indices": indices,
    "stocks": sorted((stocks[s] for s in used), key=lambda s: s["symbol"]),
}

if old_path:
    try:
        old = {i["id"]: set(i["symbols"]) for i in json.load(open(old_path))["indices"]}
        for idx in indices:
            before = old.get(idx["id"])
            if before is None:
                print(f"    {idx['name']}: nyt indeks")
                continue
            added = sorted(set(idx["symbols"]) - before)
            removed = sorted(before - set(idx["symbols"]))
            if added or removed:
                print(f"    {idx['name']}: +{added} -{removed}")
    except FileNotFoundError:
        pass

with open(out, "w") as f:
    json.dump(payload, f, ensure_ascii=False, indent=1)
    f.write("\n")

for idx in indices:
    print(f"    {idx['flag']} {idx['name']}: {len(idx['symbols'])} aktier")
for w in warnings:
    print(f"    ADVARSEL: {w}")
