#!/usr/bin/env bash
# update-indices.sh — builds Sources/Stockmote/Resources/Indices.json.
#
# Index membership changes a few times a year. The list lives in data rather
# than in code, so it can be updated without touching Swift:
#
#   S&P 500     github.com/datasets/s-and-p-500-companies (GICS sector + industry)
#   Nasdaq 100  api.nasdaq.com/api/quote/list-type/nasdaq100
#   Dow Jones   the Wikipedia template "Dow Jones Industrial Average companies"
#   Europe      C25, DAX, Euro Stoxx 50, FTSE 100, CAC 40, OMXS30, OBX,
#               OMXH25, SMI and AEX: members from Wikipedia, sector and
#               market cap from Yahoo. See Scripts/update-indices.py.
#
# Nasdaq 100 companies that aren't in the S&P 500 (ASML, ARM, Shopify …) have
# no GICS classification in any of the open sources. They're listed in
# OVERRIDES in update-indices.py. If a new one turns up, the script falls back
# to Nasdaq's own sector and says so loudly, so you can add it.
#
# Usage:
#   ./Scripts/update-indices.sh            # write Indices.json
#   ./Scripts/update-indices.sh --check    # show the diff, write nothing

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
