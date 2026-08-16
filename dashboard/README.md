# Small Water Systems Explorer

A standalone Streamlit dashboard for exploring active community water systems
serving 3,300 people or fewer by congressional district.

## Build the data

Run `water_inf_analysis.R` through the `analysis` section. It creates the
lightweight files in `dashboard/data/`; the deployed app does not need R or the
source SDWA CSV files.

## Run locally

```bash
cd dashboard
python -m pip install -r requirements.txt
streamlit run app.py
```

The map uses CARTO's public Positron basemap and does not require an API key.

## Map delivery options

The app defaults to district-filtered GeoJSON rendered with PyDeck. The complete
map payload is currently small enough for this to remain a practical,
zero-infrastructure deployment.

The R export also creates `data/water_infrastructure.pmtiles`. For a MapLibre
deployment, host that file on a service that supports HTTP byte-range requests
(such as S3, Cloudflare R2, or a suitable static host), then load its public URL
with `anymap-ts` or the MapLibre PMTiles protocol. Do not rely on Streamlit's
built-in static-file server for production PMTiles delivery; `.pmtiles` is not
one of its officially supported static media types.

The archive is regenerated with the analysis pipeline and contains four named
layers: `congressional_districts`, `cws_service_areas`, `all_block_groups`, and
`vulnerable_block_groups`. Keep `data/water_infrastructure.pmtiles` with the
deployment artifacts even while the Streamlit app uses state-split GeoJSON as
its default, zero-infrastructure map source.

## Principal outputs

- Congressional-district metrics and boundaries
- CWS service areas clipped to congressional districts
- Complete Census block-group coverage, split into lightweight state files
- CWS-served block groups in the district community tables
- The most vulnerable 10% of served block groups
- District-to-water-system lookup with compliance and component summaries

EPA service areas include both authoritative and modeled boundaries. Geocoded
administrative addresses are retained as an optional layer and should not be
interpreted as physical infrastructure locations.
