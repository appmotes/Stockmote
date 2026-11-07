<img src="docs/app-icon.png" alt="The Stockmote icon: a small heatmap of green and red tiles with an arrow pointing up" width="96">

# Stockmote

**English** · [Dansk](README.da.md)

A macOS app — a window and a menu bar item — that shows the stock market as a heatmap: three US indices and ten European ones, from the S&P 500
to the Danish C25 and the German DAX — and any ETF or index fund you search for, shown stock by stock.

**This app was written by a machine intelligence.** All the code, the comments, the design, the icon, the scripts and
this README were made by Claude Opus 5.5 (Anthropic) from a human's description. No human has reviewed the code line by
line. Read the [Disclaimer](#disclaimer) before you trust it with anything.

![S&P 500, one day, dark theme](docs/map.png)

It is an ordinary Mac app with a Dock icon and a window you can resize, minimise and put in full screen — and it also
lives in the menu bar: click the icon there and a compact panel drops down with the same map. Each tile is a company; its
size is the market value and its colour is how much the stock has moved in the time range you picked. Markets and your
own lists sit in a sidebar on the left, each with its change right next to it.

The app speaks Danish and English; pick the language in settings. This README uses the English labels.

Apple frameworks only: SwiftUI, AppKit, WidgetKit and AppIntents. No third-party dependencies. Requires macOS 14 or
later.

## Disclaimer

Not investment advice. The app shows public quotes as they are. It is not made by or affiliated with Nasdaq, Yahoo,
S&P Dow Jones Indices, Nasdaq Copenhagen, Deutsche Börse, BlackRock, State Street, Invesco or any other exchange, index
or fund provider.

Quotes come from public endpoints at Yahoo Finance and Nasdaq, fund holdings from BlackRock (iShares), State Street
and Invesco, none of which need an account or API key. None of them is a
documented, promised API. Any of them can change or close without notice, and then the map goes grey and the status
line says which source failed. No analytics and no tracking.

## Features

- **A real Mac window.** Traffic lights over the sidebar, a transparent title bar level with the toolbar, resizing
  from every edge (down to 720 × 480), the green button for macOS full screen in its own Space, minimise to the Dock,
  zoom, and the size and position remembered between launches. Drag the empty part of the toolbar row to move the
  window; double-click it to zoom.
- **Menu bar panel.** The menu bar icon still opens the compact panel under it — the quick look. The window button
  at the bottom of the panel's sidebar (or ⌘O) opens the window. Panel and window show the same thing: pick an index
  in one and the other follows.
- **Dock, menu bar or both.** Settings → **Show Stockmote in**: **Dock and menu bar** (default), **Menu bar only**
  (no Dock icon; the window opens from the panel) or **Dock only** (no menu bar icon). Never neither. Closing the
  window does not quit — the app stays in the menu bar or the Dock, and clicking the Dock icon brings the window back.
  ⌘Q quits. The window opens at launch (**Open window at launch**, on by default), but not when Stockmote opens at
  login: then it waits quietly in the menu bar.
- **Menus.** Stockmote (About, Settings… ⌘,, Hide, Quit), File (Open Window ⌘O, New Watchlist ⌘N, Add Fund ⇧⌘N,
  Close Window ⌘W), Edit, View (the six time ranges on ⌥⌘1 … ⌥⌘6, Show as List ⌘L, Hide Sidebar ⌃⌘S, Replay the Day
  ⌘P, light/dark ⇧⌘T, Refresh ⌘R, Map Only ⇧⌘F, Enter Full Screen ⌃⌘F), Window and Help (the keyboard shortcuts). The
  menus follow the app's language, not the system's.
- **13 indices.** United States: S&P 500, Nasdaq 100, Dow Jones. Europe: 🇩🇰 C25, 🇩🇪 DAX, 🇪🇺 Euro Stoxx 50,
  🇬🇧 FTSE 100, 🇫🇷 CAC 40, 🇸🇪 OMXS30, 🇳🇴 OBX, 🇫🇮 OMXH25, 🇨🇭 SMI and 🇳🇱 AEX. ⌘1 … ⌘9 jump to the first nine.
- **Funds.** + next to **Funds** in the sidebar opens a dialog in the middle of the panel: type the name or ticker of
  an ETF or index fund (`SPY`, `SEC0`, `iShares Core MSCI World`, `SPIC25`) and pick a result. Its holdings are loaded
  right there, with a preview such as "237 stocks · largest: Taiwan Semiconductor 8.81%", and only a fund whose
  holdings could be found can be added — otherwise the dialog says so and **Add** stays off. Return adds and opens
  it; Esc cancels without closing the panel. The fund is shown
  exactly like an index — sector → industry → stock, zoom, hover, list, replay, full screen, widget — but each tile's
  size is the stock's **weight in the fund**, not its market value. The title shows the fund's own name and its own
  price change. Hover shows the weight, the list has a weight column, and the status line says where the holdings
  come from. Large funds (iShares Core MSCI World: ~1,200 stocks) are cut to the 500 largest by weight, and the status
  line says so. Funds are remembered across restarts; right-click to reload the holdings or remove the fund.
- **Six time ranges** in the segmented control at the top: 1D, 1U/1W (week), 1M, 3M, ÅTD/YTD and 1Å/1Y. The colour
  scale follows the range: full colour at ±3 % for a day, ±35 % for a year.
- **Sectors and industries.** Click a sector or industry header to go into it. The title becomes that level, with a
  back arrow and the way up underneath (`🇩🇰 C25 › Health Care`), which you can click; Esc does the same. Clicking
  the selected index in the sidebar again also takes you back to the whole map.
- **Zoom.** Pinch on the trackpad (or ⌘-scroll) to zoom where the pointer is; two-finger scroll or drag to move.
  Small tiles get their labels as they grow.
- **Replay the day** (▶ in the toolbar or ⌘P): the map animated through the time range — the trading
  day in 5-minute steps, a week in half hours, months day by day, a year week by week. A curve of the index runs
  under the map; drag in it to jump to a moment, or press space to play and pause, ← → to step. The title, the
  colours and the tooltip's price all follow the moment shown. 1×, 2× or 4× speed. Tile sizes stay put; only the
  colours move. In Map Only it plays in a loop, like a living picture of the market.
- **Full screen** (⌃⌘F or the green button): the window in macOS full screen, sidebar, toolbar and all, in its own
  Space.
- **Map Only** (⇧⌘F): the map alone, edge to edge, with no Dock, title or frame; the menu bar
  hides and slides in only if you push the pointer to the top. Hover, click and zoom still work. Esc first zooms out,
  then goes up a level, then leaves. ⇧⌘F, the menu bar icon or **Exit Map Only** in the
  right-click menu leave at once. On a MacBook with a notch the map starts below the notch, and the strip beside it
  shows the title, the change and the replay clock.
- **Hover** a tile for price (in its own currency), market value, sector, industry and the change.
- **Click** a tile to open the stock in the browser (Yahoo Finance, Google Finance, Nasdaq or Finviz).
  **Right-click** to add it to favourites or a watchlist, jump to its sector or industry, or copy the symbol.
- **Favorites** and **watchlists** in the sidebar under **My lists**, each with a
  search field that finds any US stock or any stock in the European indices. Favourites get a small star on the map.
  + makes a new watchlist and right-click → **Rename …** renames one, both in a small dialog over the panel or window;
  right-click to delete one.
- **List view** (⌘L): any map as a sortable list.
- **Light and dark theme**, switched with the sun/moon button in the toolbar (⇧⌘T; right-click to follow the system). The light theme is not the dark one inverted: white grout between the tiles, light grey
  for unchanged stocks and dark text wherever a tile is light.
- **Danish or English**, switched instantly without a restart. Numbers follow: `+0,31%` and `1,2 bio. $` in Danish,
  `+0.31%` and `$1.2T` in English.
- **Menu bar** shows the chosen index's change today next to the icon, both in green or red (or blue/orange).
- **Widget** for the desktop and Notification Centre in all four sizes: favourites, a watchlist, or an index, sector
  fund, sector or industry, in any time range. It follows the theme chosen in settings (system, light or dark). Clicking it opens the window on the matching view.
- **Everything that switches on also switches off** with the same click or key: the menu bar icon closes the panel
  (and Map Only), Settings in the panel goes back to where you were, ⌘0 the sidebar, ⌘L map/list, ⌃⌘F full screen,
  ⇧⌘F Map Only, and
  clicking a search suggestion that is already on the list (✓) removes it.
- **Esc** closes a dialog, then zooms out, then stops a replay, then goes up a level — in the panel, where it finally
  closes the panel, and in the window, which it never closes.
- **Narrow panels.** In the small size, long titles are shortened with … and the time-range control becomes a
  compact menu, so nothing is pushed out of the window.
- **Settings** (⌘, opens the standard Settings window; in the panel they are a page of their own): theme, colours
  (red/green or orange/blue for red–green colour blindness), panel size, language, Dock and/or menu bar, what the menu
  bar shows, open window at launch, launch at login, list tile size, refresh rate, which site and browser stocks
  open in.

| | |
| --- | --- |
| ![DAX in the light theme, English](docs/light.png) | ![C25](docs/c25.png) |
| DAX, light theme | C25 — Danish stocks in Danish kroner |
| ![Replay](docs/replay.png) | ![Full screen](docs/fullscreen.png) |
| Replaying the S&P 500's day, paused at 17.45 | Full screen with a notch: C25 replaying at 14.30 |
| ![Settings](docs/settings.png) | ![iShares Core MSCI World](docs/fund.png) |
| Settings, at the smallest panel size | A fund: iShares Core MSCI World, tiles sized by weight |
| ![Adding a fund](docs/fund-dialog.png) | |
| Adding a fund: its holdings are checked before it can be added | |

## Build

```bash
swift build
swift run Stockmote
```

## Make the .app bundle

```bash
./Scripts/make-app.sh --install --open
```

This builds release, packages `build/Stockmote.app` with the widget inside as `Contents/PlugIns/StockmoteWidget.appex`,
signs both ad hoc and, with `--install`, copies the app to `/Applications` (quitting a running copy first).

The widget appears in the gallery once the app is in `/Applications` and has been opened once: right-click the desktop
→ **Edit Widgets** → search for Stockmote.

## Where the data comes from

| What | Source | How often |
| --- | --- | --- |
| Price and change, all ranges, all indices | Yahoo Finance `v7/finance/spark` | Every minute while the panel is open and a market is open; every 5 min otherwise; every 30 min when all are closed |
| History for replay | The same endpoint with `interval` set (5m, 30m, 1d or 1wk) | When you start a replay, and again if you change index, list or range |
| Exchange rates (for sizing European stocks in dollars) | Yahoo Finance, `EURUSD=X` and friends | With the prices |
| US market value, name, search | Nasdaq screener (all ~7000 US stocks, 2 MB) | Every 30 min |
| Index members, sectors, European market values | `Indices.json`, bundled | When you run `update-indices.sh` |
| Fund search; sectors for foreign stocks in funds | Yahoo Finance `v1/finance/search` | As you type; once per new stock |
| Fund holdings: iShares ETFs, US and European (SOXX, IVV, SEC0, EUNL, CSPX …) | iShares' product lists (the ones the product screener on ishares.com loads, for the US, UK and German sites) and each fund's `latest-holdings.csv` | When the fund is added, then at most weekly; the product lists weekly |
| Fund holdings: SPDR ETFs (SPY, XLK, SPGM …) | State Street's daily spreadsheet (`holdings-daily-us-en-<ticker>.xlsx`) | When the fund is added, then at most weekly |
| Fund holdings: Invesco ETFs (QQQ, RSP …) | Invesco's JSON (`dng-api.invesco.com`) | As above |

**Nasdaq's screener lags.** Measured on a Friday afternoon it still showed Thursday's close, so it is used only for
size and search, and the market value is scaled by Yahoo's current price. Yahoo allows 20 symbols per call, so the
S&P 500 costs 26 calls, four at a time.

**European market values** come from Yahoo's fundamentals series in local currency, stored with the price at the
time. The app scales them by today's price and converts them to dollars, so a watchlist with both Novo Nordisk and
Apple gets fair sizes.

The **index figure** at the top and in the sidebar is the index's own (`^GSPC`, `^OMXC25`, `^GDAXI` …). If Yahoo does
not answer, the app falls back to a market-value-weighted average of the members, which is close but not official.

**Tiles are sized by market value in every index.** The real Dow Jones is price-weighted, but a map where the size is
the share price says little.

**Sectors.** US stocks use GICS. European stocks use Yahoo's classification, mapped to the GICS sector names so every
index shares one vocabulary; their industries keep Yahoo's names (`Drug Manufacturers – General`).

**Funds.** No open source has the holdings of every fund. The app tries, in this order:

1. **The fund's own holdings** at iShares (US and European iShares ETFs), State Street (every SPDR ETF) or Invesco.
   An iShares fund is found in iShares' own product lists by ticker — any listing: `SEC0` on Xetra, `SEMI` in
   London — or else by name, since the lists have one ticker per country (`IWDA` in Amsterdam is found as "iShares
   Core MSCI World UCITS ETF", the same fund as `SWDA` and `EUNL`). All three publish the full holdings with weight,
   ticker and trading currency; iShares also gives the exchange and the sector.
2. **One of the app's own indices**, if the fund's name says it tracks one: `iShares Core DAX`, `Sparindex INDEX OMX
   C25 KL`, `Vanguard 500 Index Admiral`. The holdings are then the index members, and tiles are sized by market value.
3. **A SPDR fund on a similar index**: MSCI World, MSCI ACWI and FTSE All-World → SPGM (MSCI ACWI IMI); emerging
   markets → SPEM; Europe/STOXX 600 → SPEU; the whole US market → SPTM. The status line says so ("Holdings of SPGM
   (SSGA), which tracks a similar index"). MSCI World leaves out emerging markets, so this is an approximation — the
   largest stocks are the same.
4. Otherwise: "Could not load the holdings for …".

Funds with a twist in the name — sector, factor, ESG, leverage, bonds — do not track the broad index and get no
stand-in. Vanguard, Zacks and stockanalysis.com were tried and left out: they turn away anything but a browser.

Foreign stocks in a fund get their Yahoo symbol from ticker and exchange where the provider names the exchange, as
iShares does (`ASML` on Euronext Amsterdam → `ASML.AS`, `000660` on the Korea Exchange → `000660.KS`), and otherwise
from ticker and currency (`7203` + JPY → `7203.T`, `700` + HKD → `0700.HK`, `SHEL` + GBP → `SHEL.L`). Euro stocks
without an exchange cannot be guessed (Paris, Frankfurt, Milan …) and are looked up by name, and so are stocks whose
guessed symbol Yahoo does not know (iShares writes Roche as `ROP`; Yahoo has `ROG.SW`). Sector and industry come from
`Indices.json` if the stock is there, otherwise from Yahoo's search, mapped to the GICS sector names, and as a last
resort from the fund's own file. The lookups are stored in `~/Library/Application Support/Stockmote/Funds/Names.json`,
iShares' product lists in `iShares.json` and the holdings in the same folder, so a fund only costs Yahoo calls the
first time. Yahoo answers 429 when asked too much;
the app then waits, and retries the lookups that failed one at a time.

**Opening hours** are per exchange and shown in your local time in the status line: `Closed · opens Mon 09.00`. Holidays are not known.

## Index members

```bash
./Scripts/update-indices.sh          # rewrite Indices.json
./Scripts/update-indices.sh --check  # show what changed, write nothing
```

The script ([update-indices.py](Scripts/update-indices.py)) takes about a minute:

- **S&P 500** from the `datasets/s-and-p-500-companies` list, with GICS sector and sub-industry.
- **Nasdaq 100** from Nasdaq's own list. Members outside the S&P 500 (ASML, Arm, Shopify …) have no open GICS source
  and are set by hand in `OVERRIDES`.
- **Dow Jones** from the Wikipedia template of its members.
- **The ten European indices** from the ticker table in each Wikipedia article. Sector, name and market value come
  from two Yahoo endpoints that need no cookie: the search and the fundamentals time series. Tickers where Wikipedia
  and Yahoo disagree go in `YAHOO_RENAMES` (Nordea is `NDA-DK.CO`).

Yahoo answers 429 if you run the script several times in a row. It waits and tries again; if it still fails, it stops
before writing, so the old file is left untouched.

You can override the bundled file without building: put your own `Indices.json` in
`~/Library/Application Support/Stockmote/` and click **Reload lists** in settings.

## The widget

Three things that Xcode normally does for a widget had to be done by hand, because the app is built with SwiftPM:

- **Entry point.** An extension must start in Foundation's `_NSExtensionMain`, not in `main`. Without it the process
  dies in ExtensionFoundation before WidgetKit gets going, and the widget never shows up in the gallery. The widget
  target is linked with `-e _NSExtensionMain` (see [Package.swift](Package.swift)).
- **AppIntents metadata.** The widget's settings (content, index, sector, range) must be described in
  `Metadata.appintents`. `make-app.sh` makes it with Xcode's `appintentsmetadataprocessor` from the constant values
  the compiler is asked to emit.
- **Sharing data without an app group.** A widget runs in a sandbox and cannot read the app's settings. An app group
  needs an Apple developer team, and Stockmote is signed ad hoc. Instead the app writes
  `~/Library/Application Support/Stockmote/Widget.json` (favourites, watchlists, indices, funds and their weights,
  sectors, market values, language), and the widget has a read-only exception for exactly that folder. Prices are not in the file: the widget
  fetches them from Yahoo itself, so it is fresh even when the app has not been opened.

It refreshes about every 15 minutes while a market is open and hourly otherwise; WidgetKit has the last word.

## Files

| File | Contents |
| --- | --- |
| [Sources/Stockmote/StockmoteApp.swift](Sources/Stockmote/StockmoteApp.swift) | `@main`, `AppDelegate` (launch, Dock / menu bar, reopen from the Dock), `stockmote://` links, snapshot mode |
| [Sources/Stockmote/MainWindow.swift](Sources/Stockmote/MainWindow.swift) | The main window and its title bar, the Settings window, Esc in the window |
| [Sources/Stockmote/MainMenu.swift](Sources/Stockmote/MainMenu.swift) | The main menu, in the app's language |
| [Sources/Stockmote/MenuBarPanel.swift](Sources/Stockmote/MenuBarPanel.swift) | Menu bar icon and coloured figure, panel window, placement, Esc |
| [Sources/Stockmote/PanelView.swift](Sources/Stockmote/PanelView.swift) | Sidebar, toolbar, status line, favourites, watchlists, search, list view |
| [Sources/Stockmote/Dialogs.swift](Sources/Stockmote/Dialogs.swift) | The dialogs centred over the panel: add a fund (search, check its holdings, add), new and rename watchlist |
| [Sources/Stockmote/HeatmapView.swift](Sources/Stockmote/HeatmapView.swift) | Hover, click, zoom, tooltip, right-click menu |
| [Sources/Stockmote/Fullscreen.swift](Sources/Stockmote/Fullscreen.swift) | Map Only: the borderless full-screen map and the notch strip |
| [Sources/Stockmote/Replay.swift](Sources/Stockmote/Replay.swift) | Replay the day: history, timeline, playback, the bar under the map |
| [Sources/Stockmote/SettingsView.swift](Sources/Stockmote/SettingsView.swift) | Settings and About |
| [Sources/Stockmote/MarketData.swift](Sources/Stockmote/MarketData.swift) | Quotes, exchange rates, refresh loop, Nasdaq screener |
| [Sources/Stockmote/Universe.swift](Sources/Stockmote/Universe.swift) | Loading `Indices.json` |
| [Sources/Stockmote/Funds.swift](Sources/Stockmote/Funds.swift) | Funds: search, holdings from iShares, State Street and Invesco, stand-in indices, foreign stock lookup, cache, .xlsx and CSV readers |
| [Sources/Stockmote/Lists.swift](Sources/Stockmote/Lists.swift) | Favourites and watchlists |
| [Sources/Stockmote/Preferences.swift](Sources/Stockmote/Preferences.swift) | Settings |
| [Sources/Stockmote/AppState.swift](Sources/Stockmote/AppState.swift) | What is selected, drill-down, zoom and the open dialog |
| [Sources/Stockmote/Browsers.swift](Sources/Stockmote/Browsers.swift) | Which browser links open in (from DRmote) |
| [Sources/Stockmote/WidgetSync.swift](Sources/Stockmote/WidgetSync.swift) | Writes `Widget.json` and reloads the widget |
| [Sources/StockmoteShared/Treemap.swift](Sources/StockmoteShared/Treemap.swift) | Squarified treemap layout |
| [Sources/StockmoteShared/HeatmapCanvas.swift](Sources/StockmoteShared/HeatmapCanvas.swift) | Drawing the tiles, shared by app, full screen and widget |
| [Sources/StockmoteShared/Style.swift](Sources/StockmoteShared/Style.swift) | Time ranges, themes, colour scale, number formats, panel colours |
| [Sources/StockmoteShared/Lang.swift](Sources/StockmoteShared/Lang.swift) | Danish and English |
| [Sources/StockmoteShared/Market.swift](Sources/StockmoteShared/Market.swift) | Symbols, opening hours, currencies |
| [Sources/StockmoteShared/Yahoo.swift](Sources/StockmoteShared/Yahoo.swift) | Yahoo client |
| [Sources/StockmoteShared/WidgetShare.swift](Sources/StockmoteShared/WidgetShare.swift) | The file shared with the widget |
| [Sources/StockmoteWidget/StockmoteWidget.swift](Sources/StockmoteWidget/StockmoteWidget.swift) | The widget and its settings |
| [Scripts/make-app.sh](Scripts/make-app.sh) | Packages and signs app and widget, makes the AppIntents metadata |
| [Scripts/update-indices.sh](Scripts/update-indices.sh), [update-indices.py](Scripts/update-indices.py) | Rebuild `Indices.json` |
| [Scripts/make-icon.swift](Scripts/make-icon.swift) | Draws the app icon |
| [Scripts/make-screenshots.sh](Scripts/make-screenshots.sh) | Renders the images in `docs/` |

## Screenshots

`./Scripts/make-screenshots.sh` renders them with live data. The app has a snapshot mode for it, which keeps its
settings apart from the real app's:

```bash
.build/release/Stockmote --snapshot out.png --index c25 --period 1M --theme light --lang en
```

Options: `--tab map|favorites|watchlists|settings`, `--index <id>`, `--period 1D|1U|1M|3M|ÅTD|1Å`,
`--sector "…"`, `--industry "…"`, `--size small|medium|large|huge`, `--list`, `--zoom 2.5`,
`--theme light|dark`, `--lang da|en`, `--no-sidebar`, `--fullscreen`, `--notch 32` (full screen as on a screen
with a notch), `--replay 0.4` (replay paused 40 % into the range), `--fund SPY` (add and show a fund),
`--fund-search "MSCI World"` (the add-fund dialog, open with results), `--fund-pick SEC0.DE` (with that result picked
and its holdings loaded — or the warning if none were found), `--fund-add` (and added), `--dialog new-list|rename-list`
(the watchlist dialogs), `--window 1200x780` (the main window's content at that size), `--settings` (the Settings
window). A snapshot draws the app's own views only: the window's title bar and traffic lights are drawn by macOS
and are not in the picture — their space at the top left is left empty, as in the window.

| | |
| --- | --- |
| ![Information Technology](docs/sector.png) | ![Nasdaq 100, one month, light](docs/nasdaq-1m.png) |
| A sector, after clicking its header | Nasdaq 100 over a month, light theme |
| ![Favourites](docs/favorites.png) | ![FTSE 100 in English](docs/english.png) |
| Favourites | FTSE 100, English |

## Licence

[MIT](LICENSE). You may use, change and pass on the code, commercially too, as long as the copyright line and the
licence text go with it. Stockmote has no third-party dependencies. The quotes and index lists belong to their
sources (Yahoo Finance, Nasdaq, Wikipedia and the index providers) and are not covered by this licence.
