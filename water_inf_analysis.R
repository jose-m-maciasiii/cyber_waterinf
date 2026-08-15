# libraries used
library(tidyverse)
library(tidycensus)
library(tidygeocoder)
library(janitor)
library(sf)

######################## Water Inf Section ########################
# U.S. states targted by iran
state_list <- c("MI", "MN", "NJ", "SD", "GA")
# EPA regions MUST match with state_code MI = 5, MN = 5, NJ = 2, SD =8, GA =4
## read SWDA data
water_faci <- read_csv("data/SDWA_latest_downloads/SDWA_FACILITIES.csv") |>
    clean_names() |>
    filter(facility_activity_code == "A")

water_pub <- read_csv(
    "data/SDWA_latest_downloads/SDWA_PUB_WATER_SYSTEMS.CSV"
) |>
    clean_names() |>
    filter(
        pws_activity_code == "A" &
            pop_cat_3_code == 1
    ) |>
    mutate(epa_region = as.numeric(epa_region))

glimpse(water_pub)
######################## U.S. Census Section ########################
# District context for the water-infrastructure analysis. Named variables give
# the wide ACS output readable column names.
census_variables <- c(
    total_population = "B01003_001",
    median_household_income = "B19013_001",
    civilian_labor_force = "B23025_003",
    employed_population = "B23025_004",
    unemployed_population = "B23025_005",
    poverty_universe = "B17001_001",
    population_below_poverty = "B17001_002",
    internet_households = "B28002_001",
    broadband_households = "B28002_004"
)

census <- get_acs(
    geography = "congressional district",
    variables = census_variables,
    state = state_list,
    year = 2024,
    survey = "acs5",
    output = "wide",
    geometry = TRUE
) |>
    mutate(
        state = str_extract(NAME, "(?<=, )[^,]+$"),
        state_po = state.abb[match(state, state.name)],
        district = if_else(
            str_detect(NAME, fixed("(at Large)")),
            0L,
            as.integer(
                str_extract(
                    str_remove(NAME, fixed("Congressional District ")),
                    "^[0-9]+"
                )
            )
        ),
        total_population = total_populationE,
        median_household_income = median_household_incomeE,
        civilian_labor_force = civilian_labor_forceE,
        employed_population = employed_populationE,
        unemployed_population = unemployed_populationE,
        unemployment_rate = 100 * unemployed_population / civilian_labor_force,
        poverty_rate = 100 * population_below_povertyE / poverty_universeE,
        broadband_households = broadband_householdsE,
        broadband_rate = 100 * broadband_households / internet_householdsE
    )


census_block <- get_acs(
    geography = "block group",
    variables = census_variables,
    state = state_list,
    year = 2024,
    survey = "acs5",
    output = "wide",
    geometry = TRUE
) |>
    mutate(
        total_population = total_populationE,
        median_household_income = median_household_incomeE,
        civilian_labor_force = civilian_labor_forceE,
        employed_population = employed_populationE,
        unemployed_population = unemployed_populationE,
        unemployment_rate = 100 * unemployed_population / civilian_labor_force,
        poverty_rate = 100 * population_below_povertyE / poverty_universeE,
        broadband_households = broadband_householdsE,
        broadband_rate = 100 * broadband_households / internet_householdsE
    )

######################## Election Data Section ########################
elections_2024 <- read_csv("data/U.S. House 1976–2024/1976-2024-house.tab") |>
    filter(year == 2024)

# Some candidates appear on more than one party line (fusion tickets), so
# aggregate their votes before selecting the district winner.
winners_2024 <- elections_2024 |>
    filter(!is.na(candidate)) |>
    group_by(
        year,
        state,
        state_po,
        state_fips,
        district,
        candidate
    ) |>
    summarise(
        party = str_c(sort(unique(na.omit(party))), collapse = " / "),
        candidatevotes = sum(candidatevotes, na.rm = TRUE),
        totalvotes = first(totalvotes),
        .groups = "drop"
    ) |>
    group_by(state_po, district) |>
    slice_max(candidatevotes, n = 1, with_ties = FALSE) |>
    ungroup() |>
    mutate(vote_share = candidatevotes / totalvotes)

# Winners in the states used in this analysis.
target_state_winners_2024 <- winners_2024 |>
    filter(state_po %in% state_list)

# One row per targeted congressional district, combining ACS attributes and
# the certified 2024 election winner. This remains an sf object because the
# Census geometry is retained.
target_districts_2024 <- census |>
    left_join(
        target_state_winners_2024 |>
            select(
                state_po,
                district,
                candidate,
                party,
                candidatevotes,
                totalvotes,
                vote_share
            ),
        by = c("state_po", "district"),
        relationship = "one-to-one"
    )

stopifnot(
    nrow(target_districts_2024) == nrow(target_state_winners_2024),
    !anyNA(target_districts_2024$candidate)
)

# Assign congressional districts to block groups by positive overlap area.
# EPSG:5070 is an equal-area CRS, so overlap shares are meaningful. This avoids
# false matches from polygons that merely touch along a boundary and preserves
# block groups that are split across congressional districts.
block_groups_equal_area <- census_block |>
    select(GEOID) |>
    st_make_valid() |>
    st_transform(5070) |>
    mutate(
        block_state_fips = str_sub(GEOID, 1, 2),
        block_group_area_m2 = as.numeric(st_area(geometry))
    )

districts_equal_area <- target_districts_2024 |>
    transmute(
        district_state_fips = str_sub(GEOID, 1, 2),
        congressional_district = if_else(
            district == 0,
            str_glue("{state_po}-AL"),
            str_glue("{state_po}-{str_pad(district, 2, pad = '0')}")
        ),
        elected_representative = candidate,
        representative_party = party
    ) |>
    st_make_valid() |>
    st_transform(5070)

block_group_district_overlaps <- suppressWarnings(
    st_intersection(block_groups_equal_area, districts_equal_area)
) |>
    mutate(
        overlap_area_m2 = as.numeric(st_area(geometry)),
        overlap_share = overlap_area_m2 / block_group_area_m2,
        assignment_method = "area overlap"
    ) |>
    st_drop_geometry() |>
    # Remove numerical slivers; real split block groups remain represented.
    filter(overlap_area_m2 > 1, overlap_share > 1e-8)

# Water-only, empty, or tiny sliver block-group geometries can have no positive
# polygon overlap. Assign those to the nearest district in the same state and
# label the fallback explicitly rather than leaving their district missing.
unmatched_block_groups <- block_groups_equal_area |>
    filter(!GEOID %in% block_group_district_overlaps$GEOID) |>
    mutate(empty_geometry = st_is_empty(geometry))

unmatched_with_geometry <- unmatched_block_groups |>
    filter(!empty_geometry)

nearest_district_fallback <- map_dfr(
    seq_len(nrow(unmatched_with_geometry)),
    function(i) {
        block_group <- unmatched_with_geometry[i, ]
        state_districts <- districts_equal_area |>
            filter(district_state_fips == block_group$block_state_fips[[1]])
        nearest_district <- st_nearest_feature(block_group, state_districts)

        state_districts[nearest_district, ] |>
            st_drop_geometry() |>
            transmute(
                GEOID = block_group$GEOID[[1]],
                congressional_district,
                elected_representative,
                representative_party,
                overlap_area_m2 = NA_real_,
                overlap_share = NA_real_,
                assignment_method = "nearest same-state district"
            )
    }
)

block_group_district_overlaps <- bind_rows(
    block_group_district_overlaps,
    nearest_district_fallback
) |>
    arrange(GEOID, desc(overlap_share))

block_group_district_attributes <- block_group_district_overlaps |>
    group_by(GEOID) |>
    summarise(
        primary_congressional_district = first(congressional_district),
        primary_representative = first(elected_representative),
        primary_party = first(representative_party),
        district_assignment_method = first(assignment_method),
        district_overlap_count = n_distinct(congressional_district),
        district_assignment = if_else(
            district_overlap_count == 1,
            "single",
            "multiple"
        ),
        district_overlap_details = str_c(
            congressional_district,
            " (",
            if_else(
                assignment_method == "area overlap",
                scales::percent(overlap_share, accuracy = 0.1),
                assignment_method
            ),
            ")",
            collapse = "; "
        ),
        congressional_district = str_c(
            unique(congressional_district),
            collapse = " / "
        ),
        elected_representative = str_c(
            unique(elected_representative),
            collapse = " / "
        ),
        representative_party = str_c(
            unique(representative_party),
            collapse = " / "
        ),
        .groups = "drop"
    )

# One row per Census block group, retaining its original ACS attributes and
# geometry plus congressional district and representative information.
census_block <- census_block |>
    left_join(block_group_district_attributes, by = "GEOID")

# These rows cannot be assigned spatially because the Census response contains
# no polygon for them. Keep them visible for auditing instead of inventing a
# representative. With the current five-state 2024 ACS pull, there are 60.
unassigned_block_groups <- census_block |>
    filter(is.na(congressional_district)) |>
    select(GEOID, NAME, geometry)

if (nrow(unassigned_block_groups) > 0) {
    message(
        nrow(unassigned_block_groups),
        " block groups could not be assigned because their geometry is empty. ",
        "See `unassigned_block_groups`."
    )
}

stopifnot(
    nrow(census_block) == n_distinct(census_block$GEOID),
    !anyNA(
        census_block$congressional_district[!st_is_empty(census_block)]
    )
)

########################

# FUNCTION to subset for targeted states

water_state <- function(state, region_input) {
    water_pub |>
        filter(
            state_code == state &
                epa_region == region_input
        )
}

mi_water_pub <- water_state("MI", 5)
nrow(mi_water_pub)
mn_water_pub <- water_state("MN", 5)
nrow(mn_water_pub)
nj_water_pub <- water_state("NJ", 2)
nrow(nj_water_pub)
sd_water_pub <- water_state("SD", 8)
nrow(sd_water_pub)
ga_water_pub <- water_state("GA", 4)
nrow(ga_water_pub)

glimpse(mi_water_pub)

# Forward geocode facility mailing addresses. The Census batch service is a
# better fit than the public Nominatim/OSM endpoint for thousands of US
# addresses. Results are saved after each chunk so an interrupted run resumes.
addys_for_water_geocode <- function(
    data,
    method = "census",
    chunk_size = 1000,
    retries = 3,
    timeout = 10,
    cache_dir = "data/geocoded"
) {
    input_data <- data |>
        mutate(.input_row = row_number())

    addresses <- input_data |>
        select(
            .input_row,
            pwsid,
            pws_name,
            address_line1,
            city_name,
            zip_code,
            state_code,
            country_code
        ) |>
        mutate(
            across(c(address_line1, city_name, state_code), str_squish),
            zip_code = str_sub(as.character(zip_code), 1, 5)
        )

    address_lookup <- addresses |>
        distinct(address_line1, city_name, zip_code, state_code) |>
        filter(
            !is.na(address_line1),
            address_line1 != "",
            !is.na(city_name),
            city_name != "",
            !is.na(state_code),
            state_code != ""
        ) |>
        arrange(state_code, city_name, address_line1, zip_code) |>
        mutate(.geocode_id = row_number())

    if (nrow(address_lookup) == 0) {
        return(
            input_data |>
                mutate(latitude = NA_real_, longitude = NA_real_) |>
                select(-.input_row)
        )
    }

    dir.create(cache_dir, recursive = TRUE, showWarnings = FALSE)
    state_label <- str_c(
        sort(unique(address_lookup$state_code)),
        collapse = "-"
    )
    chunks <- split(
        address_lookup,
        ceiling(seq_len(nrow(address_lookup)) / chunk_size)
    )

    geocode_chunk <- function(chunk, chunk_number) {
        cache_file <- file.path(
            cache_dir,
            str_glue("{str_to_lower(state_label)}_{method}_{chunk_number}.rds")
        )

        if (file.exists(cache_file)) {
            cached <- readRDS(cache_file)
            address_columns <- c(
                ".geocode_id",
                "address_line1",
                "city_name",
                "zip_code",
                "state_code"
            )
            if (
                identical(
                    cached |> select(all_of(address_columns)),
                    chunk |> select(all_of(address_columns))
                )
            ) {
                return(cached)
            }
        }

        message("Geocoding chunk ", chunk_number, " of ", length(chunks))

        for (attempt in seq_len(retries)) {
            result <- tryCatch(
                {
                    if (method == "census") {
                        chunk |>
                            geocode(
                                street = address_line1,
                                city = city_name,
                                state = state_code,
                                postalcode = zip_code,
                                method = "census",
                                mode = "batch",
                                lat = latitude,
                                long = longitude,
                                timeout = timeout
                            )
                    } else {
                        chunk |>
                            geocode(
                                street = address_line1,
                                city = city_name,
                                state = state_code,
                                postalcode = zip_code,
                                method = method,
                                lat = latitude,
                                long = longitude,
                                min_time = if (method == "osm") 1 else NULL,
                                timeout = timeout
                            )
                    }
                },
                error = identity
            )

            if (!inherits(result, "error")) {
                saveRDS(result, cache_file)
                return(result)
            }

            if (attempt == retries) {
                stop(
                    "Geocoding chunk ",
                    chunk_number,
                    " failed after ",
                    retries,
                    " attempts: ",
                    conditionMessage(result),
                    call. = FALSE
                )
            }
            Sys.sleep(2^attempt)
        }
    }

    geocoded_lookup <- map2_dfr(
        chunks,
        seq_along(chunks),
        geocode_chunk
    ) |>
        select(
            address_line1,
            city_name,
            zip_code,
            state_code,
            latitude,
            longitude
        )

    coordinates <- addresses |>
        left_join(
            geocoded_lookup,
            by = c("address_line1", "city_name", "zip_code", "state_code")
        ) |>
        select(.input_row, latitude, longitude)

    input_data |>
        left_join(coordinates, by = ".input_row") |>
        arrange(.input_row) |>
        select(-.input_row)
}

addy_mi_water_pub <- addys_for_water_geocode(mi_water_pub)
addy_mn_water_pub <- addys_for_water_geocode(mn_water_pub)
addy_nj_water_pub <- addys_for_water_geocode(nj_water_pub)
addy_sd_water_pub <- addys_for_water_geocode(sd_water_pub)

######################## Visualize Census ########################

library(freestiler)
library(mapgl)

# Prepare compact, tile-friendly versions of both spatial layers. Block groups
# spanning more than one district are shown as "Multiple" regardless of party.
block_groups_for_map <- census_block |>
    filter(!st_is_empty(geometry)) |>
    transmute(
        block_group_id = GEOID,
        block_group_name = NAME,
        party_category = case_when(
            district_overlap_count > 1 ~ "Multiple",
            str_detect(
                representative_party,
                fixed("REPUBLICAN")
            ) ~ "Republican",
            str_detect(representative_party, fixed("DEMOCRAT")) ~ "Democrat",
            TRUE ~ "Other / unassigned"
        ),
        congressional_district,
        elected_representative,
        representative_party,
        total_population,
        median_household_income,
        employed_population,
        unemployment_rate,
        poverty_rate,
        broadband_rate,
        geometry
    )

districts_for_map <- target_districts_2024 |>
    transmute(
        district_id = if_else(
            district == 0,
            str_glue("{state_po}-AL"),
            str_glue("{state_po}-{str_pad(district, 2, pad = '0')}")
        ),
        district_name = NAME,
        elected_representative = candidate,
        representative_party = party,
        geometry
    )

# Store both layers in one PMTiles archive so the map does not embed tens of
# thousands of block-group polygons in the HTML widget.
dir.create("data/tiles", recursive = TRUE, showWarnings = FALSE)
census_tiles_file <- "data/tiles/census_block_groups_and_districts.pmtiles"

freestile(
    list(
        block_groups = freestile_layer(
            block_groups_for_map,
            min_zoom = 3,
            max_zoom = 12
        ),
        congressional_districts = freestile_layer(
            districts_for_map,
            min_zoom = 3,
            max_zoom = 12
        )
    ),
    census_tiles_file,
    overwrite = TRUE
)

# PMTiles need a local server that supports HTTP range requests. If port 8080
# is already occupied, run stop_server() or change the port here and below.
serve_tiles(census_tiles_file, port = 8080)

party_colors <- c(
    "Democrat" = "#2166ac",
    "Republican" = "#b2182b",
    "Multiple" = "#762a83",
    "Other / unassigned" = "#969696"
)

census_map <- maplibre(
    style = openfreemap_style("positron"),
    bounds = c(-105, 30, -73, 49),
    projection = "mercator"
) |>
    add_pmtiles_source(
        id = "census-source",
        url = paste0(
            "http://localhost:8080/",
            basename(census_tiles_file)
        ),
        promote_id = list(
            block_groups = "block_group_id",
            congressional_districts = "district_id"
        )
    ) |>
    # Bottom layer: block groups colored by the assigned representative party.
    add_fill_layer(
        id = "block-groups-fill",
        source = "census-source",
        source_layer = "block_groups",
        fill_color = match_expr(
            column = "party_category",
            values = names(party_colors),
            stops = unname(party_colors),
            default = "#969696"
        ),
        fill_opacity = 0.62,
        fill_outline_color = "rgba(255, 255, 255, 0.25)",
        hover_options = list(fill_opacity = 0.9),
        tooltip = concat(
            "<strong>",
            get_column("block_group_name"),
            "</strong><br><strong>District:</strong> ",
            get_column("congressional_district"),
            "<br><strong>Representative:</strong> ",
            get_column("elected_representative"),
            "<br><strong>Party:</strong> ",
            get_column("representative_party"),
            "<br><strong>Population:</strong> ",
            number_format(get_column("total_population"), locale = "en"),
            "<br><strong>Median household income:</strong> $",
            number_format(
                get_column("median_household_income"),
                locale = "en"
            ),
            "<br><strong>Employed residents:</strong> ",
            number_format(get_column("employed_population"), locale = "en"),
            "<br><strong>Unemployment:</strong> ",
            number_format(
                get_column("unemployment_rate"),
                locale = "en",
                maximum_fraction_digits = 1
            ),
            "%<br><strong>Poverty:</strong> ",
            number_format(
                get_column("poverty_rate"),
                locale = "en",
                maximum_fraction_digits = 1
            ),
            "%<br><strong>Broadband:</strong> ",
            number_format(
                get_column("broadband_rate"),
                locale = "en",
                maximum_fraction_digits = 1
            ),
            "%"
        ),
        tooltip_style = tooltip_style("light")
    ) |>
    # Top layer: congressional district outlines only. Adding this last keeps
    # the district boundaries above the block-group fills.
    add_line_layer(
        id = "congressional-district-outlines",
        source = "census-source",
        source_layer = "congressional_districts",
        line_color = "#111111",
        line_width = 2.25,
        line_opacity = 0.95,
        hover_options = list(line_width = 4),
        tooltip = concat(
            "<strong>",
            get_column("district_name"),
            "</strong><br><strong>Representative:</strong> ",
            get_column("elected_representative"),
            "<br><strong>Party:</strong> ",
            get_column("representative_party")
        ),
        tooltip_style = tooltip_style("dark")
    ) |>
    add_categorical_legend(
        legend_title = "2024 House Party Win",
        values = names(party_colors),
        colors = unname(party_colors),
        position = "bottom-left"
    )

census_map

# Stop the local PMTiles server when you are finished with the map:
stop_server()
