from __future__ import annotations

import json
from pathlib import Path
from typing import Any

import pandas as pd
import pydeck as pdk
import streamlit as st


APP_DIR = Path(__file__).resolve().parent
DATA_DIR = APP_DIR / "data"
MAP_STYLE = "https://basemaps.cartocdn.com/gl/positron-gl-style/style.json"


st.set_page_config(
    page_title="Small Water Systems Explorer",
    page_icon="💧",
    layout="wide",
)

st.markdown(
    """
    <style>
      :root { --ink:#17324d; --blue:#1677a6; --aqua:#20a4a9; --sand:#f5f1e8; }
      .stApp { background: #fbfcfd; color: var(--ink); }
      /* Increase this value to let the dashboard use more of a wide screen. */
      .block-container { max-width: 1720px; padding-top: 2rem; padding-bottom: 3rem; }
      .eyebrow { color:#1677a6; font-size:.78rem; font-weight:750; letter-spacing:.13em;
                 text-transform:uppercase; margin-bottom:.35rem; }
      .hero { background:linear-gradient(120deg,#eef8fb 0%,#f8fbfc 58%,#f7f2e8 100%);
              border:1px solid #dce9ee; border-radius:18px; padding:1.35rem 1.5rem;
              margin-bottom:1rem; }
      .hero h1 { color:#12314a; font-size:2.15rem; line-height:1.08; margin:.1rem 0 .55rem; }
      .hero p { color:#496273; max-width:850px; font-size:1.02rem; margin:0; }
      [data-testid="stMetric"] { background:white; border:1px solid #dde7eb;
        border-radius:14px; padding:.8rem 1rem; box-shadow:0 2px 10px rgba(23,50,77,.04); }
      [data-testid="stMetricLabel"] { color:#536b7b; }
      h2, h3 { color:#17324d; }
      .note { color:#617583; font-size:.88rem; }
      .source-box { background:#f5f7f8; border-left:4px solid #20a4a9;
                    padding:.8rem 1rem; border-radius:5px; }
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


def subset_geojson(data: dict[str, Any], district_id: str) -> dict[str, Any]:
    """Keep features assigned to or clipped to the selected district."""
    features = []
    for feature in data.get("features", []):
        value = str(feature.get("properties", {}).get("congressional_district", ""))
        if district_id in [part.strip() for part in value.split("/")]:
            features.append(feature)
    return {"type": "FeatureCollection", "features": features}


def district_feature(data: dict[str, Any], district_id: str) -> dict[str, Any]:
    features = [
        feature
        for feature in data.get("features", [])
        if feature.get("properties", {}).get("congressional_district") == district_id
    ]
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


def add_geojson_tooltips(
    data: dict[str, Any], layer_type: str
) -> dict[str, Any]:
    """Give every pickable GeoJSON layer the same tooltip field names."""
    for feature in data.get("features", []):
        properties = feature.setdefault("properties", {})
        if layer_type == "service_area":
            properties.update(
                tooltip_title=str(properties.get("pws_name") or "Water system"),
                tooltip_line_1=(
                    f"<b>PWSID:</b> {properties.get('pwsid') or 'Not available'}"
                ),
                tooltip_line_2=(
                    "<b>Population served:</b> "
                    f"{number(properties.get('population_served_count'))}"
                ),
                tooltip_line_3=(
                    "<b>Service-area source:</b> "
                    f"{properties.get('symbology_field') or 'Not available'}"
                ),
                tooltip_line_4=(
                    "<b>Model method:</b> "
                    f"{properties.get('model_method') or 'Not available'}"
                ),
            )
        else:
            properties.update(
                tooltip_title=str(properties.get("NAME") or "Census block group"),
                tooltip_line_1=(
                    "<b>Poverty rate:</b> "
                    f"{percent(properties.get('poverty_rate'))}"
                ),
                tooltip_line_2=(
                    "<b>Median household income:</b> "
                    f"{money(properties.get('median_household_income'))}"
                ),
                tooltip_line_3=(
                    "<b>Estimated population served:</b> "
                    f"{number(properties.get('estimated_cws_service_population'))}"
                ),
                tooltip_line_4=(
                    "<b>Rural status:</b> "
                    f"{properties.get('rural_status') or 'Not available'}"
                ),
            )
    return data


try:
    districts = load_csv("district_metrics.csv")
    systems = load_csv("district_water_systems.csv")
    district_geo = load_geojson("congressional_districts.geojson")
    service_geo = load_geojson("cws_service_areas.geojson")
    communities_geo = load_geojson("served_block_groups.geojson")
    vulnerable_geo = load_geojson("vulnerable_block_groups.geojson")
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
      to connect water infrastructure, community conditions, and representation.</p>
    </div>
    """,
    unsafe_allow_html=True,
)


with st.sidebar:
    st.header("Pick a State & Voting District")
    available_states = sorted(districts["state_po"].dropna().unique().tolist())
    selected_state = st.selectbox(
        "State",
        available_states,
        index=None,
        placeholder="Select a state",
    )
    state_rows = districts[districts["state_po"] == selected_state].copy()
    state_rows = state_rows.sort_values("district")
    district_options = state_rows["congressional_district"].tolist()
    selected_district = st.selectbox(
        "Congressional district",
        district_options,
        index=None,
        placeholder=(
            "Select a district" if selected_state else "Select a state first"
        ),
        disabled=selected_state is None,
    )

    if selected_district:
        st.divider()
        st.subheader("Map layers")
        show_service_areas = st.checkbox("CWS service areas", value=True)
        show_communities = st.checkbox("Served block groups", value=True)
        show_vulnerable = st.checkbox("Most vulnerable block groups", value=True)
        show_points = st.checkbox("Geocoded administrative points", value=True)

    st.divider()
    st.caption(
        "Analysis by Jose M. Macias III from Perhipery Analytics. Data is sourced from the U.S. EPA, US.Census Beaur ACS 5-year estimates."
    )


if not selected_state or not selected_district:
    st.info(
        "Start by selecting a state and congressional district from the sidebar. "
        "The map and district profile will appear after both selections are made."
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
    st.stop()


district_row = districts.loc[
    districts["congressional_district"] == selected_district
].iloc[0]
selected_systems = systems.loc[
    systems["congressional_district"] == selected_district
].copy()
selected_systems = selected_systems.drop_duplicates(subset=["pwsid"])

selected_district_geo = district_feature(district_geo, selected_district)
selected_service_geo = subset_geojson(service_geo, selected_district)
selected_communities_geo = subset_geojson(communities_geo, selected_district)
selected_vulnerable_geo = subset_geojson(vulnerable_geo, selected_district)
selected_service_geo = add_geojson_tooltips(selected_service_geo, "service_area")
selected_communities_geo = add_geojson_tooltips(selected_communities_geo, "community")
selected_vulnerable_geo = add_geojson_tooltips(selected_vulnerable_geo, "community")

st.subheader(f"{selected_district}: {district_row['NAME']}")
st.caption(
    f"Representative: {district_row['candidate']} ({str(district_row['party']).title()})"
)

metric_cols = st.columns(5)
metric_cols[0].metric("Small Community Water Systems", number(district_row["cws_service_area_count"]))
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
    layers: list[pdk.Layer] = []
    if show_communities:
        layers.append(
            pdk.Layer(
                "GeoJsonLayer",
                selected_communities_geo,
                id="served-communities",
                pickable=True,
                stroked=True,
                filled=True,
                get_fill_color=(
                    "properties.poverty_rate >= 30 ? [153,27,30,120] : "
                    "properties.poverty_rate >= 20 ? [230,85,13,105] : "
                    "properties.poverty_rate >= 10 ? [253,174,107,90] : [255,237,160,75]"
                ),
                get_line_color=[255, 255, 255, 110],
                line_width_min_pixels=0.4,
            )
        )
    if show_vulnerable:
        layers.append(
            pdk.Layer(
                "GeoJsonLayer",
                selected_vulnerable_geo,
                id="vulnerable-communities",
                pickable=True,
                stroked=True,
                filled=True,
                get_fill_color=[176, 35, 42, 145],
                get_line_color=[108, 15, 24, 225],
                line_width_min_pixels=1.1,
            )
        )
    # PyDeck draws later layers above earlier ones. Keep Census polygons at the
    # bottom, the district outline above them, service areas next, and points
    # at the very top.
    layers.append(
        pdk.Layer(
            "GeoJsonLayer",
            selected_district_geo,
            id="district-outline",
            pickable=False,
            stroked=True,
            filled=False,
            get_line_color=[20, 42, 61, 245],
            line_width_min_pixels=3,
        )
    )
    if show_service_areas:
        layers.append(
            pdk.Layer(
                "GeoJsonLayer",
                selected_service_geo,
                id="service-areas",
                pickable=True,
                stroked=True,
                filled=True,
                get_fill_color=[20, 145, 170, 42],
                get_line_color=[17, 112, 142, 185],
                line_width_min_pixels=1.2,
            )
        )
    if show_points:
        point_data = selected_systems.dropna(
            subset=["latitude", "longitude"]
        ).copy()
        point_data["tooltip_title"] = point_data["pws_name"].fillna("Water system")
        point_data["tooltip_line_1"] = (
            "<b>PWSID:</b> "
            + point_data["pwsid"].fillna("Not available").astype(str)
        )
        point_data["tooltip_line_2"] = point_data["population_served_count"].map(
            lambda value: f"<b>Population served:</b> {number(value)}"
        )
        point_data["tooltip_line_3"] = point_data["active_component_count"].map(
            lambda value: f"<b>Active components:</b> {number(value)}"
        )
        point_data["tooltip_line_4"] = point_data["primary_source_code"].map(
            lambda value: (
                "<b>Primary source:</b> "
                f"{'Not available' if pd.isna(value) else value}"
            )
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
                get_fill_color=[204, 32, 47, 220],
                get_line_color=[255, 255, 255, 240],
                line_width_min_pixels=1,
                pickable=True,
            )
        )

    tooltip = {
        "html": (
            "<b>{tooltip_title}</b><br/>"
            "{tooltip_line_1}<br/>"
            "{tooltip_line_2}<br/>"
            "{tooltip_line_3}<br/>"
            "{tooltip_line_4}"
        ),
        "style": {"backgroundColor": "#17324d", "color": "white"},
    }
    deck = pdk.Deck(
        layers=layers,
        initial_view_state=map_view(selected_district_geo),
        map_style=MAP_STYLE,
        tooltip=tooltip,
    )
    map_event = st.pydeck_chart(
        deck,
        use_container_width=True,
        height=650,
        on_select="rerun",
        selection_mode="single-object",
        key=f"district-map-{selected_district}",
    )
    st.caption(
        "Blue outlines show EPA service areas; shaded Census block groups are "
        "colored by poverty rate; dark red identifies the study's most vulnerable 10%."
    )
    selected_objects = map_event.selection.get("objects", {})
    selected_object = next(
        (
            records[-1]
            for records in selected_objects.values()
            if records
        ),
        None,
    )
    if selected_object:
        selected_properties = selected_object.get("properties", selected_object)
        detail_lines = "<br/>".join(
            str(selected_properties.get(f"tooltip_line_{index}", ""))
            for index in range(1, 5)
            if selected_properties.get(f"tooltip_line_{index}")
        )
        st.markdown(
            "<div class='source-box'><strong>Selected map feature</strong><br/>"
            f"<strong>{selected_properties.get('tooltip_title', 'Map feature')}</strong>"
            f"<br/>{detail_lines}</div>",
            unsafe_allow_html=True,
        )
    else:
        st.caption("Click a service area, block group, or point to keep its details visible.")

with context_col:
    st.markdown("### About the District")
    st.metric("District population", number(district_row["total_population"]))
    st.metric("District median household income", money(district_row["median_household_income"]))
    st.metric("District poverty rate", percent(district_row["poverty_rate"]))
    st.metric("Rural population share", percent(district_row["district_rural_share"], False))
    st.markdown(
        f"""
        <div class="source-box"><strong>What this means</strong><br>
        The service-area figures describe the portions of this district associated
        with active community water systems serving no more than 3,300 people.
        They are not measures of every drinking-water provider in the district.</div>
        """,
        unsafe_allow_html=True,
    )


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
    community_rows = [feature.get("properties", {}) for feature in selected_communities_geo["features"]]
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

st.divider()
st.caption(
    "Sources: U.S. EPA SDWIS, EPA Community Water System Service Areas v3.0, "
    "U.S. Census Bureau ACS 2020–2024 and 2020 DHC, and 2024 U.S. House election returns."
)
