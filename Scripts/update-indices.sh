#!/usr/bin/env bash
# update-indices.sh — bygger Sources/Stockmote/Resources/Indices.json.
#
# Indeksernes medlemmer skifter et par gange om året. Listen ligger i data og
# ikke i koden, så den kan opdateres uden at røre Swift:
#
#   S&P 500     github.com/datasets/s-and-p-500-companies (GICS sektor + branche)
#   Nasdaq 100  api.nasdaq.com/api/quote/list-type/nasdaq100
#   Dow Jones   Wikipedia-skabelonen "Dow Jones Industrial Average companies"
#   Europa      C25, DAX, Euro Stoxx 50, FTSE 100, CAC 40, OMXS30, OBX,
#               OMXH25, SMI og AEX: medlemmer fra Wikipedia, sektor og
#               markedsværdi fra Yahoo. Se Scripts/update-indices.py.
#
# Nasdaq 100-selskaber der ikke er i S&P 500 (ASML, ARM, Shopify …) har ingen
# GICS-klassifikation i nogen af de åbne kilder. De står i OVERRIDES nedenfor.
# Dukker et nyt op, falder scriptet tilbage på Nasdaq's egen sektor og siger
# det højt, så du kan tilføje det.
#
# Brug:
#   ./Scripts/update-indices.sh            # skriv Indices.json
#   ./Scripts/update-indices.sh --check    # vis forskellen, skriv intet

set -euo pipefail
cd "$(dirname "$0")/.."

CHECK=0
[ "${1:-}" = "--check" ] && CHECK=1

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

UA='Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15'

echo "==> Henter S&P 500"
curl -fsS --max-time 30 -o "$WORK/sp500.csv" \
  'https://raw.githubusercontent.com/datasets/s-and-p-500-companies/main/data/constituents.csv'

echo "==> Henter Nasdaq 100"
curl -fsS --max-time 30 -A "$UA" -H 'Accept: application/json' -o "$WORK/ndx.json" \
  'https://api.nasdaq.com/api/quote/list-type/nasdaq100'

echo "==> Henter Nasdaq's screener (fallback-sektorer)"
curl -fsS --max-time 60 -A "$UA" -H 'Accept: application/json' -o "$WORK/screener.json" \
  'https://api.nasdaq.com/api/screener/stocks?tableonly=true&download=true'

echo "==> Henter Dow Jones"
curl -fsS --max-time 30 -A 'StockmoteBuild/1.0' -o "$WORK/dow.json" \
  'https://en.wikipedia.org/w/api.php?action=parse&page=Template:Dow_Jones_Industrial_Average_companies&prop=text&format=json&formatversion=2'

OUT=Sources/Stockmote/Resources/Indices.json
[ "$CHECK" -eq 1 ] && OUT="$WORK/Indices.json"

python3 -I Scripts/update-indices.py "$WORK" "$OUT" Sources/Stockmote/Resources/Indices.json

[ "$CHECK" -eq 0 ] && echo "==> Skrev $OUT"
