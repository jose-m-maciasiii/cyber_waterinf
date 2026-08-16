from __future__ import annotations

import json
from pathlib import Path
from typing import Any, Optional

import pandas as pd
import pydeck as pdk
import streamlit as st


APP_DIR = Path(__file__).resolve().parent
DATA_DIR = APP_DIR / "data"
LOGO_PATH = APP_DIR / "assets" / "periphery_analytics_logo.png"
FOOTER_LOGO_PATH = APP_DIR / "assets" / "periphery_analytics_wordmark.png"
MAP_STYLE = "https://basemaps.cartocdn.com/gl/positron-gl-style/style.json"
STATE_NAMES = {
    "GA": "Georgia",
    "MI": "Michigan",
    "MN": "Minnesota",
    "NJ": "New Jersey",
    "SD": "South Dakota",
}


st.set_page_config(
    page_title="Small Water Systems Explorer",
    page_icon="💧",
    layout="wide",
)

st.markdown(
    """
    <style>
      :root {
        --ink:#163247; --ink-soft:#526b7a; --blue:#176f91; --aqua:#198f91;
        --aqua-soft:#dff1f0; --sand:#f5f0e5; --paper:#ffffff;
        --canvas:#f6f9fa; --line:#dbe5e8;
      }
      html, body, [class*="css"] {
        font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif;
      }
      .stApp {
        background:
          radial-gradient(circle at 82% 0%, rgba(25,143,145,.07), transparent 26rem),
          var(--canvas);
        color:var(--ink);
      }
      /* Increase this value to let the dashboard use more of a wide screen. */
      .block-container { max-width:1720px; padding-top:1.35rem; padding-bottom:3rem; }
      [data-testid="stSidebar"] {
        background:linear-gradient(180deg,#f0f6f7 0%,#f8faf9 65%,#f5f0e5 100%);
        border-right:1px solid var(--line);
      }
      [data-testid="stSidebar"] [data-testid="stSidebarContent"] {
        padding-top:1.25rem;
      }
      [data-testid="stSidebar"] h2 {
        font-size:1.15rem; letter-spacing:-.01em; margin-bottom:.8rem;
      }
      [data-testid="stSidebar"] hr { border-color:var(--line); margin:1.15rem 0; }
      [data-testid="stSidebar"] details {
        background:rgba(255,255,255,.62); border:1px solid var(--line);
        border-radius:10px; padding:.1rem .65rem;
      }
      .eyebrow { color:var(--aqua); font-size:.74rem; font-weight:700;
                 letter-spacing:.14em; text-transform:uppercase; margin-bottom:.45rem; }
      .hero {
        position:relative; overflow:hidden;
        background:linear-gradient(125deg,#e5f4f3 0%,#f4f9f9 52%,#f4edde 100%);
        border:1px solid #d5e5e5; border-radius:20px; padding:1.6rem 1.75rem;
        margin-bottom:1.35rem; box-shadow:0 12px 32px rgba(22,50,71,.06);
      }
      .hero::after {
        content:""; position:absolute; width:210px; height:210px; right:-72px;
        top:-118px; border-radius:50%; border:32px solid rgba(25,143,145,.09);
      }
      .hero h1 { color:var(--ink); font-size:clamp(2rem,3vw,2.75rem);
                 letter-spacing:-.035em; line-height:1.02; margin:.1rem 0 .65rem; }
      .hero p { color:var(--ink-soft); max-width:820px; font-size:1.02rem;
                line-height:1.55; margin:0; }
      .district-heading { display:flex; align-items:flex-end; justify-content:space-between;
                          flex-wrap:wrap; gap:.75rem; margin:.2rem 0 1rem; }
      .district-heading h2 { margin:0; letter-spacing:-.025em; }
      .district-meta { color:var(--ink-soft); font-size:.92rem; }
      .party-tag { display:inline-block; background:var(--aqua-soft); color:var(--ink);
                   border:1px solid #c5e2e0; border-radius:999px; padding:.25rem .6rem;
                   font-size:.8rem; font-weight:600; }
      [data-testid="stMetric"] {
        background:rgba(255,255,255,.92); border:1px solid var(--line);
        border-radius:14px; min-height:112px; padding:.9rem 1rem;
        box-shadow:0 5px 16px rgba(22,50,71,.045);
      }
      [data-testid="stMetricLabel"] { color:var(--ink-soft); font-size:.82rem; }
      [data-testid="stMetricValue"] { color:var(--ink); letter-spacing:-.025em; }
      h1, h2, h3 { color:var(--ink); }
      .note { color:var(--ink-soft); font-size:.88rem; }
      .source-box { background:linear-gradient(135deg,#eef7f6,#f8fbfa);
                    border:1px solid #d5e7e5; border-left:4px solid var(--aqua);
                    padding:.9rem 1rem; border-radius:10px; line-height:1.5; }
      .instruction { display:flex; gap:.7rem; align-items:center; color:var(--ink-soft);
                     background:rgba(255,255,255,.82); border:1px solid var(--line);
                     border-radius:12px; padding:.7rem .85rem; margin:.2rem 0 .85rem; }
      .step-dot { display:inline-grid; place-items:center; flex:0 0 26px; height:26px;
                  border-radius:50%; background:var(--aqua); color:white;
                  font-size:.78rem; font-weight:700; }
      [data-testid="stAlert"] { border-radius:12px; border:1px solid #d6e5e8; }
      [data-testid="stDeckGlJsonChart"] {
        border:1px solid var(--line); border-radius:16px; overflow:hidden;
        box-shadow:0 8px 24px rgba(22,50,71,.07);
      }
      [data-baseweb="tab-list"] { gap:.25rem; border-bottom:1px solid var(--line); }
      [data-baseweb="tab"] { padding:.65rem .9rem; }
      [data-testid="stDataFrame"] { border:1px solid var(--line); border-radius:12px;
                                     overflow:hidden; }
      .footer-copy { color:var(--ink-soft); font-size:.86rem; line-height:1.65; }
      .footer-copy strong { color:var(--ink); }
      .footer-copy a { color:var(--blue); text-decoration:none; }
      .footer-copy a:hover { text-decoration:underline; }
      .map-legend { display:flex; flex-wrap:wrap; gap:.45rem 1rem; align-items:center;
                    margin:.6rem 0 .3rem; padding:.55rem .7rem; color:var(--ink-soft);
                    font-size:.8rem; background:rgba(255,255,255,.78);
                    border:1px solid var(--line); border-radius:10px; }
      .map-legend-title { color:var(--ink); font-weight:700; margin-right:.1rem; }
      .legend-item { display:inline-flex; align-items:center; gap:.35rem; }
      .legend-swatch { display:inline-block; width:16px; height:12px; border-radius:2px; }
      .legend-point { width:10px; height:10px; border-radius:50%; background:#095b6c;
                      border:1.5px solid #0f191e; }
      .legend-district { width:18px; height:10px; border:2px solid #142a3d;
                         background:transparent; }
      .legend-service { background:rgba(20,145,170,.35); border:2px solid #11708e; }
      .legend-vulnerable { background:rgba(176,35,42,.72); border:1px solid #6c0f18; }
      @media (max-width: 760px) {
        .block-container { padding-top:.8rem; }
        .hero { padding:1.2rem; border-radius:15px; }
        .hero h1 { font-size:2rem; }
        .district-heading { align-items:flex-start; flex-direction:column; }
        .map-legend { gap:.4rem .7rem; }
      }
    </style>
    """,
    unsafe_allow_html=True,
)


@st.cache_data(show_spinner=False)
def load_csv(filename: str) -> pd.DataFrame:
    path = DATA_DIR / filename
    if not path.exists():
        raise FileNotFoundError(path)
    return pd.read_csv(path)


@st.cache_data(show_spinner=False)
def load_geojson(filename: str) -> dict[str, Any]:
    path = DATA_DIR / filename
    if not path.exists():
        raise FileNotFoundError(path)
    with path.open("r", encoding="utf-8") as handle:
        return json.load(handle)


def subset_geojson(
    data: dict[str, Any], geography_id: str, property_name: str
) -> dict[str, Any]:
    """Keep features assigned to or clipped to a selected geography."""
    features = []
    for feature in data.get("features", []):
        value = str(feature.get("properties", {}).get(property_name, ""))
        if geography_id in [part.strip() for part in value.split("/")]:
            features.append(feature)
    return {"type": "FeatureCollection", "features": features}


def geography_feature(
    data: dict[str, Any], geography_id: str, property_name: str
) -> dict[str, Any]:
    features = [
        feature
        for feature in data.get("features", [])
        if str(feature.get("properties", {}).get(property_name)) == geography_id
    ]
    return {"type": "FeatureCollection", "features": features}


def ids_features(
    data: dict[str, Any], geography_ids: set[str], property_name: str
) -> dict[str, Any]:
    """Keep features assigned to any identifier in a selected state."""
    features = []
    for feature in data.get("features", []):
        value = str(feature.get("properties", {}).get(property_name, ""))
        if any(part.strip() in geography_ids for part in value.split("/")):
            features.append(feature)
    return {"type": "FeatureCollection", "features": features}


def county_block_group_features(
    data: dict[str, Any], county_geoid: str
) -> dict[str, Any]:
    """Filter block groups by county field, with GEOID-prefix fallback."""
    county_geoid = str(county_geoid).zfill(5)
    features = []
    for feature in data.get("features", []):
        properties = feature.get("properties", {})
        feature_county = str(properties.get("county_geoid", "")).zfill(5)
        block_group_geoid = str(properties.get("GEOID", ""))
        if feature_county == county_geoid or block_group_geoid.startswith(
            county_geoid
        ):
            features.append(feature)
    return {"type": "FeatureCollection", "features": features}


def state_features(data: dict[str, Any], state_code: str) -> dict[str, Any]:
    """Keep features assigned to any congressional district in a state."""
    features = []
    district_prefix = f"{state_code}-"
    for feature in data.get("features", []):
        properties = feature.get("properties", {})
        district_value = str(properties.get("congressional_district", ""))
        district_ids = [part.strip() for part in district_value.split("/")]
        if properties.get("state_po") == state_code or any(
            district_id.startswith(district_prefix) for district_id in district_ids
        ):
            features.append(feature)
    return {"type": "FeatureCollection", "features": features}


def coordinate_pairs(value: Any):
    if isinstance(value, list) and len(value) >= 2 and all(
        isinstance(item, (int, float)) for item in value[:2]
    ):
        yield float(value[0]), float(value[1])
    elif isinstance(value, list):
        for item in value:
            yield from coordinate_pairs(item)


def map_view(feature_collection: dict[str, Any]) -> pdk.ViewState:
    pairs = []
    for feature in feature_collection.get("features", []):
        pairs.extend(coordinate_pairs(feature.get("geometry", {}).get("coordinates", [])))
    if not pairs:
        return pdk.ViewState(latitude=39.5, longitude=-96.5, zoom=3.3)
    longitudes, latitudes = zip(*pairs)
    lon_span = max(longitudes) - min(longitudes)
    lat_span = max(latitudes) - min(latitudes)
    span = max(lon_span, lat_span, 0.02)
    zoom = max(5.0, min(11.5, 8.5 - (span - 0.2) * 1.15))
    return pdk.ViewState(
        latitude=(min(latitudes) + max(latitudes)) / 2,
        longitude=(min(longitudes) + max(longitudes)) / 2,
        zoom=zoom,
        pitch=0,
    )


def number(value: Any, decimals: int = 0) -> str:
    value = pd.to_numeric(value, errors="coerce")
    if pd.isna(value):
        return "Not available"
    return f"{value:,.{decimals}f}"


def money(value: Any) -> str:
    value = pd.to_numeric(value, errors="coerce")
    return "Not available" if pd.isna(value) else f"${value:,.0f}"


def percent(value: Any, already_percent: bool = True) -> str:
    value = pd.to_numeric(value, errors="coerce")
    if pd.isna(value):
        return "Not available"
    if not already_percent:
        value *= 100
    return f"{value:.1f}%"


def source_label(value: Any) -> str:
    """Expand EPA primary-source codes for public-facing labels."""
    if pd.isna(value):
        return "Not available"
    code = str(value).upper()
    labels = {
        "GW": "Ground water (GW)",
        "GWP": "Purchased ground water (GWP)",
        "SW": "Surface water (SW)",
        "SWP": "Purchased surface water (SWP)",
        "GU": "Ground water under the influence of surface water (GU)",
        "GUP": "Purchased ground water under the influence of surface water (GUP)",
    }
    return labels.get(code, code)


def add_geojson_tooltips(
    data: dict[str, Any], layer_type: str
) -> dict[str, Any]:
    """Give every pickable GeoJSON layer the same tooltip field names."""
    for feature in data.get("features", []):
        properties = feature.setdefault("properties", {})
        if layer_type == "service_area":
            properties.update(
                tooltip_title=str(properties.get("pws_name") or "Water system"),
                tooltip_label_1="PWSID",
                tooltip_value_1=str(properties.get("pwsid") or "Not available"),
                tooltip_label_2="Population served",
                tooltip_value_2=number(properties.get("population_served_count")),
                tooltip_label_3="Service-area source",
                tooltip_value_3=str(
                    properties.get("symbology_field") or "Not available"
                ),
                tooltip_label_4="Model method",
                tooltip_value_4=str(properties.get("model_method") or "Not available"),
            )
        else:
            properties.update(
                tooltip_title=str(properties.get("NAME") or "Census block group"),
                tooltip_label_1="Poverty rate",
                tooltip_value_1=percent(properties.get("poverty_rate")),
                tooltip_label_2="Median household income",
                tooltip_value_2=money(properties.get("median_household_income")),
                tooltip_label_3="Estimated population served",
                tooltip_value_3=number(
                    properties.get("estimated_cws_service_population")
                ),
                tooltip_label_4="Rural status",
                tooltip_value_4=str(
                    properties.get("rural_status") or "Not available"
                ),
            )
    return data


def map_layers(
    communities: dict[str, Any],
    vulnerable: dict[str, Any],
    geography_boundaries: dict[str, Any],
    service_areas: dict[str, Any],
    water_systems: pd.DataFrame,
    census_variable: Optional[str],
    show_vulnerable: bool,
) -> list[pdk.Layer]:
    """Build map layers from bottom to top."""
    census_fills = {
        "Poverty rate": (
            "properties.poverty_rate == null ? [180,180,180,55] : "
            "properties.poverty_rate >= 30 ? [153,27,30,120] : "
            "properties.poverty_rate >= 20 ? [230,85,13,105] : "
            "properties.poverty_rate >= 10 ? [253,174,107,90] : "
            "[255,237,160,75]"
        ),
        "Median household income": (
            "properties.median_household_income == null ? [180,180,180,55] : "
            "properties.median_household_income >= 90000 ? [8,81,156,120] : "
            "properties.median_household_income >= 60000 ? [49,130,189,105] : "
            "properties.median_household_income >= 40000 ? [107,174,214,90] : "
            "[198,219,239,75]"
        ),
        "Rural population share": (
            "properties.rural_share == null ? [180,180,180,55] : "
            "properties.rural_share >= 1 ? [0,90,50,120] : "
            "properties.rural_share >= 0.5 ? [49,163,84,105] : "
            "properties.rural_share > 0 ? [161,217,155,90] : "
            "[237,248,233,75]"
        ),
    }
    layers: list[pdk.Layer] = []
    if census_variable:
        layers.append(
            pdk.Layer(
                "GeoJsonLayer",
                communities,
                id="served-communities",
                pickable=True,
                stroked=True,
                filled=True,
                get_fill_color=census_fills[census_variable],
                get_line_color=[255, 255, 255, 110],
                line_width_min_pixels=0.4,
            )
        )
    if show_vulnerable:
        layers.append(
            pdk.Layer(
                "GeoJsonLayer",
                vulnerable,
                id="vulnerable-communities",
                pickable=True,
                stroked=True,
                filled=True,
                get_fill_color=[176, 35, 42, 145],
                get_line_color=[108, 15, 24, 225],
                line_width_min_pixels=1.1,
            )
        )
    layers.append(
        pdk.Layer(
            "GeoJsonLayer",
            geography_boundaries,
            id="geography-outline",
            pickable=False,
            stroked=True,
            filled=False,
            get_line_color=[20, 42, 61, 245],
            line_width_min_pixels=3,
        )
    )
    layers.append(
        pdk.Layer(
            "GeoJsonLayer",
            service_areas,
            id="service-areas",
            pickable=True,
            stroked=True,
            filled=True,
            get_fill_color=[20, 145, 170, 42],
            get_line_color=[17, 112, 142, 185],
            line_width_min_pixels=1.2,
        )
    )
    point_data = water_systems.dropna(subset=["latitude", "longitude"]).copy()
    if not point_data.empty:
        point_data["tooltip_title"] = point_data["pws_name"].fillna("Water system")
        point_data["tooltip_label_1"] = "PWSID"
        point_data["tooltip_value_1"] = point_data["pwsid"].fillna(
            "Not available"
        ).astype(str)
        point_data["tooltip_label_2"] = "Population served"
        point_data["tooltip_value_2"] = point_data["population_served_count"].map(
            number
        )
        point_data["tooltip_label_3"] = "Active components"
        point_data["tooltip_value_3"] = point_data["active_component_count"].map(
            number
        )
        point_data["tooltip_label_4"] = "Primary source"
        point_data["tooltip_value_4"] = point_data["primary_source_code"].map(
            source_label
        )
        layers.append(
            pdk.Layer(
                "ScatterplotLayer",
                point_data,
                id="administrative-points",
                get_position="[longitude, latitude]",
                get_radius=90,
                radius_min_pixels=3,
                radius_max_pixels=8,
                get_fill_color=[9, 91, 108, 235],
                get_line_color=[15, 25, 30, 255],
                line_width_min_pixels=1.5,
                pickable=True,
            )
        )
    return layers


MAP_TOOLTIP = {
    "html": (
        "<b>{tooltip_title}</b><br/>"
        "<b>{tooltip_label_1}:</b> {tooltip_value_1}<br/>"
        "<b>{tooltip_label_2}:</b> {tooltip_value_2}<br/>"
        "<b>{tooltip_label_3}:</b> {tooltip_value_3}<br/>"
        "<b>{tooltip_label_4}:</b> {tooltip_value_4}"
    ),
    "style": {"backgroundColor": "#17324d", "color": "white"},
}


def show_selected_map_feature(map_event: Any) -> None:
    """Show the most recently clicked feature below a map."""
    selected_objects = map_event.selection.get("objects", {})
    selected_object = next(
        (records[-1] for records in selected_objects.values() if records),
        None,
    )
    if selected_object:
        selected_properties = selected_object.get("properties", selected_object)
        detail_lines = "<br/>".join(
            "<strong>"
            f"{selected_properties.get(f'tooltip_label_{index}', '')}:"
            "</strong> "
            f"{selected_properties.get(f'tooltip_value_{index}', '')}"
            for index in range(1, 5)
            if selected_properties.get(f"tooltip_label_{index}")
        )
        st.markdown(
            "<div class='source-box'><strong>Selected map feature</strong><br/>"
            f"<strong>{selected_properties.get('tooltip_title', 'Map feature')}</strong>"
            f"<br/>{detail_lines}</div>",
            unsafe_allow_html=True,
        )
    else:
        st.caption("Click a service area, block group, or point to keep its details visible.")


def show_map_legend(
    census_variable: Optional[str], show_vulnerable: bool, boundary_label: str
) -> None:
    """Render the shared state and selected-geography map legend."""
    census_items = {
        "Poverty rate": (
            '<span class="legend-item"><span class="legend-swatch" style="background:rgba(255,237,160,.75)"></span>Poverty &lt;10%</span>'
            '<span class="legend-item"><span class="legend-swatch" style="background:rgba(253,174,107,.8)"></span>10–&lt;20%</span>'
            '<span class="legend-item"><span class="legend-swatch" style="background:rgba(230,85,13,.75)"></span>20–&lt;30%</span>'
            '<span class="legend-item"><span class="legend-swatch" style="background:rgba(153,27,30,.8)"></span>30% or higher</span>'
        ),
        "Median household income": (
            '<span class="legend-item"><span class="legend-swatch" style="background:rgba(198,219,239,.75)"></span>Income &lt;$40K</span>'
            '<span class="legend-item"><span class="legend-swatch" style="background:rgba(107,174,214,.8)"></span>$40K–&lt;$60K</span>'
            '<span class="legend-item"><span class="legend-swatch" style="background:rgba(49,130,189,.75)"></span>$60K–&lt;$90K</span>'
            '<span class="legend-item"><span class="legend-swatch" style="background:rgba(8,81,156,.8)"></span>$90K or higher</span>'
        ),
        "Rural population share": (
            '<span class="legend-item"><span class="legend-swatch" style="background:rgba(237,248,233,.75)"></span>Fully urban</span>'
            '<span class="legend-item"><span class="legend-swatch" style="background:rgba(161,217,155,.8)"></span>Partly rural</span>'
            '<span class="legend-item"><span class="legend-swatch" style="background:rgba(49,163,84,.75)"></span>Majority rural</span>'
            '<span class="legend-item"><span class="legend-swatch" style="background:rgba(0,90,50,.8)"></span>Fully rural</span>'
        ),
    }.get(census_variable, "")
    vulnerable_item = (
        '<span class="legend-item"><span class="legend-swatch '
        'legend-vulnerable"></span>Highest Disadvantaged Decile</span>'
        if show_vulnerable
        else ""
    )
    st.markdown(
        f"""
        <div class="map-legend" aria-label="Map legend">
          <span class="map-legend-title">Legend</span>
          {census_items}
          {vulnerable_item}
          <span class="legend-item"><span class="legend-swatch legend-service"></span>Vulnerable CWS service area</span>
          <span class="legend-item"><span class="legend-district"></span>{boundary_label}</span>
          <span class="legend-item"><span class="legend-point"></span>CWS Administration Address</span>
        </div>
        """,
        unsafe_allow_html=True,
    )


def show_footer() -> None:
    """Show the branded, linked source footer on every dashboard view."""
    st.divider()
    footer_sources, footer_brand = st.columns(
        [5, 1.4], vertical_alignment="center"
    )
    with footer_sources:
        st.markdown(
            """
            <div class="footer-copy"><strong>Sources</strong><br>
            <a href="https://echo.epa.gov/tools/data-downloads/sdwa-download-summary" target="_blank">U.S. EPA Safe Drinking Water Information System (SDWIS)</a> ·
            <a href="https://www.epa.gov/ground-water-and-drinking-water/public-water-system-service-areas" target="_blank">EPA Public Water System Service Areas v3.0</a> ·
            <a href="https://api.census.gov/data/2024/acs/acs5.html" target="_blank">U.S. Census Bureau 2020–2024 ACS five-year estimates</a> ·
            <a href="https://www.census.gov/data/tables/2023/dec/2020-census-dhc.html" target="_blank">2020 Census Demographic and Housing Characteristics File</a> ·
            <a href="https://electionlab.mit.edu/data" target="_blank">MIT Election Data and Science Lab, U.S. House 1976–2024</a>.
            </div>
            """,
            unsafe_allow_html=True,
        )
    with footer_brand:
        st.image(str(FOOTER_LOGO_PATH), width=190)


try:
    districts = load_csv("district_metrics.csv")
    systems = load_csv("district_water_systems.csv")
    district_geo = load_geojson("congressional_districts.geojson")
    service_geo = load_geojson("cws_service_areas.geojson")
    counties = load_csv("county_metrics.csv")
    county_systems = load_csv("county_water_systems.csv")
    county_geo = load_geojson("counties.geojson")
    county_service_geo = load_geojson("county_cws_service_areas.geojson")
    vulnerable_geo = load_geojson("vulnerable_block_groups.geojson")
    counties["county_geoid"] = counties["county_geoid"].astype(str).str.zfill(5)
    county_systems["county_geoid"] = (
        county_systems["county_geoid"].astype(str).str.zfill(5)
    )
except FileNotFoundError as exc:
    st.error(
        f"Dashboard data are missing: {exc}. Run water_inf_analysis.R through "
        "the analysis export section first."
    )
    st.stop()


st.markdown(
    """
    <div class="hero">
      <div class="eyebrow">Public water infrastructure</div>
      <h1>Small Water Systems Explorer</h1>
      <p>Explore community water systems serving 3,300 people or fewer and the
      communities within their EPA service areas. Search by congressional district
      or county to connect water infrastructure, community conditions, and political
      representation. Includes data on 5 states recently targeted by Iranian hackers.</p>
    </div>
    """,
    unsafe_allow_html=True,
)


with st.sidebar:
    st.header("Choose an Area")
    available_states = sorted(districts["state_po"].dropna().unique().tolist())
    selected_state = st.selectbox(
        "Step 1: State",
        available_states,
        index=None,
        placeholder="Select a state",
    )
    analysis_level = st.radio(
        "Step 2: Analysis level",
        ["Congressional district", "County"],
        horizontal=True,
        disabled=selected_state is None,
    )
    if analysis_level == "Congressional district":
        state_rows = districts[districts["state_po"] == selected_state].copy()
        state_rows = state_rows.sort_values("district")
        area_options = state_rows["congressional_district"].tolist()
        area_labels = {value: value for value in area_options}
    else:
        state_rows = counties[counties["state_po"] == selected_state].copy()
        state_rows = state_rows.sort_values("county_name")
        area_options = state_rows["county_geoid"].astype(str).str.zfill(5).tolist()
        area_labels = dict(zip(area_options, state_rows["county_name"]))
    selected_area = st.selectbox(
        f"Select a {analysis_level.lower()}",
        area_options,
        index=None,
        placeholder=(
            f"Select a {analysis_level.lower()}"
            if selected_state else "Select a state first"
        ),
        disabled=selected_state is None,
        format_func=lambda value: area_labels.get(value, value),
    )
    selected_district = (
        selected_area if analysis_level == "Congressional district" else None
    )
    selected_county = selected_area if analysis_level == "County" else None

    if selected_state:
        st.divider()
        st.subheader("Outside Certification Requirements")
        st.caption(
            "The vulnerable community water systems identified here serve 3,300 people or fewer "
            "and are not required to certify completion of a risk and resilience "
            "assessment or emergency response plan to EPA under "
            "[America's Water Infrastructure Act (AWIA)]"
            "(https://www.epa.gov/waterresilience/awia-section-2013)."
        )
        show_vulnerable = st.checkbox(
            "Highlight most disadvantaged block groups",
            value=False,
            help=(
                "Shows the highest disadvantaged decile among Census block groups "
                "connected to these small community water systems. Vulnerability "
                "combines higher poverty with lower median household income."
            ),
        )
        st.caption(
            "When selected, dark red block groups represent the most disadvantaged "
            "10% based equally on high poverty and low median household income."
        )
        st.subheader("Optional Census Variables")
        census_variable = st.selectbox(
            "Color block groups by",
            [
                "Poverty rate",
                "Median household income",
                "Rural population share",
            ],
            index=None,
            placeholder="Choose an optional Census variable",
        )

    st.divider()
    with st.expander("Data Sources"):
        st.caption(
            "Analysis by Jose M. Macias III of Periphery Analytics. Data sources: "
            "U.S. EPA SDWIS and U.S. Census Bureau American Community Survey "
            "five-year estimates. Geocoded CWS administrative points are based on "
            "contact addresses reported to EPA and may contain positional errors; "
            "they do not necessarily represent physical infrastructure locations."
        )
    st.image(
        str(LOGO_PATH),
        width=190,
    )


if not selected_state:
    st.markdown(
        """
        <div class="instruction"><span class="step-dot">1</span><span>
        Select a state in the sidebar to open its statewide water-system map.
        You can then choose either a congressional district or county.</span></div>
        """,
        unsafe_allow_html=True,
    )
    blank_deck = pdk.Deck(
        layers=[],
        initial_view_state=pdk.ViewState(
            latitude=39.5,
            longitude=-96.5,
            zoom=3.3,
            pitch=0,
        ),
        map_style=MAP_STYLE,
    )
    st.pydeck_chart(blank_deck, use_container_width=True, height=650)
    show_footer()
    st.stop()


try:
    communities_geo = load_geojson(
        f"block_groups/{selected_state.lower()}_block_groups.geojson"
    )
except FileNotFoundError as exc:
    st.error(
        f"State block-group data are missing: {exc}. Run water_inf_analysis.R "
        "through the dashboard export section."
    )
    st.stop()


if not selected_area:
    geography_property = (
        "congressional_district"
        if analysis_level == "Congressional district"
        else "county_geoid"
    )
    active_boundaries = (
        district_geo if analysis_level == "Congressional district" else county_geo
    )
    active_services = (
        service_geo
        if analysis_level == "Congressional district"
        else county_service_geo
    )
    active_systems = (
        systems if analysis_level == "Congressional district" else county_systems
    )
    state_ids = set(area_options)
    selected_state_boundaries = ids_features(
        active_boundaries, state_ids, geography_property
    )
    selected_state_services = add_geojson_tooltips(
        ids_features(active_services, state_ids, geography_property),
        "service_area",
    )
    selected_state_communities = add_geojson_tooltips(
        state_features(communities_geo, selected_state), "community"
    )
    selected_state_vulnerable = add_geojson_tooltips(
        state_features(vulnerable_geo, selected_state), "community"
    )
    system_ids = active_systems[geography_property].astype(str)
    if geography_property == "county_geoid":
        system_ids = system_ids.str.zfill(5)
    selected_state_systems = active_systems.loc[
        system_ids.isin(state_ids)
    ].drop_duplicates(subset=["pwsid"])

    st.markdown(
        '<div class="eyebrow">Statewide exploration</div>'
        f'<h2>{STATE_NAMES.get(selected_state, selected_state)} water systems</h2>',
        unsafe_allow_html=True,
    )
    st.markdown(
        """
        <div class="instruction"><span class="step-dot">2</span><span>
        Choose an analysis level and select an area in the sidebar to open its
        infrastructure and community profile.</span></div>
        """,
        unsafe_allow_html=True,
    )
    state_layers = map_layers(
        selected_state_communities,
        selected_state_vulnerable,
        selected_state_boundaries,
        selected_state_services,
        selected_state_systems,
        census_variable,
        show_vulnerable,
    )
    state_deck = pdk.Deck(
        layers=state_layers,
        initial_view_state=map_view(selected_state_boundaries),
        map_style=MAP_STYLE,
        tooltip=MAP_TOOLTIP,
    )
    show_map_legend(census_variable, show_vulnerable, analysis_level.title())
    state_map_event = st.pydeck_chart(
        state_deck,
        use_container_width=True,
        height=650,
        on_select="rerun",
        selection_mode="single-object",
        key=f"state-map-{selected_state}-{analysis_level}",
    )
    st.caption(
        f"The statewide view shows all available {analysis_level.lower()} "
        "boundaries and small-CWS data for the selected state."
    )
    show_selected_map_feature(state_map_event)
    show_footer()
    st.stop()


if selected_county:
    county_row = counties.loc[counties["county_geoid"] == selected_county].iloc[0]
    selected_systems = county_systems.loc[
        county_systems["county_geoid"] == selected_county
    ].drop_duplicates(subset=["pwsid"])
    selected_boundary_geo = geography_feature(
        county_geo, selected_county, "county_geoid"
    )
    selected_service_geo = subset_geojson(
        county_service_geo, selected_county, "county_geoid"
    )
    selected_communities_geo = county_block_group_features(
        communities_geo, selected_county
    )
    selected_vulnerable_geo = county_block_group_features(
        vulnerable_geo, selected_county
    )
    selected_service_geo = add_geojson_tooltips(selected_service_geo, "service_area")
    selected_communities_geo = add_geojson_tooltips(
        selected_communities_geo, "community"
    )
    selected_vulnerable_geo = add_geojson_tooltips(
        selected_vulnerable_geo, "community"
    )

    st.markdown(
        f"""
        <div class="district-heading">
          <div>
            <div class="eyebrow">County profile</div>
            <h2>{county_row['county_name']}, {selected_state}</h2>
          </div>
          <div class="district-meta">
            Congressional districts&nbsp; <strong>{county_row['congressional_districts']}</strong><br>
            Representatives&nbsp; <strong>{county_row['elected_representatives']}</strong>&nbsp;
            <span class="party-tag">{str(county_row['representative_parties']).title()}</span>
          </div>
        </div>
        """,
        unsafe_allow_html=True,
    )

    metric_cols = st.columns(5)
    metric_cols[0].metric(
        "CWS outside AWIA threshold",
        number(county_row["cws_service_area_count"]),
    )
    metric_cols[1].metric(
        "Estimated population served",
        number(county_row["estimated_cws_service_population"]),
    )
    metric_cols[2].metric(
        "Most disadvantaged block groups",
        number(county_row["vulnerable_block_group_count"]),
    )
    metric_cols[3].metric(
        "Active water components", number(county_row["cws_component_count"])
    )
    metric_cols[4].metric(
        "Service-area coverage",
        f"{number(county_row['cws_service_area_sq_km'])} km²",
    )

    if show_vulnerable and not selected_vulnerable_geo["features"]:
        st.info(
            "This county does not contain a block group in the highest "
            "disadvantage decile for this five-state analysis. Choose an "
            "optional Census variable to display all block groups in the county."
        )

    map_col, context_col = st.columns([3.4, 1], gap="large")
    with map_col:
        layers = map_layers(
            selected_communities_geo,
            selected_vulnerable_geo,
            selected_boundary_geo,
            selected_service_geo,
            selected_systems,
            census_variable,
            show_vulnerable,
        )
        deck = pdk.Deck(
            layers=layers,
            initial_view_state=map_view(selected_boundary_geo),
            map_style=MAP_STYLE,
            tooltip=MAP_TOOLTIP,
        )
        show_map_legend(census_variable, show_vulnerable, "County")
        map_event = st.pydeck_chart(
            deck,
            use_container_width=True,
            height=650,
            on_select="rerun",
            selection_mode="single-object",
            key=f"county-map-{selected_county}",
        )
        st.caption(
            "County boundaries organize the profile; service areas and block "
            "groups remain the underlying EPA and Census geographies."
        )
        show_selected_map_feature(map_event)

    with context_col:
        st.markdown("### About the County")
        st.metric("County population", number(county_row["total_population"]))
        st.metric(
            "County median household income",
            money(county_row["median_household_income"]),
        )
        st.metric("County poverty rate", percent(county_row["poverty_rate"]))
        st.metric(
            "Rural population share",
            percent(county_row["county_rural_share"], False),
        )

    overview_tab, systems_tab, communities_tab, methods_tab = st.tabs(
        ["Overview", "Water systems", "Communities", "Methods & limitations"]
    )
    with overview_tab:
        c1, c2, c3 = st.columns(3)
        c1.metric(
            "Estimated households served",
            number(county_row["estimated_cws_service_households"]),
        )
        c2.metric(
            "Systems with unresolved violations",
            number((selected_systems["unresolved_violation_count"].fillna(0) > 0).sum()),
        )
        c3.metric(
            "Site inspections recorded",
            number(selected_systems["site_inspection_count"].fillna(0).sum()),
        )
        st.markdown(
            "This county view lists every congressional district and elected "
            "representative whose district overlaps the county."
        )

    with systems_tab:
        st.markdown(f"### {len(selected_systems):,} systems intersect this county")
        search = st.text_input(
            "Search system name or PWSID",
            placeholder="Type a name or identifier",
            key="county-system-search",
        )
        system_table = selected_systems.copy()
        if search:
            mask = (
                system_table["pws_name"].fillna("").str.contains(search, case=False, regex=False)
                | system_table["pwsid"].fillna("").str.contains(search, case=False, regex=False)
            )
            system_table = system_table.loc[mask]
        display_columns = {
            "pws_name": "Water system",
            "pwsid": "PWSID",
            "population_served_count": "Population served",
            "primary_source_code": "Source",
            "active_component_count": "Components",
            "violation_count": "Violations",
            "unresolved_violation_count": "Unresolved",
            "health_based_violation_count": "Health-based",
            "site_inspection_count": "Inspections",
        }
        st.dataframe(
            system_table[list(display_columns)].rename(columns=display_columns),
            hide_index=True,
            width="stretch",
            height=410,
        )
        st.download_button(
            "Download county water systems (CSV)",
            system_table.to_csv(index=False).encode("utf-8"),
            file_name=f"{selected_county}_small_cws.csv",
            mime="text/csv",
        )

    with communities_tab:
        community_rows = [
            feature.get("properties", {})
            for feature in selected_communities_geo["features"]
            if pd.to_numeric(
                feature.get("properties", {}).get("cws_service_area_count"),
                errors="coerce",
            ) > 0
        ]
        communities = pd.DataFrame(community_rows)
        if communities.empty:
            st.info("No block-group crosswalk records are available for this county.")
        else:
            st.markdown(f"### {len(communities):,} served Census block groups")
            columns = {
                "NAME": "Community",
                "GEOID": "Block group GEOID",
                "poverty_rate": "Poverty rate (%)",
                "median_household_income": "Median household income",
                "rural_status": "Rural status",
                "cws_service_area_count": "CWS",
                "estimated_cws_service_population": "Estimated population served",
            }
            available = [column for column in columns if column in communities.columns]
            st.dataframe(
                communities[available].rename(columns=columns).sort_values(
                    "Poverty rate (%)", ascending=False
                ),
                hide_index=True,
                width="stretch",
                height=410,
            )
            st.download_button(
                "Download county communities (CSV)",
                communities.to_csv(index=False).encode("utf-8"),
                file_name=f"{selected_county}_served_block_groups.csv",
                mime="text/csv",
            )

    with methods_tab:
        st.markdown(
            """
            ### How to read the county analysis

            - County demographics are 2020–2024 ACS five-year estimates.
            - Rural population is aggregated from 2020 DHC block-group counts.
            - Water systems and service-area coverage use positive EPA polygon
              intersections with the county boundary.
            - Representatives are included when their congressional district has
              a positive-area overlap with the county; some counties therefore
              have multiple representatives and parties.
            - Administrative points are reported contact addresses and may not
              represent infrastructure locations.
            """
        )
    show_footer()
    st.stop()


district_row = districts.loc[
    districts["congressional_district"] == selected_district
].iloc[0]
selected_systems = systems.loc[
    systems["congressional_district"] == selected_district
].copy()
selected_systems = selected_systems.drop_duplicates(subset=["pwsid"])

selected_district_geo = geography_feature(
    district_geo, selected_district, "congressional_district"
)
selected_service_geo = subset_geojson(
    service_geo, selected_district, "congressional_district"
)
selected_communities_geo = subset_geojson(
    communities_geo, selected_district, "congressional_district"
)
selected_vulnerable_geo = subset_geojson(
    vulnerable_geo, selected_district, "congressional_district"
)
selected_service_geo = add_geojson_tooltips(selected_service_geo, "service_area")
selected_communities_geo = add_geojson_tooltips(selected_communities_geo, "community")
selected_vulnerable_geo = add_geojson_tooltips(selected_vulnerable_geo, "community")

st.markdown(
    f"""
    <div class="district-heading">
      <div>
        <div class="eyebrow">Congressional district profile</div>
        <h2>{selected_district}: {district_row['NAME']}</h2>
      </div>
      <div class="district-meta">
        Representative&nbsp; <strong>{district_row['candidate']}</strong>&nbsp;
        <span class="party-tag">{str(district_row['party']).title()}</span>
      </div>
    </div>
    """,
    unsafe_allow_html=True,
)

metric_cols = st.columns(5)
metric_cols[0].metric(
    "CWS outside AWIA threshold",
    number(district_row["cws_service_area_count"]),
)
metric_cols[1].metric(
    "Estimated population served",
    number(district_row["estimated_cws_service_population"]),
)
metric_cols[2].metric("Active Water Components", number(district_row["cws_component_count"]))
metric_cols[3].metric(
    "Service-area coverage",
    f"{number(district_row['cws_service_area_sq_km'])} km²",
)
metric_cols[4].metric(
    "Service-area income estimate",
    money(district_row["estimated_service_area_median_household_income"]),
)

# Increase the first number to give the map more horizontal space relative to
# the district context column (for example, [4, 1]).
map_col, context_col = st.columns([3.4, 1], gap="large")

with map_col:
    layers = map_layers(
        selected_communities_geo,
        selected_vulnerable_geo,
        selected_district_geo,
        selected_service_geo,
        selected_systems,
        census_variable,
        show_vulnerable,
    )
    deck = pdk.Deck(
        layers=layers,
        initial_view_state=map_view(selected_district_geo),
        map_style=MAP_STYLE,
        tooltip=MAP_TOOLTIP,
    )
    show_map_legend(census_variable, show_vulnerable, "Congressional District")
    map_event = st.pydeck_chart(
        deck,
        use_container_width=True,
        height=650,
        on_select="rerun",
        selection_mode="single-object",
        key=f"district-map-{selected_district}",
    )
    if census_variable:
        st.caption(
            f"Census block groups are colored by {census_variable.lower()}. "
            "Blue outlines show EPA service areas."
        )
    else:
        st.caption(
            "No Census shading is active. Choose an optional Census variable "
            "in the sidebar; blue outlines show EPA service areas."
        )
    show_selected_map_feature(map_event)

with context_col:
    st.markdown("### About the District")
    st.metric("District population", number(district_row["total_population"]))
    st.metric("District median household income", money(district_row["median_household_income"]))
    st.metric("District poverty rate", percent(district_row["poverty_rate"]))
    st.metric("Rural population share", percent(district_row["district_rural_share"], False))


overview_tab, systems_tab, communities_tab, methods_tab = st.tabs(
    ["Overview", "Water systems", "Communities", "Methods & limitations"]
)

with overview_tab:
    c1, c2, c3 = st.columns(3)
    c1.metric(
        "Estimated households served",
        number(district_row["estimated_cws_service_households"]),
    )
    c2.metric("Systems with unresolved violations", number(
        (selected_systems["unresolved_violation_count"].fillna(0) > 0).sum()
    ))
    c3.metric("Site inspections recorded", number(
        selected_systems["site_inspection_count"].fillna(0).sum()
    ))
    st.markdown(
        "This view connects infrastructure records with the populations inside EPA "
        "service-area estimates. Use the other tabs to inspect individual systems "
        "and the Census block groups they serve."
    )

with systems_tab:
    st.markdown(f"### {len(selected_systems):,} systems intersect this district")
    search = st.text_input("Search system name or PWSID", placeholder="Type a name or identifier")
    system_table = selected_systems.copy()
    if search:
        mask = (
            system_table["pws_name"].fillna("").str.contains(search, case=False, regex=False)
            | system_table["pwsid"].fillna("").str.contains(search, case=False, regex=False)
        )
        system_table = system_table.loc[mask]
    display_columns = {
        "pws_name": "Water system",
        "pwsid": "PWSID",
        "population_served_count": "Population served",
        "primary_source_code": "Source",
        "active_component_count": "Components",
        "violation_count": "Violations",
        "unresolved_violation_count": "Unresolved",
        "health_based_violation_count": "Health-based",
        "site_inspection_count": "Inspections",
    }
    st.dataframe(
        system_table[list(display_columns)].rename(columns=display_columns),
        hide_index=True,
        width="stretch",
        height=410,
    )
    st.download_button(
        "Download district water systems (CSV)",
        system_table.to_csv(index=False).encode("utf-8"),
        file_name=f"{selected_district}_small_cws.csv",
        mime="text/csv",
    )

with communities_tab:
    community_rows = [
        feature.get("properties", {})
        for feature in selected_communities_geo["features"]
        if pd.to_numeric(
            feature.get("properties", {}).get("cws_service_area_count"),
            errors="coerce",
        )
        > 0
    ]
    communities = pd.DataFrame(community_rows)
    if communities.empty:
        st.info("No block-group crosswalk records are available for this district.")
    else:
        st.markdown(f"### {len(communities):,} served Census block groups")
        columns = {
            "NAME": "Community",
            "GEOID": "Block group GEOID",
            "poverty_rate": "Poverty rate (%)",
            "median_household_income": "Median household income",
            "rural_status": "Rural status",
            "cws_service_area_count": "CWS",
            "estimated_cws_service_population": "Estimated population served",
        }
        available = [column for column in columns if column in communities.columns]
        st.dataframe(
            communities[available].rename(columns=columns).sort_values(
                "Poverty rate (%)", ascending=False
            ),
            hide_index=True,
            width="stretch",
            height=410,
        )
        st.download_button(
            "Download district communities (CSV)",
            communities.to_csv(index=False).encode("utf-8"),
            file_name=f"{selected_district}_served_block_groups.csv",
            mime="text/csv",
        )

with methods_tab:
    st.markdown(
        """
        ### How to read this dashboard

        - **Small CWS** means an active community water system in the selected EPA
          primacy jurisdiction serving 3,300 people or fewer.
        - **Service areas** come from EPA's Community Water System Service Areas v3.0.
          Some boundaries are authoritative; others are modeled.
        - **Community estimates** use EPA's building-weighted 2020 Census crosswalk.
          Overlapping systems can describe dual service or boundary uncertainty.
        - **Poverty and income** are 2020–2024 ACS five-year estimates. Block-group
          poverty uses collapsed table C17002.
        - **Administrative points** are geocoded mailing/contact addresses. They are
          optional because they are not necessarily treatment plants, wells, or offices.
        - **Violations and inspections** are distinct historical records retained in
          the current SDWIS quarterly snapshot, not counts limited to a single year.

        This is an exploratory public-information project and should not be used as
        an emergency notification, regulatory determination, or assessment of water safety.
        """
    )

show_footer()
