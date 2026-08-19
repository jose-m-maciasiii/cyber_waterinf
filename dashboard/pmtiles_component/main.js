import * as maplibregl from "https://unpkg.com/maplibre-gl@6.0.0/dist/maplibre-gl.mjs";

let map = null;
let protocolRegistered = false;
let selectedHighlight = null;
let fatalErrorReported = false;

const sendMessage = (type, extra = {}) => {
  window.parent.postMessage({ isStreamlitMessage: true, type, ...extra }, "*");
};

const setFrameHeight = (height) => {
  sendMessage("streamlit:setFrameHeight", { height });
};

const setComponentValue = (value) => {
  sendMessage("streamlit:setComponentValue", { value, dataType: "json" });
};

const reportFatalError = (error) => {
  if (fatalErrorReported) return;
  fatalErrorReported = true;
  const message = error?.message || String(error || "PMTiles could not be loaded");
  setComponentValue({ error: message, selected_at: Date.now() });
};

const escapeHtml = (value) => String(value).replace(/[&<>'"]/g, (character) => ({
  "&": "&amp;", "<": "&lt;", ">": "&gt;", "'": "&#39;", '"': "&quot;",
})[character]);

const validNumber = (value) => value !== undefined && value !== null &&
  value !== "" && Number.isFinite(Number(value));
const formatNumber = (value) => validNumber(value)
  ? Math.round(Number(value)).toLocaleString() : null;
const formatMoney = (value) => validNumber(value)
  ? `$${Math.round(Number(value)).toLocaleString()}` : null;
const formatPercent = (value) => validNumber(value)
  ? `${Number(value).toFixed(1)}%` : null;

const featurePresentation = (feature) => {
  const properties = feature.properties || {};
  const title = properties.tooltip_title || properties.pws_name ||
    properties.NAME || properties.name || properties.county_name || "Map feature";
  let labels = [
    ["PWSID", properties.pwsid],
    ["Population served", formatNumber(properties.population_served_count)],
    ["Active components", formatNumber(properties.active_component_count)],
    ["Primary source", properties.primary_source_code],
    ["County", properties.county_name],
    ["Congressional district", properties.congressional_district],
    ["Representative", properties.elected_representative],
    ["Party", properties.representative_party],
    ["Poverty rate", formatPercent(properties.poverty_rate)],
    ["Median household income", formatMoney(properties.median_household_income)],
    ["Estimated population served", formatNumber(properties.estimated_cws_service_population)],
    ["Rural status", properties.rural_status],
  ].filter((item) => item[1] !== undefined && item[1] !== null && item[1] !== "");
  if (!labels.length) {
    labels = [1, 2, 3, 4].map((index) => [
      properties[`tooltip_label_${index}`], properties[`tooltip_value_${index}`],
    ]).filter((item) => item[0] && item[1] !== undefined && item[1] !== null && item[1] !== "");
  }
  return { title, labels };
};

const popupHtml = ({ title, labels }) => {
  const details = labels.map(([label, value]) =>
    `<b>${escapeHtml(label)}:</b> ${escapeHtml(value)}`
  ).join("<br>");
  return `<b>${escapeHtml(title)}</b>${details ? `<br>${details}` : ""}`;
};

const componentPayload = (feature) => {
  const { title, labels } = featurePresentation(feature);
  const properties = { tooltip_title: title };
  labels.slice(0, 12).forEach(([label, value], index) => {
    properties[`tooltip_label_${index + 1}`] = label;
    properties[`tooltip_value_${index + 1}`] = String(value);
  });
  return {
    properties,
    source_layer: feature.sourceLayer || null,
    highlight: selectedHighlight,
    selected_at: Date.now(),
  };
};

const addDiamondPattern = (activeMap) => {
  const canvas = document.createElement("canvas");
  canvas.width = 18;
  canvas.height = 18;
  const context = canvas.getContext("2d");
  context.strokeStyle = "rgba(17,17,17,.82)";
  context.lineWidth = 1.6;
  context.beginPath();
  context.moveTo(9, 2);
  context.lineTo(16, 9);
  context.lineTo(9, 16);
  context.lineTo(2, 9);
  context.closePath();
  context.stroke();
  activeMap.addImage("vulnerable-diamonds", context.getImageData(0, 0, 18, 18), {
    pixelRatio: 2,
  });
  activeMap.setPaintProperty("vulnerable-fill", "fill-pattern", "vulnerable-diamonds");
};

const removeSelectionLayers = () => {
  ["selected-feature", "selected-halo"].forEach((layerId) => {
    if (map?.getLayer(layerId)) map.removeLayer(layerId);
  });
};

const applySelectionHighlight = () => {
  removeSelectionLayers();
  if (!selectedHighlight || !map?.getSource("water")) return;
  const { sourceLayer, property, value, geometryType } = selectedHighlight;
  const filter = ["==", ["to-string", ["get", property]], String(value)];
  if (geometryType === "Point") {
    map.addLayer({ id: "selected-halo", type: "circle", source: "water",
      "source-layer": sourceLayer, filter,
      paint: { "circle-radius": 9, "circle-color": "#111827" } });
    map.addLayer({ id: "selected-feature", type: "circle", source: "water",
      "source-layer": sourceLayer, filter,
      paint: { "circle-radius": 6.5, "circle-color": "#facc15",
        "circle-stroke-color": "#fff7cc", "circle-stroke-width": 1 } });
  } else {
    map.addLayer({ id: "selected-halo", type: "line", source: "water",
      "source-layer": sourceLayer, filter,
      paint: { "line-color": "rgba(17,24,39,.9)", "line-width": 7 } });
    map.addLayer({ id: "selected-feature", type: "line", source: "water",
      "source-layer": sourceLayer, filter,
      paint: { "line-color": "#facc15", "line-width": 4 } });
  }
};

const rememberSelection = (feature) => {
  const properties = feature.properties || {};
  const property = properties.GEOID !== undefined ? "GEOID" :
    (properties.pwsid !== undefined ? "pwsid" : null);
  if (!property || !feature.sourceLayer) return;
  selectedHighlight = {
    sourceLayer: feature.sourceLayer,
    property,
    value: properties[property],
    geometryType: feature.geometry?.type || "Polygon",
  };
  applySelectionHighlight();
};

const renderMap = (args) => {
  const status = document.getElementById("status");
  const height = Number(args.height) || 650;
  document.documentElement.style.height = `${height}px`;
  document.body.style.height = `${height}px`;
  setFrameHeight(height);

  if (map) map.remove();
  document.getElementById("map").replaceChildren();
  status.textContent = "Loading map…";
  status.className = "";

  const cfg = args.config;
  if (cfg.selectedHighlight) selectedHighlight = cfg.selectedHighlight;
  fatalErrorReported = false;
  const style = structuredClone(cfg.style);
  if (!protocolRegistered) {
    maplibregl.addProtocol("pmtiles", new pmtiles.Protocol().tile);
    protocolRegistered = true;
  }
  style.sources.water = cfg.tileTemplate
    ? { type: "vector", tiles: [cfg.tileTemplate], minzoom: 0, maxzoom: 14 }
    : { type: "vector", url: `pmtiles://${cfg.url}` };

  if (cfg.censusColor) {
    style.layers.push({ id: "census-fill", type: "fill", source: "water",
      "source-layer": "all_block_groups", filter: cfg.filter,
      paint: { "fill-color": cfg.censusColor, "fill-outline-color": "rgba(255,255,255,.55)" } });
  }
  if (cfg.showVulnerable) {
    style.layers.push({ id: "vulnerable-fill", type: "fill", source: "water",
      "source-layer": "vulnerable_block_groups", filter: cfg.filter,
      paint: { "fill-color": "rgba(0,0,0,0)", "fill-outline-color": "#111111" } });
  }
  style.layers.push({ id: "service", type: "fill", source: "water",
    "source-layer": cfg.serviceLayer, filter: cfg.filter,
    paint: { "fill-color": "rgba(20,145,170,.28)", "fill-outline-color": "#11708e" } });
  style.layers.push({ id: "boundary", type: "line", source: "water",
    "source-layer": cfg.boundaryLayer, filter: cfg.filter,
    paint: { "line-color": "#142a3d", "line-width": 3.5 } });
  style.layers.push({ id: "admin-points", type: "circle", source: "water",
    "source-layer": "administrative_points", filter: cfg.filter,
    paint: { "circle-radius": ["interpolate", ["linear"], ["zoom"], 3, 1.75, 7, 3, 12, 4.5],
      "circle-color": "#095b6c", "circle-stroke-color": "#0f191e", "circle-stroke-width": 1.3 } });

  map = new maplibregl.Map({ container: "map", style, center: cfg.center, zoom: cfg.zoom });
  window.pmtilesMap = map;
  map.addControl(new maplibregl.NavigationControl(), "top-right");
  // Match the visual stack: points and service areas sit above Census layers.
  const priority = ["admin-points", "service", "vulnerable-fill", "census-fill"];
  const featureAt = (point) => {
    for (const layerId of priority) {
      if (!map.getLayer(layerId)) continue;
      const features = map.queryRenderedFeatures(point, { layers: [layerId] });
      if (features.length) return features[0];
    }
    return null;
  };
  const hoverPopup = new maplibregl.Popup({ closeButton: false, closeOnClick: false, offset: 10 });

  map.on("load", () => {
    status.style.display = "none";
    if (cfg.showVulnerable) addDiamondPattern(map);
    const firstLayer = cfg.censusColor ? "census-fill" :
      (cfg.showVulnerable ? "vulnerable-fill" : "service");
    map.addSource("carto-positron", { type: "raster",
      tiles: ["https://a.basemaps.cartocdn.com/light_all/{z}/{x}/{y}.png"],
      tileSize: 256, attribution: "© OpenStreetMap contributors © CARTO" });
    map.addLayer({ id: "carto-positron", type: "raster", source: "carto-positron" }, firstLayer);
    applySelectionHighlight();
    map.resize();
  });
  map.on("click", (event) => {
    const feature = featureAt(event.point);
    if (feature) {
      rememberSelection(feature);
      setComponentValue(componentPayload(feature));
    }
  });
  map.on("mousemove", (event) => {
    const feature = featureAt(event.point);
    map.getCanvas().style.cursor = feature ? "pointer" : "";
    if (!feature) return hoverPopup.remove();
    hoverPopup.setLngLat(event.lngLat).setHTML(popupHtml(featurePresentation(feature))).addTo(map);
  });
  map.on("mouseout", () => hoverPopup.remove());
  map.on("error", (event) => {
    if (!event.error) return;
    status.style.display = "block";
    status.textContent = `Map error: ${event.error.message || event.error}`;
    status.className = "error";
    const message = String(event.error.message || event.error).toLowerCase();
    if (event.sourceId === "water" || message.includes("pmtiles")) {
      reportFatalError(event.error);
    }
  });
};

window.addEventListener("message", (event) => {
  if (event.data?.type !== "streamlit:render") return;
  try {
    renderMap(event.data.args);
  } catch (error) {
    const status = document.getElementById("status");
    status.textContent = `Map error: ${error.message || error}`;
    status.className = "error";
    reportFatalError(error);
  }
});

sendMessage("streamlit:componentReady", { apiVersion: 1 });
