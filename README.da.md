<img src="docs/app-icon.png" alt="Stockmotes ikon: et lille heatmap af grønne og røde felter med en pil der peger op" width="96">

# Stockmote

[English](README.md) · **Dansk**

En macOS-app — et vindue og et menubar-ikon — der viser aktiemarkedet som et heatmap: tre amerikanske indekser og ti europæiske, fra S&P
500 til danske C25 og tyske DAX — og enhver ETF eller indeksfond du søger frem, vist aktie for aktie.

**Denne app er skrevet af en maskinintelligens.** Al koden, kommentarerne, designet, ikonet, scripts og denne README
er lavet af Claude Opus 5.5 (Anthropic) ud fra et menneskes beskrivelse. Intet menneske har gennemgået koden linje for
linje. Læs [Ansvarsfraskrivelsen](#ansvarsfraskrivelse) før du stoler på den med noget.

![Overblikket: lister, fonde og alle indekser som små kort](docs/overview.png)

Den er en almindelig Mac-app med ét vindue, du kan ændre størrelse på, minimere og sætte i fuld skærm, et dock-ikon —
og et ikon i menubaren, der henter vinduet frem, uanset hvor du er. Hvert felt er et
selskab; størrelsen er markedsværdien, og farven er hvor meget aktien har bevæget sig i det tidsrum du har valgt.
Den åbner på et **overblik** over alle markeder og lister; et klik går ind i et kort, og et klik på et felt ind i
selve aktien.

Appen taler dansk og engelsk.

Kun Apples egne frameworks: SwiftUI, AppKit, WidgetKit og AppIntents. Ingen tredjepartsafhængigheder. Kræver macOS 14
eller nyere.

## Ansvarsfraskrivelse

Ikke investeringsrådgivning. Appen viser offentlige kurser som de er. Den er ikke lavet af eller forbundet med Nasdaq,
Yahoo, S&P Dow Jones Indices, Nasdaq Copenhagen, Deutsche Börse, BlackRock, Vanguard, DWS, Amundi, State Street, Invesco, Nordnet, Morningstar eller nogen anden børs,
indeks- eller fondsudbyder.

Kurserne kommer fra offentlige adresser hos Yahoo Finance og Nasdaq, fondenes beholdninger fra BlackRock (iShares),
Vanguard, DWS (Xtrackers), Amundi, State Street, Invesco og Nordnet, indre værdi for unoterede fonde fra Morningstar, alle uden konto eller API-nøgle. Ingen af
dem er et dokumenteret, lovet API. De kan alle ændre sig eller lukke uden varsel; så bliver kortet gråt, og
statuslinjen siger hvilken kilde der fejlede. Ingen analytics og ingen sporing.

**Alle tal er læst af rigtige kurser.** Findes der ingen — en aktie noteret efter tidsrummets start, et indeks hvis
historik Yahoo ikke har så langt tilbage — viser appen **–** i stedet for et tal regnet ud på anden vis. To afledte
tal vises, fordi de er kutyme, og hvert er navngivet der hvor det står: en fonds **indikative** værdi for dagen (≈,
se *Kurser for danske fonde og Nordnets fonde*) og **gennemsnittet** af en liste eller en sektor.

## Funktioner

- **Et rigtigt Mac-vindue.** Trafiklys i værktøjslinjen, en gennemsigtig titellinje i højde med værktøjslinjen,
  størrelsesændring fra alle kanter (ned til 720 × 480), den grønne knap til macOS' fulde skærm i sit eget Space,
  minimér til Dock, zoom, og størrelse og placering huskes mellem starter. Træk i den tomme del af værktøjslinjen for
  at flytte vinduet; dobbeltklik for at zoome.
- **Ét vindue, åbnet fra menubaren.** Et klik på ikonet i menubaren henter vinduet frem — åbner det, hvis det er
  lukket eller minimeret, og skifter til det fra den app, du er i. Et klik, mens vinduet allerede er forrest, lukker
  det igen; appen kører videre. Højreklik (eller ⌃-klik) på ikonet giver **Åbn vindue**, **Indstillinger …** og
  **Afslut Stockmote**. I Kun kortet lukker ikonet Kun kortet.
- **Dock, menubar eller begge.** Indstillinger → **Vis Stockmote i**: **Dock og menubar** (standard), **Kun menubar**
  (intet dock-ikon og ingen egen menulinje; vinduet åbnes fra ikonet i menubaren, og dets højrekliksmenu afslutter)
  eller **Kun Dock** (intet ikon i menubaren). Aldrig ingen af dem. Når
  vinduet lukkes, kører appen videre i menubaren eller Dock, og et klik på dock-ikonet henter vinduet frem igen. ⌘Q
  afslutter. Vinduet åbner ved start (**Åbn vindue ved start**, slået til som standard), men ikke når Stockmote
  starter ved login: så venter den stille i menubaren.
- **Menuer.** Stockmote (Om, Indstillinger … ⌘,, Skjul, Afslut), Arkiv (Åbn vindue ⌘O, Ny watchliste ⌘N, Søg … ⌘K,
  Luk vindue ⌘W), Rediger, Vis (de ti tidsrum på ⌥⌘1 … ⌥⌘9 og ⌥⌘0, Vis som liste ⌘L, Overblik ⌘0, Tilbage ⌘[,
  Seismograf ⌘P, lyst/mørkt ⇧⌘T, Opdatér ⌘R, Kun kortet ⇧⌘F, Fuld skærm ⌃⌘F), Vindue og Hjælp (tastaturgenvejene).
  Menuerne følger appens sprog, ikke systemets.
- **Overblikket** er startskærmen. Under et bånd med dagens handelstider i din egen tid (Europa 9.00–17.30 og USA
  15.30–22.00 set fra Danmark, med en markør for nu; helligdage kendes ikke) kommer tre afsnit: **Mine** (Favoritter,
  hver watchliste og hver fond du har tilføjet), **USA** og **Europa**. Hvert kort har navnet, ændringen i det valgte
  tidsrum — indeksets eller fondens eget tal, eller en listes gennemsnit mærket *gns.* — og et lille kort over de
  største aktier, hver farvet efter sin egen ændring. Klik på et kort for at åbne dets kort. Hold musen over en fond
  eller en watchliste for et lille ✕ der fjerner den (eller højreklik: hent igen, kopiér symbol, omdøb, fjern); en
  besked nederst tilbyder **Fortryd**.
- **Kortet** fylder vinduet. Værktøjslinjen har en tilbage-pil og vejen tilbage som et brødkrummespor man kan klikke
  på (`Overblik › S&P 500 › Information Technology › Semiconductors`), titlen og dens ændring, tidsvælgeren,
  seismografen, kort/liste og **Søg ⌘K**.
- **13 indekser.** USA: S&P 500, Nasdaq 100, Dow Jones. Europa: 🇩🇰 C25, 🇩🇪 DAX, 🇪🇺 Euro Stoxx 50, 🇬🇧 FTSE 100,
  🇫🇷 CAC 40, 🇸🇪 OMXS30, 🇳🇴 OBX, 🇫🇮 OMXH25, 🇨🇭 SMI og 🇳🇱 AEX. ⌘1 … ⌘9 hopper til de første ni, ⌘0 til overblikket.
- **Søg** (⌘K, knappen i værktøjslinjen eller /) er den ene måde at finde og tilføje ting på. Resultaterne kommer i
  tre grupper: **Indeks** (Åbn), **Aktier** (☆ for favorit, **Åbn** for aktiens side og **+ <liste>** når en watchliste
  er på skærmen — så tilføjer Retur til den liste) og **Fonde**. ↑ ↓ vælger, Retur gør det første, Esc lukker.
  **+ Ny watchliste** nederst laver en liste og åbner den.
- **Fonde.** Skriv navn eller ticker på en ETF eller indeksfond i søgningen (`SPY`, `VWCE`, `XDWD`, `iShares Core MSCI
  World`, `SPIC25`, `Nordnet Danmark Indeks`) og klik **Tilføj** (eller Retur). Beholdningen hentes først, med en
  smagsprøve som "237 aktier · største: Taiwan Semiconductor 8,81%", og kun en fond hvis beholdning kunne findes,
  tilføjes og åbnes — ellers siger rækken hvorfor. En obligations-, pengemarkeds- eller blandet fond får en besked om
  at den ikke ejer aktier, i stedet for et tomt kort. **Tilføjet ✓** på en fond der allerede er der, fjerner den.
  Fonden vises
  præcis som et indeks — sektor → branche → aktie, zoom, hover, liste, seismograf, fuld skærm, widget — men hvert
  felts størrelse er aktiens **vægt i fonden**, ikke dens markedsværdi. Titlen viser fondens eget navn og dens egen
  kursændring. Hover viser vægten, listen har en vægt-kolonne, og statuslinjen siger hvor beholdningen kommer fra — og for
  Vanguard, der offentliggør månedligt, hvilken dato den er fra ("Beholdning fra Vanguard pr. 30. sep.").
  Store fonde (iShares Core MSCI World: ~1200 aktier) beskæres til de 500 største efter vægt, og det står i
  statuslinjen. Danske investeringsforeninger og de fonde Nordnet sælger, kan også findes (se *Hvor data kommer fra*).
  Fondene huskes på tværs af genstart; højreklik for at hente beholdningen igen eller fjerne fonden.
- **Ti tidsrum** i den segmenterede kontrol øverst: 1D, 1U, 1M, 3M, 6M, ÅTD, 1Å, 3Å, 5Å og Alt (på engelsk 1W, YTD,
  1Y, 3Y, 5Y og All). Under hvert står ændringen i det du ser på over det tidsrum — indeksets eget tal, fondens egen
  kurs, en listes gennemsnit — så tidsrummene kan sammenlignes uden at klikke sig igennem dem; "–" mens det hentes,
  eller hvis der ikke er en kurs så langt tilbage. Hold markøren over et tidsrum for at se hvorfra tallet er målt.
  **3Å** regnes fra lukkekursen på eller lige før samme dag for tre år siden. **Alt** regnes fra den første kurs
  Yahoo har: titlen skriver året ("Siden 1927" for S&P 500), og da hver aktie har sin egen første kurs — Apple 1980,
  Airbnb 2020 — siger statuslinjen det, og hvert felts tooltip giver datoen. En aktie uden kurs for hele tidsrummet
  (noteret senere) forbliver grå i stedet for at blive målt over et kortere stykke, og statuslinjen tæller dem. Store
  ændringer får korte tal: `+9.439%`, `+41,7K%`, `+1,1M%`. Farveskalaen følger tidsrummet: fuld farve ved ±3 % for en
  dag, 20 % for et halvt år, 35 % for et år, 50 % for tre og 80 % for fem. For Alt er den logaritmisk — fuld grøn ved
  ×100, fuld rød ved −90 % — for ændringerne siden første kurs går fra −90 % til +500.000 %, og på en lige skala ville
  alle felter have fuld farve.
- **Sektorer og brancher.** Klik på en sektor- eller branchestrimmel for at gå ind i den. Titlen bliver det niveau,
  og brødkrummesporet over den fører op igen (`Overblik › 🇩🇰 C25 › Health Care`); pilen og Esc går et niveau op, og
  fra toppen af et kort til overblikket.
- **Zoom.** Knib på trackpad'en (eller ⌘-scroll) for at zoome der hvor markøren er; to-finger-scroll eller træk for
  at flytte rundt. Små felter får navn efterhånden som de vokser.
- **Seismograf** (bølgen i værktøjslinjen, ⌘P eller mellemrum på et kort): en skuffe under kortet med én stribe pr.
  barn af det niveau du står på — et indeks' sektorer, en sektors brancher, en branches eller en listes aktier (de tolv
  største; seks i et lavt vindue) — og en totalrække øverst. Hver kolonne er et skridt i tidsrummet: handelsdagen i
  5-minutters skridt, en uge i halve timer, måneder og tre år dag for dag, et og fem år uge for uge, Alt måned for
  måned (eller kvartal for kvartal for lange historikker), højst 400 skridt. Hver celle er farvet efter rækkens
  ændring på det tidspunkt. Totalrækken er indeksets eller fondens eget forløb (en listes gennemsnit, mærket som
  sådan); et indeks hvis egen historik mangler, får en tom række i stedet for en erstatning. Sektor- og
  branchrækker er medlemmernes ændringer vægtet efter markedsværdi (efter fondens vægte i en fond), mærket *gns.*.
  Knappen og ⌘P åbner den på pause ved det seneste tidspunkt; mellemrum på et kort åbner den og afspiller med det
  samme. Træk i markøren, brug ← → til et skridt eller mellemrum til afspil/pause, i 1×, 2× eller 4×; kortet, titlen og
  kursen i tooltippen følger tidspunktet. Klik på en rækkes navn for at gå ind i den (en aktierække åbner aktien).
  Felternes størrelse står fast; kun farverne bevæger sig. I Kun kortet kører den i ring, som et levende billede af
  markedet.
- **Fuld skærm** (⌃⌘F eller den grønne knap): vinduet i macOS' fulde skærm, med værktøjslinje og det hele, i sit
  eget Space.
- **Kun kortet** (⇧⌘F): kortet alene, kant til kant, uden dock, titel eller ramme; menubaren
  skjules og glider kun frem hvis man fører musen helt op. Hover, klik og zoom virker stadig. Esc zoomer først ud,
  går så et niveau op og lukker til sidst. ⇧⌘F, menubar-ikonet eller **Luk Kun kortet** i højrekliksmenuen
  lukker med det samme. På en MacBook med notch starter kortet under notchen, og båndet ved siden af viser titel,
  ændring og klokkeslættet for det viste øjeblik.
- **Hold musen over** et felt for kurs (i aktiens egen valuta), markedsværdi, sektor, branche og ændring.
- **Klik** på et felt (eller en række i listen) for at åbne **aktiens side**: kurs og ændring i tidsrummet, et
  candlestick-diagram over tidsrummet ud fra Yahoos egne åbnings-, høj-, lav- og lukkekurser (5-minutters lys for en
  dag, halve timer for en uge, dage op til år til dato, uger for et, tre og fem år, måneder for Alt) med volumen
  nedenunder og lysets åbning, høj, lav, luk og bevægelse når du peger; har Yahoo ingen lys, siger siden det.
  Nøgletallene er kun dem appen har: markedsværdi, vægten i den fond du kom fra, 52-ugers spændet i daglige
  lukkekurser, dagens ændring, sektor, branche, børs og symbol. **Samme industri** er et lille kort over dens
  ligemænd (klik for at gå til en), **Også i** viser de andre indekser, fonde og lister den er i, **☆ Favorit** og
  **+ Liste** (med *Ny liste med …*) tilføjer den, og **Åbn på Yahoo Finance** (eller den side der er valgt i
  indstillingerne, i den valgte browser) er den ene vej ud på nettet. **Højreklik** på et felt for aktiens side,
  nettet, favoritter eller en watchliste, dens sektor eller branche eller for at kopiere symbolet.
- **Favoritter** og **watchlister** står på overblikket under **Mine**. Tilføj aktier med ☆ eller **+ <liste>** i
  søgningen, på aktiens side eller i højrekliksmenuen. Favoritter får en lille stjerne på kortet. **+ Ny watchliste**
  i søgningen laver en; højreklik på dens kort → **Omdøb …** omdøber den, og ✕ eller højreklik sletter den (med
  Fortryd).
  En listes tal er gennemsnittet af dens aktier med lige vægt, og titlen skriver **gennemsnit**; en sektors eller
  branches er vægtet efter markedsværdi (efter fondens vægte i en fond).
- **Listevisning** (⌘L): ethvert kort som en sortérbar liste.
- **Lyst og mørkt tema**, skiftet med sol/måne-knappen i værktøjslinjen (⇧⌘T; højreklik for at følge systemet). Det lyse er ikke det mørke vendt om: hvide fuger mellem felterne, lysegrå for uændrede
  aktier og mørk tekst hvor et felt er lyst.
- **Dansk eller engelsk**, skiftet med det samme uden genstart. Tallene følger med: `+0,31%` og `1,2 bio. $` på
  dansk, `+0.31%` og `$1.2T` på engelsk.
- **Menubaren** viser det valgte indeks' ændring i dag ved siden af ikonet, begge i grønt eller rødt (eller
  blåt/orange).
- **Widget** til skrivebordet og Notifikationscenter i alle fire størrelser: favoritter, en watchliste eller et
  indeks, en fond, en sektor eller en branche, i ethvert tidsrum. Den følger temaet fra indstillingerne (som systemet, lyst eller mørkt). Et klik åbner vinduet på
  den rigtige visning.
- **Alt der slår til, slår også fra** med samme klik eller tast: menubar-ikonet lukker det vindue, det
  hentede frem (og Kun kortet), ⌘P seismografen, ⌘L kort/liste, ⌃⌘F fuld skærm, ⇧⌘F Kun kortet, ☆ en favorit,
  **✓ <liste>** i søgningen tager aktien af listen, og **Tilføjet ✓** fjerner en fond.
- **Esc** lukker en dialog, zoomer så ud, lukker seismografen og går et niveau op: aktie → kort → sektor → indeks →
  overblik. Den lukker aldrig vinduet.
- **Smalle vinduer.** I et smalt vindue forkortes lange titler med …, og tidsvælgeren med sine tal bliver en
  kompakt menu, der viser hvert tidsrum med sin ændring, så intet skubbes ud af vinduet.
- **Indstillinger** (⌘, eller **Indstillinger …** i Stockmote-menuen eller menubar-ikonets højrekliksmenu åbner det almindelige indstillingsvindue):
  tema, farver (rød/grøn eller orange/blå ved rød-grøn farveblindhed), sprog, Dock og/eller menubar, hvad
  menubaren viser, åbn vindue ved start, start ved login, feltstørrelse i lister, opdateringsfrekvens, hvilken side og browser aktier åbnes
  i.

| | |
| --- | --- |
| ![S&P 500, én dag](docs/map.png) | ![Seismografen](docs/seismograph.png) |
| S&P 500's kort, én dag | Seismografen under S&P 500: én stribe pr. sektor, markøren om eftermiddagen |
| ![NVIDIAs side](docs/stock.png) | ![Novo Nordisk, lyst](docs/stock-light.png) |
| En akties side: en måned i daglige lys | Åbnet fra C25, i lyst tema |
| ![Søg](docs/search.png) | ![iShares Core MSCI World](docs/fund.png) |
| Søgningen: en fonds beholdning tjekkes, før den tilføjes | En fond: iShares Core MSCI World, felter efter vægt |
| ![DAX i lyst tema](docs/light.png) | ![C25](docs/c25.png) |
| DAX, lyst tema | C25 — danske aktier i danske kroner |
| ![Fuld skærm](docs/fullscreen.png) | ![Indstillinger](docs/settings.png) |
| Kun kortet med notch: C25 afspillet til kl. 14.30 | Indstillingsvinduet |

## Byg

```bash
swift build
swift run Stockmote
```

## Lav .app-bundlen

```bash
./Scripts/make-app.sh --install --open
```

Bygger release, pakker `build/Stockmote.app` med widget'en indeni som `Contents/PlugIns/StockmoteWidget.appex`,
signerer begge ad hoc og kopierer med `--install` appen til `/Applications` (en kørende kopi lukkes først).

Widget'en dukker op i galleriet når appen ligger i `/Applications` og har været åbnet én gang: højreklik på
skrivebordet → **Rediger widgets** → søg efter Stockmote.

## Hvor data kommer fra

| Hvad | Kilde | Hvor tit |
| --- | --- | --- |
| Kurs og ændring, alle tidsrum, alle indekser | Yahoo Finance `v7/finance/spark` | Hvert minut mens vinduet er åbent og en børs er åben; ellers hvert 5. minut; hver halve time når alle er lukket |
| Forløb til seismografen | Samme adresse med `interval` sat (5m, 30m, 1d, 1wk eller 1mo) | Når du åbner seismografen, og igen hvis du skifter indeks, liste eller tidsrum |
| Lys på aktiens side (åbning, høj, lav, luk, volumen) og 52-ugers spændet | Yahoo Finance `v8/finance/chart`, ét symbol pr. kald | Når du åbner en akties side eller skifter tidsrum der; højst hvert 5. minut |
| Valutakurser (til at give europæiske aktier størrelse i dollar) | Yahoo Finance, `EURUSD=X` m.fl. | Sammen med kurserne |
| Amerikansk markedsværdi, navn, søgning | Nasdaq's screener (alle ~7000 amerikanske aktier, 2 MB) | Hver halve time |
| Indeksmedlemmer, sektorer, europæiske markedsværdier | `Indices.json`, bundtet med | Når du kører `update-indices.sh` |
| Søgning efter fonde; sektor for udenlandske aktier i fonde | Yahoo Finance `v1/finance/search` | Når du skriver; for hver ny aktie én gang |
| Fondes beholdning: iShares-ETF'er, amerikanske og europæiske (SOXX, IVV, SEC0, EUNL, CSPX …) | iShares' produktlister (dem produktsøgningen på ishares.com henter, for det amerikanske, britiske og tyske site) og hver fonds `latest-holdings.csv` | Når fonden tilføjes, og derefter højst ugentligt; produktlisterne ugentligt |
| Fondes beholdning: SPDR-ETF'er (SPY, XLK, SPGM …) | State Streets daglige regneark (`holdings-daily-us-en-<ticker>.xlsx`) | Når fonden tilføjes, og derefter højst ugentligt |
| Fondes beholdning: Invesco-ETF'er (QQQ, RSP …) | Invescos JSON (`dng-api.invesco.com`) | Som ovenfor |
| Fondes beholdning: Vanguards amerikanske fonde (VOO, VTI, VT …) | JSON'en bag fondssiderne på investor.vanguard.com (`irr/funds/profile/<ticker>-AdditionalFundData`) | Som ovenfor; Vanguard opdaterer månedligt, nogle uger efter månedens udgang |
| Fondes beholdning: Vanguards UCITS-ETF'er (VWRL, VWCE, VUSA …) | vanguard.co.uk: fondenes id'er fra produktsidens model (`product.model.json`), navne, ISIN og alle noteringers tickere, og beholdningen fra sitets GraphQL-tjeneste (`gpx/graphql`) | Som ovenfor; produktlisten ugentligt |
| Fondes beholdning: Xtrackers-ETF'er (XDWD, XMME, XDAX …) | etf.dws.com: fondssiderne i sitemaps (ISIN og navn) og beholdnings-JSON'en bag hver side (`api/pdp/en-gb/etf/<ISIN>/holdings`) | Som ovenfor; sitemaps ugentligt |
| Fondes beholdning: Amundi- og tidligere Lyxor-ETF'er (MWRD, CW8, PANX …) | amundietf.co.uk's produkt-API (`mapi/ProductAPI/getProductsData`): produktlisten (britisk og fransk site) og hver fonds sammensætning | Som ovenfor; produktlisten ugentligt |
| Fondssøgning og beholdning: danske investeringsforeninger (DKIDKIX, SPIC25KL …) og fonde solgt hos Nordnet (Nordnet Danmark Indeks, Nordnet Global Indeks …) | Nordnets offentlige API bag nordnet.dk (header `client-id: NEXT`, ingen konto): `api/2/main_search` til søgningen, `api/2/instruments/<id>/fund/info` til de største beholdninger med vægt, `api/2/instruments/<ids>` til deres ticker, børs og ISIN | Mens du skriver; beholdningen når fonden tilføjes, derefter højst ugentligt |
| Daglig indre værdi for fonde der ikke er børsnoterede (Nordnets egne fonde og andre Yahoo ikke kender) | Morningstars offentlige kursserie (`lt.morningstar.com/api/rest.svc/timeseries_price`, med Morningstar-id, i fondens valuta) | Med kurserne for 1U og længere perioder |
| Aktiesymboler for fonde der skriver ISIN (Vanguard, Xtrackers, Amundi) | Yahoo Finance `v1/finance/search` med ISIN | Én gang pr. ny aktie |

**Nasdaq's screener halter.** Målt en fredag eftermiddag viste den stadig torsdagens lukkekurs, så den bruges kun til
størrelse og søgning, og markedsværdien skaleres med Yahoo's aktuelle kurs. Yahoo tillader 20 symboler pr. kald, så
S&P 500 koster 26 kald, fire ad gangen.

**Europæiske markedsværdier** kommer fra Yahoo's fundamentals-tidsserie i lokal valuta, gemt sammen med kursen på det
tidspunkt. Appen skalerer dem med dagens kurs og omregner til dollar, så en watchliste med både Novo Nordisk og Apple
får rimelige størrelser.

**Indekstallet** øverst, på overblikket og under hvert tidsrum er indeksets eget (`^GSPC`, `^OMXC25`, `^GDAXI` …).
Svarer Yahoo ikke, står der –: et gennemsnit af medlemmerne ville ikke være indeksets tal.

**Sådan måles hvert tidsrum.** Yahoos `chartPreviousClose` er lukkekursen lige før tidsrummet begynder, for hvert
tidsrum Yahoo navngiver (`5d`, `1mo`, `3mo`, `6mo`, `ytd`, `1y`, `5y`). Med `max` er det den første kurs Yahoo har —
efterprøvet: 17,66 for S&P 500, kursen ved udgangen af 1927. Yahoo navngiver intet treårs-tidsrum (`3y` bliver
tilfældigvis accepteret, men står ikke blandt dem Yahoo oplister), så **3Å** læser de daglige lukkekurser over fem år
og tager den sidste før tidspunktet for tre år siden; når serien ikke rækker så langt tilbage, eller har et hul på
mere end ti dage der, er der intet tal. Tallene under tidsrummene koster ét lille kald pr. tidsrum, kun for indekset
eller fonden; medlemmerne hentes kun for det valgte tidsrum. Et symbol hvis første handel ligger efter tidsrummets
start, får intet tal for det. Yahoos udgangspunkt efterprøves også mod den serie det kom med: for nogle få symboler
er det simpelthen gårsdagens lukkekurs uanset tidsrum (Oslos OBX.OL gav −1,33 % for et år, fem år og Alt), så et
tidsrums tal bruges kun, når serien starter ved tidsrummets start, og dens første lukkekurs ligger inden for ×1,5 af
udgangspunktet (×4 for Alt, hvis første søjle er en måned eller et kvartal, ofte lige efter en notering).

**Felterne har størrelse efter markedsværdi i alle indekser.** Det rigtige Dow Jones er prisvægtet, men et kort hvor
størrelsen er aktiekursen siger ikke meget.

**Sektorer.** Amerikanske aktier bruger GICS. Europæiske bruger Yahoo's klassifikation, oversat til GICS'
sektornavne, så alle indekser deler sprog; brancherne beholder Yahoo's navne (`Drug Manufacturers – General`).

**Fonde.** Ingen åben kilde har beholdningen for alle fonde. Appen prøver i denne rækkefølge:

1. **Fondens egen beholdning** hos iShares (amerikanske og europæiske iShares-ETF'er), Vanguard (amerikanske fonde
   og UCITS-ETF'er), Xtrackers, Amundi (også de tidligere Lyxor-fonde), State Street (alle SPDR-ETF'er) eller Invesco. En iShares-fond findes i iShares' egne produktlister på ticker — enhver notering:
   `SEC0` på Xetra, `SEMI` i London — eller ellers på navnet, for listerne har én ticker pr. land (`IWDA` i Amsterdam
   findes som "iShares Core MSCI World UCITS ETF", samme fond som `SWDA` og `EUNL`). Alle tre lægger hele
   beholdningen frem, med vægt, ticker og handelsvaluta; iShares også med børs og sektor. Vanguards UCITS-fonde
   findes på enhver noterings ticker (`VWRL`, `VWRA`, `VWCE` står alle i produktlisten), Amundis på ticker eller
   navn, og Xtrackers' på navn, da DWS ikke offentliggør tickere. Vanguard og Amundi skriver ISIN og ticker (Amundi
   som Bloomberg-tickere med børs: `ASML NA` → `ASML.AS`), Xtrackers kun ISIN.
2. **Et af appens egne indekser**, hvis fondens navn siger at den følger det: `iShares Core DAX`, `Sparindex INDEX OMX
   C25 KL`, `Vanguard 500 Index Admiral`. Så er beholdningen indeksets medlemmer, og felterne får markedsværdi.
3. **En SPDR-fond på et tilsvarende indeks**: MSCI World, MSCI ACWI og FTSE All-World → SPGM (MSCI ACWI IMI);
   emerging markets → SPEM; Europa/STOXX 600 → SPEU; hele det amerikanske marked → SPTM. Statuslinjen siger det
   ("Beholdning fra SPGM (SSGA), der følger et tilsvarende indeks"). MSCI World har ikke emerging markets med, så det
   er en tilnærmelse — de største aktier er de samme.
4. Ellers: "Kunne ikke hente beholdningen for …".

Før alt det får en **dansk fond eller en fond solgt hos Nordnet** sin beholdning fra Nordnet: en fond fra Nordnets
søgning har Nordnets id med, og en fond noteret i København fundet i Yahoos søgning (`DKIDKIX.CO`) slås op i
Nordnets søgning på ticker. Nordnet offentliggør kun de **25 største beholdninger** (Morningstars data, som regel fra
seneste månedsskifte). Dækker de under 95 % af fonden, og navnet passer på trin 2 eller 3 (Nordnet Global Indeks →
SPGM), foretrækkes erstatningen, fordi den viser hele fonden; ellers viser kortet de 25, og statuslinjen siger det
("Beholdning fra Nordnet pr. 30. okt. · kun fondens 25 største beholdninger"). Udløbne indeksfutures og kontanter i
Nordnets liste springes over.

**Kurser for danske fonde og Nordnets fonde.** En børsnoteret investeringsforening har et Yahoo-symbol
(`DKIDKIX.CO`) og prissættes som enhver ETF. En fond der ikke er noteret, og som Yahoo ikke kender, har kun en daglig
indre værdi, der offentliggøres aftenen efter: appen henter den fra Morningstar for 1U og længere — 3Å fra den indre værdi
på eller lige før samme dag for tre år siden, Alt fra fondens første — og søgeresultatet viser `NAV` i stedet for en
ticker. For 1D findes der endnu ingen indre værdi for i dag, så dagens ændring er fondens **indikative værdi**, den
kutymemæssige iNAV: beholdningens ændringer vægtet efter deres vægt i fonden. Den er mærket som sådan overalt hvor
den står — `≈ +0,84%` med **indikativ** ved siden af i titlen, `≈` på overblikket, i tidsvælgeren, menubaren og
seismografen — og dens tooltip siger, at den er anslået ud fra beholdningen, indtil den indre værdi offentliggøres.
Widgetten viser – i stedet.
Yahoo kender mange af Nordnets fonde under et Morningstar-id (`0P000134KA.CO` = Nordnet Danmark Indeks A); så beholdes
Yahoo-resultatet, med Nordnets beholdning.

Obligations-, pengemarkeds- og blandede fonde (efter udbyderens aktivklasse, eller fordi beholdningen ikke har
aktier) stopper i stedet med en besked: de kan ikke tegnes som et aktiekort. Swap-baserede ETF'er (Amundis `CW8`,
`500`, `ANX` …) ejer en erstatningskurv af andre aktier, ikke indekset, så appen springer kurven over og går videre til
trin 2 og 3; uden erstatning siger den at fonden er swap-baseret.

| Udbyder | Understøttet | Hvorfor / hvordan |
|---|---|---|
| iShares, Vanguard, Xtrackers, Amundi/Lyxor, SPDR (USA), Invesco (USA) | Ja | Fuld beholdning, se ovenfor |
| SPDR Europe (UCITS), WisdomTree, VanEck, HSBC, J.P. Morgan, Franklin Templeton, Global X, Schwab, First Trust, Fidelity | Ikke endnu | Ikke undersøgt endnu; fonde på et kendt indeks får en erstatning |
| Danske investeringsforeninger (Sparindex, Danske Invest, Nykredit Invest, Jyske Invest, BankInvest …) og fonde solgt hos Nordnet | Ja, top 25 | De 25 største beholdninger fra Nordnet; en erstatning når fonden følger et bredt indeks appen kender (se ovenfor); indre værdi fra Morningstar for unoterede fonde |

Fonde med en drejning i navnet — sektor, faktor, ESG, gearing, obligationer — følger ikke det brede indeks og får
ingen erstatning. Zacks og stockanalysis.com blev prøvet og fravalgt: de afviser alt andet end en browser.

Udenlandske aktier i en fond får Yahoo-symbol ud fra ticker og børs, når udbyderen skriver børsen, som iShares gør
(`ASML` på Euronext Amsterdam → `ASML.AS`, `000660` på Korea Exchange → `000660.KS`), og ellers ud fra ticker og
valuta (`7203` + JPY → `7203.T`, `700` + HKD → `0700.HK`, `SHEL` + GBP → `SHEL.L`). Euro-aktier uden børs kan ikke
gættes (Paris, Frankfurt, Milano …) og slås op på navnet, og det gør aktier hvis gættede symbol Yahoo ikke kender,
også. Når udbyderen skriver ISIN, spørges Yahoo's søgning først om ISIN, som finder præcis selskabet og dets
primære notering. Uden børs og valuta giver ISIN'ens land børsen (`JP…` → Tokyo, `KR…` → Korea, `CN…` → Shanghai,
Shenzhen eller Hongkong efter ticker); for selskaber registreret i Irland, på Caymanøerne og lignende gør udbyderens
risikoland (Linde → New York, Tencent → Hongkong). Sektor og branche kommer fra `Indices.json` hvis aktien
står der, ellers fra Yahoo's søgning, oversat til GICS' sektornavne, og som sidste udvej fra fondens egen fil.
Opslagene gemmes i `~/Library/Application Support/Stockmote/Funds/Names.json`, udbydernes produktlister i
`iShares.json`, `Vanguard.json`, `Xtrackers.json` og `Amundi.json`, og beholdningerne i samme mappe, så en fond kun koster Yahoo-kald første gang. Yahoo svarer 429 hvis der spørges for meget; så ventes der, og
de opslag der fejlede, prøves igen ét ad gangen.

**Åbningstider** følger hver børs og vises i din lokale tid i statuslinjen: `Lukket · åbner man. 09.00`. Helligdage
kendes ikke.

## Indeksmedlemmer

```bash
./Scripts/update-indices.sh          # skriv Indices.json igen
./Scripts/update-indices.sh --check  # vis hvad der er ændret, skriv intet
```

Scriptet ([update-indices.py](Scripts/update-indices.py)) tager omkring et minut:

- **S&P 500** fra listen `datasets/s-and-p-500-companies` med GICS-sektor og -branche.
- **Nasdaq 100** fra Nasdaq's egen liste. Medlemmer uden for S&P 500 (ASML, Arm, Shopify …) har ingen åben
  GICS-kilde og står i `OVERRIDES`.
- **Dow Jones** fra Wikipedias skabelon over medlemmerne.
- **De ti europæiske indekser** fra tickertabellen i hver Wikipedia-artikel. Sektor, navn og markedsværdi kommer fra
  to Yahoo-adresser der ikke kræver cookie: søgningen og fundamentals-tidsserien. Tickers hvor Wikipedia og Yahoo er
  uenige, står i `YAHOO_RENAMES` (Nordea hedder `NDA-DK.CO`).

Yahoo svarer 429 hvis man kører scriptet flere gange i træk. Det venter og prøver igen; fejler det stadig, stopper det
før det skriver, så den gamle fil er urørt.

Du kan overstyre den bundtede fil uden at bygge: læg din egen `Indices.json` i
`~/Library/Application Support/Stockmote/` og klik **Genindlæs lister** i indstillingerne.

## Widget'en

Tre ting som Xcode normalt gør for en widget, måtte gøres i hånden, fordi appen bygges med SwiftPM:

- **Startpunkt.** En udvidelse skal starte i Foundations `_NSExtensionMain`, ikke i `main`. Uden det dør processen i
  ExtensionFoundation før WidgetKit når at starte, og widget'en dukker aldrig op i galleriet. Widget-target'et linkes
  med `-e _NSExtensionMain` (se [Package.swift](Package.swift)).
- **AppIntents-metadata.** Widget'ens indstillinger (indhold, indeks, sektor, tidsrum) skal beskrives i
  `Metadata.appintents`. `make-app.sh` laver den med Xcodes `appintentsmetadataprocessor` ud fra de konstantværdier
  compileren bliver bedt om at skrive.
- **Deling uden app group.** En widget kører i en sandbox og kan ikke læse appens indstillinger. En app group kræver et
  Apple-udviklerhold, og Stockmote er ad hoc-signeret. I stedet skriver appen
  `~/Library/Application Support/Stockmote/Widget.json` (favoritter, watchlister, indekser, fonde og deres vægte,
  sektorer, markedsværdier, sprog), og widget'en har en read-only-undtagelse til netop den mappe. Kurserne står ikke i filen: widget'en henter
  dem selv fra Yahoo, så den er frisk selv når appen ikke har været åbnet.

Den opdaterer cirka hvert kvarter mens en børs er åben og ellers hver time; WidgetKit har det sidste ord.

## Filer

| Fil | Indhold |
| --- | --- |
| [Sources/Stockmote/StockmoteApp.swift](Sources/Stockmote/StockmoteApp.swift) | `@main`, `AppDelegate` (start, Dock / menubar, genåbning fra Dock), `stockmote://`-links, snapshot-tilstand |
| [Sources/Stockmote/MainWindow.swift](Sources/Stockmote/MainWindow.swift) | Hovedvinduet og dets titellinje, indstillingsvinduet, Esc i vinduet |
| [Sources/Stockmote/MainMenu.swift](Sources/Stockmote/MainMenu.swift) | Hovedmenuen, på appens sprog |
| [Sources/Stockmote/MenuBarItem.swift](Sources/Stockmote/MenuBarItem.swift) | Menubar-ikon og farvet tal; et klik henter vinduet frem eller lukker det, højreklik giver en lille menu |
| [Sources/Stockmote/PanelView.swift](Sources/Stockmote/PanelView.swift) | Værktøjslinje med brødkrummer, statuslinje, kortet, favoritter, watchlister, liste |
| [Sources/Stockmote/Overview.swift](Sources/Stockmote/Overview.swift) | Overblikket: handelstider, kortene og deres små kort |
| [Sources/Stockmote/StockPage.swift](Sources/Stockmote/StockPage.swift) | Aktiens side: lys fra Yahoos chart-adresse, nøgletal, ligemænd, Også i |
| [Sources/Stockmote/Search.swift](Sources/Stockmote/Search.swift) | Søgningen: indekser, aktier og fonde, tilføj til lister og tilføj fonde |
| [Sources/Stockmote/Dialogs.swift](Sources/Stockmote/Dialogs.swift) | Dialog-værten, ny og omdøb watchliste, og fondsvælgeren bag søgningen |
| [Sources/Stockmote/HeatmapView.swift](Sources/Stockmote/HeatmapView.swift) | Hover, klik, zoom, tooltip, højrekliksmenu |
| [Sources/Stockmote/Fullscreen.swift](Sources/Stockmote/Fullscreen.swift) | Kun kortet: det rammeløse fuldskærmskort og notch-båndet |
| [Sources/Stockmote/Replay.swift](Sources/Stockmote/Replay.swift) | Seismografen: forløb, tidslinje, afspilning, rækkerne og skuffen under kortet |
| [Sources/Stockmote/SettingsView.swift](Sources/Stockmote/SettingsView.swift) | Indstillinger og Om |
| [Sources/Stockmote/MarketData.swift](Sources/Stockmote/MarketData.swift) | Kurser, valutakurser, opdateringsløkke, Nasdaq's screener |
| [Sources/Stockmote/Universe.swift](Sources/Stockmote/Universe.swift) | Indlæsning af `Indices.json` |
| [Sources/Stockmote/Funds.swift](Sources/Stockmote/Funds.swift) | Fonde: søgning, beholdninger fra iShares, State Street og Invesco, erstatningsindekser, opslag af udenlandske aktier, cache, .xlsx- og CSV-læsere |
| [Sources/Stockmote/FundIssuers.swift](Sources/Stockmote/FundIssuers.swift) | Fondes beholdning fra Vanguard, Xtrackers og Amundi, produktlister, ISIN-rækker |
| [Sources/Stockmote/Nordnet.swift](Sources/Stockmote/Nordnet.swift) | Nordnets offentlige API: søgning efter danske fonde og Nordnets fonde, deres største beholdninger |
| [Sources/Stockmote/Lists.swift](Sources/Stockmote/Lists.swift) | Favoritter og watchlister |
| [Sources/Stockmote/Preferences.swift](Sources/Stockmote/Preferences.swift) | Indstillinger |
| [Sources/Stockmote/AppState.swift](Sources/Stockmote/AppState.swift) | Overblik, kort eller aktie; kilden, niveau, tilbage, zoom, den åbne dialog og beskeden nederst |
| [Sources/Stockmote/Browsers.swift](Sources/Stockmote/Browsers.swift) | Hvilken browser links åbnes i (fra DRmote) |
| [Sources/Stockmote/WidgetSync.swift](Sources/Stockmote/WidgetSync.swift) | Skriver `Widget.json` og genindlæser widget'en |
| [Sources/StockmoteShared/Treemap.swift](Sources/StockmoteShared/Treemap.swift) | Squarified treemap-layout |
| [Sources/StockmoteShared/HeatmapCanvas.swift](Sources/StockmoteShared/HeatmapCanvas.swift) | Tegning af felterne, fælles for app, fuld skærm og widget |
| [Sources/StockmoteShared/Style.swift](Sources/StockmoteShared/Style.swift) | Tidsrum, temaer, farveskala, talformater, vinduets farver |
| [Sources/StockmoteShared/Lang.swift](Sources/StockmoteShared/Lang.swift) | Dansk og engelsk |
| [Sources/StockmoteShared/Market.swift](Sources/StockmoteShared/Market.swift) | Symboler, åbningstider, valutaer |
| [Sources/StockmoteShared/Yahoo.swift](Sources/StockmoteShared/Yahoo.swift) | Yahoo-klient; daglig indre værdi fra Morningstar for unoterede fonde |
| [Sources/StockmoteShared/WidgetShare.swift](Sources/StockmoteShared/WidgetShare.swift) | Filen der deles med widget'en |
| [Sources/StockmoteWidget/StockmoteWidget.swift](Sources/StockmoteWidget/StockmoteWidget.swift) | Widget'en og dens indstillinger |
| [Scripts/make-app.sh](Scripts/make-app.sh) | Pakker og signerer app og widget, laver AppIntents-metadata |
| [Scripts/update-indices.sh](Scripts/update-indices.sh), [update-indices.py](Scripts/update-indices.py) | Bygger `Indices.json` |
| [Scripts/make-icon.swift](Scripts/make-icon.swift) | Tegner app-ikonet |
| [Scripts/make-screenshots.sh](Scripts/make-screenshots.sh) | Renderer billederne i `docs/` |

## Skærmbilleder

`./Scripts/make-screenshots.sh` renderer dem med rigtige data. Appen har en snapshot-tilstand til det, som holder
sine indstillinger adskilt fra den rigtige apps, og sin fond-cache i `~/Library/Application Support/Stockmote/Snapshot/Funds/`:

```bash
.build/release/Stockmote --snapshot ud.png --index c25 --period 1M --theme light --lang en
```

Den tegner hovedvinduets indhold, 940 × 600 hvis intet andet er sagt.

Valg: `--screen overview|map`, `--tab map|favorites|watchlists`, `--watchlist "AI"`, `--stock NVDA` (aktiens side), `--index <id>`, `--period 1D|1U|1M|3M|6M|ÅTD|1Å|3Å|5Å|Alt`,
`--sector "…"`, `--industry "…"`, `--size small|medium|large|huge` (vinduets indhold i 720 × 480, 940 × 600,
1140 × 720 eller 1400 × 860), `--list`, `--zoom 2.5`,
`--theme light|dark`, `--lang da|en`, `--fullscreen`, `--notch 32` (fuld skærm som på en skærm med
notch), `--seismograph 0.4` (seismografen sat på pause 40 % inde i tidsrummet), `--fund SPY` (tilføj og vis en fond),
`--search "MSCI World"` (søgningen, åben med resultater), `--fund-pick SEC0.DE` (med den fond valgt og
beholdningen hentet — eller advarslen, hvis den ikke kunne findes), `--fund-add` (og tilføjet), `--dialog
new-list|rename-list` (dialogerne til watchlister), `--window 1200x780` (vinduets indhold i en vilkårlig størrelse),
`--settings` (indstillingsvinduet). Et snapshot tegner kun appens egne views: vinduets titellinje og trafiklys tegnes
af macOS og er ikke med på billedet — deres plads øverst til venstre står tom, som i vinduet.

| | |
| --- | --- |
| ![Information Technology](docs/sector.png) | ![Nasdaq 100, én måned, lyst](docs/nasdaq-1m.png) |
| En sektor, efter klik på dens strimmel | Nasdaq 100 over en måned, lyst tema |
| ![Favoritter](docs/favorites.png) | ![FTSE 100 på engelsk](docs/english.png) |
| Favoritter | FTSE 100, engelsk |

## Licens

[MIT](LICENSE). Du må bruge, ændre og videregive koden, også kommercielt, så længe copyright-linjen og licensteksten
følger med. Stockmote har ingen tredjepartsafhængigheder. Kurser og indekslister tilhører deres kilder (Yahoo
Finance, Nasdaq, Wikipedia og indeksudbyderne) og er ikke omfattet af licensen.
