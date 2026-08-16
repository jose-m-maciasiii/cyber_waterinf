# Small Water Systems Explorer

An open, exploratory analysis of active community water systems (CWS) serving
3,300 people or fewer and the communities within their EPA service areas. The
project combines federal drinking-water records, EPA service-area geography,
Census socioeconomic and rurality measures, and 2024 U.S. House election
results. Its public-facing Streamlit dashboard supports exploration by either
congressional district or county.

**Live dashboard:** [Small Water Systems Explorer](https://jose-m-maciasiii-small-water-systems-explorer.share.connect.posit.cloud/)

The project is maintained by Jose M. Macias III of Periphery Analytics. It is
an independent public-information project and is not an official government
product.

## Research purpose

Small community water systems can face limited staffing, funding, and technical
capacity. This project helps identify where reliance on small CWS intersects
with socioeconomic disadvantage and rurality, and connects those communities
to their congressional representation.

The analysis is a screening and public-engagement tool. It does **not** assess a
water system's cybersecurity posture, establish that a system has been
compromised, or determine whether its drinking water is safe.

## Study scope

- **Water-system universe:** active CWS serving 3,300 people or fewer
- **SDWIS snapshot:** 2026 second quarter
- **Detailed spatial coverage:** Georgia, Michigan, Minnesota, New Jersey, and
  South Dakota
- **Community geography:** 2024 ACS census block groups and tracts
- **Summary geographies:** counties and congressional districts
- **Rurality source:** 2020 Decennial Census DHC Table P2
- **Representation:** winners of the 2024 U.S. House elections

The five-state scope reflects the data assembled for this study and should not
be interpreted as a complete national assessment.

## Active public water systems

The national descriptive counts below include systems coded as active in the
2026 Q2 SDWIS snapshot.

| System type | Description | Active systems |
|---|---|---:|
| Community water system (CWS) | Serves at least 15 service connections used by year-round residents or regularly serves at least 25 year-round residents. | 49,378 |
| Transient non-community water system (TNCWS) | Does not regularly serve at least 25 of the same people for more than six months per year; examples include campgrounds and highway rest stops. | 76,476 |
| Non-transient non-community water system (NTNCWS) | Regularly serves at least 25 of the same people for more than six months per year; examples include schools, factories, and office buildings. | 17,037 |
| **Total active public water systems** | All active CWS, TNCWS, and NTNCWS records in the quarterly extract. | **142,891** |

Nationally, 39,759 active CWS fall within the 3,300-or-fewer size category in
this snapshot. The detailed spatial analysis filters that universe to the five
study states.

## Data sources

- [EPA Safe Drinking Water Information System (SDWIS)](https://echo.epa.gov/tools/data-downloads/sdwa-download-summary): system inventory, facilities, components, inspections, violations, corrective actions, and enforcement records.
- [EPA Community Water System Service Areas v3.0](https://www.epa.gov/ground-water-and-drinking-water/public-water-system-service-areas): CWS service-area polygons and Census crosswalks.
- [2020-2024 American Community Survey five-year estimates](https://api.census.gov/data/2024/acs/acs5.html): population, households, income, poverty, employment, and broadband measures.
- [2020 Census Demographic and Housing Characteristics File](https://www.census.gov/data/tables/2023/dec/2020-census-dhc.html): urban and rural population counts from Table P2.
- [MIT Election Data and Science Lab](https://electionlab.mit.edu/data): 2024 U.S. House election returns.

EPA identifies systems with a unique Public Water System Identification Number
(`PWSID`), which links the SDWIS inventory to facilities, compliance records,
and service-area geography.

## Methodology

### 1. Select small community water systems

The pipeline reads the quarterly SDWIS files and retains systems that are:

- coded as active;
- classified as a community water system (`CWS`);
- assigned to EPA's population category for systems serving 3,300 people or
  fewer; and
- located in one of the five study states.

Each selected system is enhanced with active facility/component types, site
inspections, reported violations, unresolved and health-based violations,
corrective actions, enforcement actions, ownership, primary water source, and
reported population served. Counts describe records found in the quarterly
extract. A zero does not prove that an event never occurred.

### 2. Connect systems to service areas

EPA CWS Service Areas v3.0 provide a better approximation of communities served
than the administrative mailing address associated with a PWS. Service
polygons are joined to SDWIS records by `PWSID` and intersected with counties
and congressional districts.

EPA's accompanying tract and block-group crosswalks supply building-based
weights used to estimate population and households within service areas. When
service areas overlap, one Census geography may be linked to multiple systems.
Gross estimates retain those relationships; capped estimates cannot exceed the
corresponding Census population or household total for the geography.

### 3. Add Census characteristics and rurality

The pipeline retrieves 2024 ACS five-year estimates for:

- total population and households;
- median household income;
- poverty population and rate;
- labor force, employment, unemployment, and unemployment rate; and
- household broadband subscriptions and subscription rate.

Block-group poverty uses collapsed ACS table C17002 because detailed table
B17001 is not published at the block-group level.

Urban and rural population counts come from 2020 DHC Table P2. A geography is
classified as fully rural, majority rural, partly rural, or fully urban based
on its rural population share. Estimated rural population served applies each
block group's rural share to its estimated CWS service population; this assumes
rural and urban residents are proportionally distributed within the covered
part of the block group.

### 4. Measure community vulnerability

The vulnerability analysis includes block groups connected to at least one
target CWS and having usable poverty and income estimates. Each receives:

1. a percentile rank for higher poverty rate;
2. a percentile rank for lower median household income; and
3. an equally weighted composite of those two ranks.

The "most disadvantaged" layer is the highest-scoring decile (top 10%) within
the CWS-served block groups in the five-state study—not a national percentile
or an official government designation. Ties at the cutoff are retained.

The index is deliberately transparent, but incomplete. It does not currently
include age, disability, race and ethnicity, language access, health status,
water affordability, utility staffing, cybersecurity maturity, or the presence
of internet-connected operational technology.

### 5. Assign political representation

Block groups are spatially joined to congressional-district boundaries. When a
block group crosses a boundary, meaningful overlaps are retained and the
district containing the largest land-area share is identified as primary.

Election returns are aggregated by candidate before the candidate receiving
the most votes in each state and district is selected. This accounts for
candidates appearing on multiple party lines.

For county analysis, the pipeline retains every congressional district with a
positive-area overlap with the county. Counties spanning multiple districts
therefore list all associated representatives and parties. This provides a
civic-engagement reference; it does not imply that a representative regulates,
owns, or operates a water system.

### 6. Geocode administrative addresses

SDWIS contact addresses are forward-geocoded and cached as RDS files so routine
pipeline runs do not need to repeat completed queries. These coordinates may
represent a billing office, operator, or mailing address rather than a well,
treatment plant, or customer location. The dashboard labels them as
administrative points and does not use them to estimate service populations.

## Repository structure

```text
.
├── water_inf_analysis.R       # End-to-end ingestion, analysis, and export pipeline
├── water_inf_analysis.docx    # Research commentary and methodology draft
├── dashboard/
│   ├── app.py                 # Streamlit application
│   ├── requirements.txt       # Python dependencies
│   ├── runtime.txt            # Posit Connect Python runtime
│   └── data/                  # Lightweight, deployment-ready outputs
└── data/
    ├── analysis/              # Reusable analysis outputs
    ├── geocoded/              # Cached address geocodes (not committed)
    └── SDWA_latest_downloads/ # Raw EPA downloads (not committed)
```

Large, reproducible EPA source files and geocode caches are excluded from Git.
The precomputed files needed by the deployed dashboard are committed under
`dashboard/data/`.

## Reproducing the analysis

### Requirements

- R with `tidyverse`, `tidycensus`, `tidygeocoder`, `janitor`, `sf`, `DBI`, and
  `duckdb`
- A Census API key configured for `tidycensus`
- The EPA SDWIS quarterly files and EPA Service Areas v3.0 package placed in the
  paths referenced by `water_inf_analysis.R`
- Optional: `freestiler` to regenerate the PMTiles archive

Run the pipeline from the repository root:

```bash
Rscript water_inf_analysis.R
```

The script reads cached geocodes when available, performs the district, county,
tract, and block-group analysis, writes reusable analysis files, generates the
dashboard CSV/GeoJSON inputs, and rebuilds the PMTiles archive.

The pipeline currently expects raw files under
`data/SDWA_latest_downloads/`. Because these files can be several gigabytes,
they should remain outside Git or be managed with an appropriate data-storage
service rather than normal Git objects.

## Running the dashboard locally

```bash
cd dashboard
python -m pip install -r requirements.txt
streamlit run app.py
```

The application uses CARTO's public Positron basemap and does not require a map
API key. The deployed application reads precomputed data and does not require R
or the raw EPA files.

## Dashboard and analysis outputs

Important deployment outputs include:

- `district_metrics.csv` and `congressional_districts.geojson`
- `district_water_systems.csv`
- `county_metrics.csv` and `counties.geojson`
- `county_water_systems.csv`
- district- and county-clipped CWS service areas
- state-split complete block-group GeoJSON files
- the highest-disadvantage-decile block-group layer
- `water_infrastructure.pmtiles`

The PMTiles archive currently contains six layers:

1. `congressional_districts`
2. `counties`
3. `cws_service_areas`
4. `county_cws_service_areas`
5. `all_block_groups`
6. `vulnerable_block_groups`

PMTiles should be hosted on a service supporting HTTP byte-range requests, such
as object storage or a suitable static host. The current Streamlit application
uses state-split GeoJSON as its zero-infrastructure default.

## Important limitations

- SDWIS is a quarterly administrative snapshot and changes as agencies update
  their records.
- EPA service areas include authoritative and modeled polygons; they are not
  household-level customer records.
- A block group's intersection with a service area does not establish that
  every household receives water from that system.
- Overlapping service areas can associate one community with multiple CWS.
- ACS values are survey estimates with margins of error, especially important
  for small geographies.
- Rurality uses 2020 Census data while socioeconomic measures use 2020-2024 ACS
  estimates.
- Land-area overlap is used for some cross-boundary allocations and does not
  capture the actual within-geography distribution of residents.
- Administrative address points may contain geocoding errors and should not be
  interpreted as physical infrastructure locations.
- Violations, inspections, and corrective actions reflect available SDWIS
  records and reporting practices, not a complete measure of system quality or
  risk.
- The data do not identify whether a CWS operates internet-connected equipment,
  industrial control systems, or vulnerable SCADA technology.
- Inclusion signals potential policy relevance—not evidence of compromise,
  targeting, regulatory noncompliance, or unsafe drinking water.

## Responsible use

Avoid publishing precise infrastructure interpretations based solely on an
administrative address or modeled service polygon. Users should consult the
relevant water utility, state primacy agency, EPA, or emergency-management
authority for operational, regulatory, or safety questions.

## Suggested repository additions

The repository does not yet include several files commonly expected in a public
data project. Recommended next additions are:

- a `LICENSE` covering source code and a separate note clarifying that upstream
  government and election datasets retain their own terms;
- a `CITATION.cff` with author, project title, repository URL, and release date;
- a versioned release or changelog recording the SDWIS quarter, ACS vintage,
  election version, and service-area version used for each dashboard update;
- a machine-readable data dictionary for every published CSV;
- automated checks for expected columns, unique identifiers, missing geometry,
  and county/district coverage;
- a reproducible R dependency lockfile, such as `renv.lock`;
- a contribution guide and issue templates; and
- archived summary outputs or checksums so published commentary can be tied to
  an exact data release.

## Feedback

Questions, corrections, and reproducibility issues can be submitted through the
[GitHub issue tracker](https://github.com/jose-m-maciasiii/cyber_waterinf/issues).

