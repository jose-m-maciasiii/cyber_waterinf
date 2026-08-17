# Small Water Systems Explorer

A standalone Streamlit dashboard for exploring active community water systems serving 3,300 people or fewer by congressional district or county. See the [project README](../README.md) for the full methodology, sources, limitations, and reproducibility notes.

## Build the data

Run `water_inf_analysis.R` through the `analysis` section. It creates the lightweight files in `dashboard/data/`; the deployed app does not need R or the source SDWA CSV files.

## Run locally

``` bash
cd dashboard
python -m pip install -r requirements.txt
streamlit run app.py
```

The map uses CARTO's public Positron basemap and does not require an API key.

## Map delivery options

The app defaults to district-filtered GeoJSON rendered with PyDeck. The complete map payload is currently small enough for this to remain a practical, zero-infrastructure deployment.

The R export also creates `data/water_infrastructure.pmtiles`. For a MapLibre deployment, host that file on a service that supports HTTP byte-range requests (such as S3, Cloudflare R2, or a suitable static host), then load its public URL with `anymap-ts` or the MapLibre PMTiles protocol. Do not rely on Streamlit's built-in static-file server for production PMTiles delivery; `.pmtiles` is not one of its officially supported static media types.

The archive is regenerated with the analysis pipeline and contains six named layers: `congressional_districts`, `counties`, `cws_service_areas`, `county_cws_service_areas`, `all_block_groups`, and `vulnerable_block_groups`. Keep `data/water_infrastructure.pmtiles` with the deployment artifacts even while the Streamlit app uses state-split GeoJSON as its default, zero-infrastructure map source.

## Principal outputs

-   Congressional-district metrics and boundaries
-   County metrics and boundaries, including overlapping congressional representation
-   CWS service areas clipped to congressional districts
-   CWS service areas clipped to counties
-   Complete Census block-group coverage, split into lightweight state files
-   CWS-served block groups in the district community tables
-   The most vulnerable 10% of served block groups
-   District-to-water-system lookup with compliance and component summaries

EPA service areas include both authoritative and modeled boundaries. Geocoded administrative addresses are retained as an optional layer and should not be interpreted as physical infrastructure locations.

## **About the Data and Methodology** 

This research in brief combines federal drinking-water, demographic, geographic, and election data to examine the communities served by small community water systems. The objective is to make otherwise fragmented public information accessible and to identify places where socioeconomic vulnerability, rurality, and reliance on small water systems intersect.

## **Public water-system data**

Water-system records come from the U.S. Environmental Protection Agency’s Safe Drinking Water Information System, or SDWIS. SDWIS contains inventory, monitoring, inspection, violation, and enforcement information reported under the Safe Drinking Water Act. EPA publishes these records through its Enforcement and Compliance History Online platform and refreshes the downloadable files quarterly. Each system is identified by a unique Public Water System Identification Number, or PWSID. [EPA’s data dictionary](https://echo.epa.gov/tools/data-downloads/sdwa-download-summary) provides definitions for the fields used in this analysis.

The national descriptive counts below include systems coded as active in the 2026 second-quarter SDWIS snapshot used for this research.

**Table 1A. Active public water systems by system type**

+-------+-----------------------------------------------------+------+----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------+------+-----------------------+-----+
|       |                                                     |      |                                                                                                                                                                                                                                                                |      |                       |     |
+-------+-----------------------------------------------------+------+----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------+------+-----------------------+-----+
|       | **System type**                                     |      | **Description**                                                                                                                                                                                                                                                |      | **Active systems**    |     |
+-------+-----------------------------------------------------+------+----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------+------+-----------------------+-----+
|       |                                                     |      |                                                                                                                                                                                                                                                                |      |                       |     |
+-------+-----------------------------------------------------+------+----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------+------+-----------------------+-----+
|       | Community water system (CWS)                        |      | A public water system that has at least 15 service connections used by year-round residents or regularly serves at least 25 year-round residents. Examples include systems serving homes, apartments, and condominiums occupied as primary residences.         |      | 49,378                |     |
+-------+-----------------------------------------------------+------+----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------+------+-----------------------+-----+
|       |                                                     |      |                                                                                                                                                                                                                                                                |      |                       |     |
+-------+-----------------------------------------------------+------+----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------+------+-----------------------+-----+
|       | Transient non-community water system (TNCWS)        |      | A non-community system that does not regularly serve at least 25 of the same people for more than six months per year. Examples include campgrounds and highway rest stops with their own water sources.                                                       |      | 76,476                |     |
+-------+-----------------------------------------------------+------+----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------+------+-----------------------+-----+
|       |                                                     |      |                                                                                                                                                                                                                                                                |      |                       |     |
+-------+-----------------------------------------------------+------+----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------+------+-----------------------+-----+
|       | Non-transient non-community water system (NTNCWS)   |      | A non-community system that regularly serves at least 25 of the same people for more than six months per year. Examples include schools, factories, and office buildings with their own water sources.                                                         |      | 17,037                |     |
+-------+-----------------------------------------------------+------+----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------+------+-----------------------+-----+
|       |                                                     |      |                                                                                                                                                                                                                                                                |      |                       |     |
+-------+-----------------------------------------------------+------+----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------+------+-----------------------+-----+
|       | **Total active public water systems**               |      | All active CWS, TNCWS, and NTNCWS records in the quarterly extract.                                                                                                                                                                                            |      | **142,891**           |     |
+-------+-----------------------------------------------------+------+----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------+------+-----------------------+-----+
|       |                                                     |      |                                                                                                                                                                                                                                                                |      |                       |     |
+-------+-----------------------------------------------------+------+----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------+------+-----------------------+-----+

The remainder of the analysis focuses on active CWSs serving **3,300 or fewer people**, identified using EPA’s POP_CAT_3_CODE. Nationally, 39,759 active CWSs fall within this size category in the data snapshot. The detailed spatial analysis currently covers Georgia, Michigan, Minnesota, New Jersey, and South Dakota—the five states included in the study dataset.

The analysis also connects each target CWS to its associated EPA records, including:

-   Active facilities and infrastructure components

-   Facility and source types

-   Site inspections and sanitary surveys

-   Reported drinking-water violations

-   Unresolved and health-based violations

-   Corrective actions

-   Enforcement action

-    Estimated population served

-   Ownership and primary water-source classifications

These measures represent records contained in the quarterly SDWIS extract. A count of zero means that no qualifying record was found in that extract; it does not necessarily demonstrate that an event never occurred.

## **Water service areas**

The geographic analysis uses EPA’s Version 3.0 community-water-system service-area dataset. These polygons represent the areas EPA identifies as being served by individual CWSs. They provide a better approximation of the communities receiving water than the administrative mailing address associated with a water system.

Service-area polygons are linked to SDWIS records through the PWSID. EPA’s accompanying Census crosswalks are then used to associate each service area with census tracts and block groups. Building-based weights supplied with the crosswalk are used to estimate how much of a census geography’s population and households falls within a service area.

Where service areas overlap, the same block group can be associated with more than one CWS. The analysis retains these relationships because households may be located within overlapping or interconnected service areas. However, population and household estimates are capped at the corresponding Census total for each block group to reduce overcounting.

## **Census and rurality data**

Community characteristics come from the Census Bureau’s 2024 American Community Survey five-year estimates. Five-year estimates are used because they are available for small geographic areas, including census block groups. They are estimates rather than exact population counts and are accompanied by margins of error. [The Census Bureau explains the use of ACS one-year and five-year estimates here](https://www.census.gov/programs-surveys/acs/guidance/estimates.html).

The analysis includes:

-   Total population

-   Total households

-   Median household income

-   Population below the poverty line

-   Poverty rate

-   Civilian labor force

-   Employment and unemployment

-   Unemployment rate

-   Household broadband subscriptions

-   Broadband-subscription rate

Rural and urban population counts come from the 2020 Decennial Census Demographic and Housing Characteristics File, Table P2. The Census Bureau classifies territory at the census-block level as urban or rural; this analysis aggregates those population counts to block groups and tracts. A block group is classified as:

-   **Fully rural:** 100% of its population is rural

-   **Majority rural:** at least 50%, but less than 100%, is rural

-   **Partly rural:** more than 0%, but less than 50%, is rural

-   **Fully urban:** no population is classified as rural

This is a Census geographic classification and should not be interpreted as a direct measure of agricultural activity, remoteness, local governmental capacity, or cultural identity. [Census urban and rural methodology](https://www.census.gov/programs-surveys/geography/guidance/geo-areas/urban-rural.html).

Estimated rural population served is calculated by applying each block group’s 2020 rural population share to the population estimated to fall within CWS service areas. This assumes rural and urban residents are distributed proportionally within the covered portion of a block group. The resulting value should therefore be understood as a modeled estimate.

## **Measuring community vulnerability**

The principal unit of the vulnerability analysis is the census block group. Block groups are used because they provide insight on local socioeconomic differences that may be obscured at the tract, county, or congressional-district level.

The analysis ranks block groups connected to at least one target CWS using two equally weighted indicators:

1.  Higher poverty rate

2.  Lower median household income

Each block group receives a percentile rank for both measures. The two percentile ranks are averaged to produce a composite vulnerability score. The most vulnerable group consists of the highest-scoring 10% of block groups.

This index is intended as a transparent screening tool, not a definitive measurement of vulnerability. It does not presently include other potentially important conditions such as age, disability, race and ethnicity, language access, health status, water affordability, utility staffing, cybersecurity maturity, or the presence of internet-connected operational technology.

## **Congressional representation**

Census block groups are spatially joined to 2024 congressional-district boundaries. When a block group intersects more than one district, all meaningful district relationships are retained, and the district containing the largest share of the block group’s land area is identified as its primary district.

District assignments are joined to the winning candidate in the 2024 U.S. House election using state and congressional-district number. The winning candidate is defined as the candidate receiving the greatest number of votes in that district. This allows the public to identify the representative and political party associated with communities served by the water systems in the analysis.

Congressional assignment provides a pathway for civic engagement, but it does not imply that an individual representative regulates, owns, or operates a water system. Water-system oversight and cybersecurity assistance can involve local utilities, state primacy agencies, EPA, the Cybersecurity and Infrastructure Security Agency, and other federal or state programs.

## **Important limitations**

Several limitations should guide interpretation:

-   The national system counts describe a quarterly SDWIS snapshot and may change as states update their records.

-   SDWIS administrative addresses do not necessarily represent the physical location of infrastructure or customers.

-   Service-area polygons represent estimated areas served, not household-level customer records.

-   A block group’s association with a service area does not establish that every household in that block group receives water from that system.

-   Overlapping service areas can associate one community with multiple CWSs.

-   ACS socioeconomic values are survey estimates with margins of error.

-   Rural population data come from the 2020 Census, while socioeconomic measures come from the 2024 ACS five-year estimates.

-   Reported violations, inspections, and corrective actions reflect the available SDWIS records and reporting practices.

-   The dataset does not identify whether a system operates internet-connected equipment, industrial control systems, or vulnerable SCADA technology.

-   Inclusion in the analysis indicates potential exposure or policy relevance—not evidence that a water system has been compromised or specifically targeted.

For the complete SDWIS data dictionary, see the [EPA SDWA Data Download Summary](https://echo.epa.gov/tools/data-downloads/sdwa-download-summary).

AI was used to sum up and package the contents in this readme