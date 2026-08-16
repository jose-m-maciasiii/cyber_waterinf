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
            pop_cat_3_code == 1 &
            pws_type_code == "CWS" &
            primacy_agency_code %in% state_list
    ) |>
    mutate(epa_region = as.numeric(epa_region))

# Add system-level summaries from the SDWIS facility, inspection, and
# violation/enforcement files. Counts are historical records retained in the
# current quarterly SDWIS snapshot; distinct identifiers prevent the
# violation/enforcement table's repeated rows from inflating the totals.
sdwa_connection <- DBI::dbConnect(duckdb::duckdb())
duckdb::duckdb_register(
    sdwa_connection,
    "target_cws_ids",
    water_pub |> distinct(pwsid)
)

facility_type_lookup <- read_csv(
    "data/SDWA_latest_downloads/SDWA_REF_CODE_VALUES.csv",
    show_col_types = FALSE
) |>
    clean_names() |>
    filter(value_type == "FACILITY_TYPE_CODE") |>
    transmute(
        facility_type_code = value_code,
        facility_type = str_squish(value_description)
    )

facility_type_counts <- DBI::dbGetQuery(
    sdwa_connection,
    "
    SELECT
        f.PWSID AS pwsid,
        f.FACILITY_TYPE_CODE AS facility_type_code,
        COUNT(DISTINCT f.FACILITY_ID) AS component_count
    FROM read_csv('data/SDWA_latest_downloads/SDWA_FACILITIES.csv',
                  all_varchar = true) f
    INNER JOIN target_cws_ids t ON f.PWSID = t.pwsid
    WHERE f.FACILITY_ACTIVITY_CODE = 'A'
    GROUP BY f.PWSID, f.FACILITY_TYPE_CODE
    "
) |>
    as_tibble() |>
    left_join(facility_type_lookup, by = "facility_type_code") |>
    mutate(
        component_count = as.integer(component_count),
        facility_type = coalesce(
            facility_type,
            facility_type_code,
            "Unknown"
        ),
        facility_type_column = str_c(
            "component_",
            make_clean_names(facility_type, allow_dupes = TRUE),
            "_count"
        )
    )

facility_summary <- facility_type_counts |>
    group_by(pwsid) |>
    summarise(
        active_component_count = sum(component_count),
        active_component_type_count = n_distinct(facility_type_code),
        active_component_types = str_c(
            str_c(facility_type, " (", component_count, ")"),
            collapse = "; "
        ),
        .groups = "drop"
    ) |>
    left_join(
        facility_type_counts |>
            select(pwsid, facility_type_column, component_count) |>
            pivot_wider(
                names_from = facility_type_column,
                values_from = component_count,
                values_fill = 0
            ),
        by = "pwsid",
        relationship = "one-to-one"
    )

site_visit_summary <- DBI::dbGetQuery(
    sdwa_connection,
    "
    SELECT
        v.PWSID AS pwsid,
        COUNT(DISTINCT NULLIF(v.VISIT_ID, '')) AS site_inspection_count,
        MAX(TRY_STRPTIME(v.VISIT_DATE, '%m/%d/%Y'))::DATE AS latest_site_inspection_date
    FROM read_csv('data/SDWA_latest_downloads/SDWA_SITE_VISITS.csv',
                  all_varchar = true) v
    INNER JOIN target_cws_ids t ON v.PWSID = t.pwsid
    GROUP BY v.PWSID
    "
) |>
    as_tibble()

violation_summary <- DBI::dbGetQuery(
    sdwa_connection,
    "
    SELECT
        v.PWSID AS pwsid,
        COUNT(DISTINCT NULLIF(v.VIOLATION_ID, '')) AS violation_count,
        COUNT(DISTINCT NULLIF(v.VIOLATION_ID, '')) FILTER
            (WHERE UPPER(COALESCE(v.VIOLATION_STATUS, '')) <> 'RESOLVED')
            AS unresolved_violation_count,
        COUNT(DISTINCT NULLIF(v.VIOLATION_ID, '')) FILTER
            (WHERE UPPER(COALESCE(v.IS_HEALTH_BASED_IND, '')) = 'Y')
            AS health_based_violation_count,
        COUNT(DISTINCT NULLIF(v.CORRECTIVE_ACTION_ID, ''))
            AS corrective_action_count,
        COUNT(DISTINCT NULLIF(v.ENFORCEMENT_ID, '')) AS enforcement_action_count
    FROM read_csv('data/SDWA_latest_downloads/SDWA_VIOLATIONS_ENFORCEMENT.csv',
                  all_varchar = true) v
    INNER JOIN target_cws_ids t ON v.PWSID = t.pwsid
    GROUP BY v.PWSID
    "
) |>
    as_tibble()

DBI::dbDisconnect(sdwa_connection, shutdown = TRUE)

water_pub <- water_pub |>
    left_join(facility_summary, by = "pwsid", relationship = "one-to-one") |>
    left_join(site_visit_summary, by = "pwsid", relationship = "one-to-one") |>
    left_join(violation_summary, by = "pwsid", relationship = "one-to-one") |>
    mutate(
        across(
            matches("(_count|_count_[a-z_]+)$"),
            ~ replace_na(as.integer(.x), 0L)
        )
    )

glimpse(water_pub)
######################## U.S. Census Section ########################
# Census measures pulled for the water-infrastructure analysis:
# - 2024 ACS 5-year: total population and median household income.
# - 2024 ACS 5-year: civilian labor force, employed population, unemployed
#   population, and the calculated unemployment rate.
# - 2024 ACS 5-year: poverty universe, population below poverty, and the
#   calculated poverty rate.
# - 2024 ACS 5-year: total households in the internet-subscription universe,
#   broadband-subscribed households, and the calculated broadband rate.
# - 2020 Decennial DHC P2: total, urban, and rural population, used to calculate
#   rural population share and a block-group rural-status marker.
# ACS measures are estimates; the derived rates use their corresponding ACS
# universes as denominators. Urban/rural classification is updated decennially.
census_variables <- c(
    total_population = "B01003_001",
    total_households = "B11001_001",
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
        total_households = total_householdsE,
        median_household_income = median_household_incomeE,
        civilian_labor_force = civilian_labor_forceE,
        employed_population = employed_populationE,
        unemployed_population = unemployed_populationE,
        unemployment_rate = 100 * unemployed_population / civilian_labor_force,
        poverty_universe = poverty_universeE,
        population_below_poverty = population_below_povertyE,
        poverty_rate = 100 * population_below_poverty / poverty_universe,
        internet_households = internet_householdsE,
        broadband_households = broadband_householdsE,
        broadband_rate = 100 * broadband_households / internet_households
    ) |>
    select(-ends_with("E"))


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
        total_households = total_householdsE,
        median_household_income = median_household_incomeE,
        civilian_labor_force = civilian_labor_forceE,
        employed_population = employed_populationE,
        unemployed_population = unemployed_populationE,
        unemployment_rate = 100 * unemployed_population / civilian_labor_force,
        poverty_universe = poverty_universeE,
        population_below_poverty = population_below_povertyE,
        poverty_rate = 100 * population_below_poverty / poverty_universe,
        internet_households = internet_householdsE,
        broadband_households = broadband_householdsE,
        broadband_rate = 100 * broadband_households / internet_households
    ) |>
    select(-ends_with("E"))

# Tract-level version of the same ACS measures for the second analysis level.
census_tract <- get_acs(
    geography = "tract",
    variables = census_variables,
    state = state_list,
    year = 2024,
    survey = "acs5",
    output = "wide",
    geometry = TRUE
) |>
    mutate(
        total_population = total_populationE,
        total_households = total_householdsE,
        median_household_income = median_household_incomeE,
        civilian_labor_force = civilian_labor_forceE,
        employed_population = employed_populationE,
        unemployed_population = unemployed_populationE,
        unemployment_rate = 100 * unemployed_population / civilian_labor_force,
        poverty_universe = poverty_universeE,
        population_below_poverty = population_below_povertyE,
        poverty_rate = 100 * population_below_poverty / poverty_universe,
        internet_households = internet_householdsE,
        broadband_households = broadband_householdsE,
        broadband_rate = 100 * broadband_households / internet_households
    ) |>
    select(-ends_with("E"))

# The Census Bureau classifies population at the block level as urban or rural.
# DHC table P2 aggregates those counts to block groups, which may be fully urban,
# fully rural, or contain both urban and rural population.
rural_block_groups <- map_dfr(
    state_list,
    function(state_abbr) {
        get_decennial(
            geography = "block group",
            variables = c(
                decennial_population = "P2_001N",
                urban_population = "P2_002N",
                rural_population = "P2_003N"
            ),
            state = state_abbr,
            year = 2020,
            sumfile = "dhc",
            output = "wide",
            geometry = FALSE
        )
    }
) |>
    mutate(
        rural_share = if_else(
            decennial_population > 0,
            rural_population / decennial_population,
            NA_real_
        ),
        rural_status = case_when(
            decennial_population == 0 ~ "No population",
            rural_share == 1 ~ "Fully rural",
            rural_share >= 0.5 ~ "Majority rural",
            rural_share > 0 ~ "Partly rural",
            rural_share == 0 ~ "Fully urban",
            TRUE ~ NA_character_
        ),
        rural_majority = rural_share >= 0.5
    )

census_block <- census_block |>
    left_join(
        rural_block_groups |> select(-NAME),
        by = "GEOID",
        relationship = "one-to-one"
    )

# Direct tract-level urban/rural counts from the same 2020 DHC P2 table.
rural_tracts <- map_dfr(
    state_list,
    function(state_abbr) {
        get_decennial(
            geography = "tract",
            variables = c(
                decennial_population = "P2_001N",
                urban_population = "P2_002N",
                rural_population = "P2_003N"
            ),
            state = state_abbr,
            year = 2020,
            sumfile = "dhc",
            output = "wide",
            geometry = FALSE
        )
    }
) |>
    mutate(
        rural_share = if_else(
            decennial_population > 0,
            rural_population / decennial_population,
            NA_real_
        ),
        rural_status = case_when(
            decennial_population == 0 ~ "No population",
            rural_share == 1 ~ "Fully rural",
            rural_share >= 0.5 ~ "Majority rural",
            rural_share > 0 ~ "Partly rural",
            rural_share == 0 ~ "Fully urban",
            TRUE ~ NA_character_
        ),
        rural_majority = rural_share >= 0.5
    )

census_tract <- census_tract |>
    left_join(
        rural_tracts |> select(-NAME),
        by = "GEOID",
        relationship = "one-to-one"
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

######################## Congressional District Analysis ########################

# Estimate 2020 rural and urban population for the current congressional
# districts. Block groups that cross a district boundary are allocated by their
# share of overlapping land area. This is an approximation because population
# is not necessarily distributed evenly within a block group.
district_rural_summary <- block_group_district_overlaps |>
    left_join(
        census_block |>
            st_drop_geometry() |>
            select(
                GEOID,
                decennial_population,
                urban_population,
                rural_population
            ),
        by = "GEOID",
        relationship = "many-to-one"
    ) |>
    mutate(
        allocation_share = coalesce(overlap_share, 1),
        allocated_decennial_population = decennial_population *
            allocation_share,
        allocated_urban_population = urban_population * allocation_share,
        allocated_rural_population = rural_population * allocation_share
    ) |>
    group_by(congressional_district) |>
    summarise(
        district_decennial_population = round(
            sum(allocated_decennial_population, na.rm = TRUE)
        ),
        district_urban_population = round(
            sum(allocated_urban_population, na.rm = TRUE)
        ),
        district_rural_population = round(
            sum(allocated_rural_population, na.rm = TRUE)
        ),
        district_rural_share = if_else(
            district_decennial_population > 0,
            district_rural_population / district_decennial_population,
            NA_real_
        ),
        district_rural_status = case_when(
            district_decennial_population == 0 ~ "No population",
            district_rural_share == 1 ~ "Fully rural",
            district_rural_share >= 0.5 ~ "Majority rural",
            district_rural_share > 0 ~ "Partly rural",
            district_rural_share == 0 ~ "Fully urban",
            TRUE ~ NA_character_
        ),
        block_groups_contributing = n_distinct(GEOID),
        .groups = "drop"
    )

target_districts_2024 <- target_districts_2024 |>
    mutate(
        congressional_district = if_else(
            district == 0,
            str_glue("{state_po}-AL"),
            str_glue("{state_po}-{str_pad(district, 2, pad = '0')}")
        )
    ) |>
    left_join(
        district_rural_summary,
        by = "congressional_district",
        relationship = "one-to-one"
    )

########################

# FUNCTION to subset for targeted states

water_state <- function(state, region_input) {
    water_pub |>
        filter(
            primacy_agency_code == state &
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
    method = "osm",
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

    # Reuse every prior cache chunk by address value, even when filtering the
    # source data changes chunk boundaries between runs.
    cache_pattern <- str_glue("_{method}_[0-9]+\\.rds$")
    existing_cache_files <- list.files(
        cache_dir,
        pattern = cache_pattern,
        full.names = TRUE
    )
    existing_geocodes <- map_dfr(
        existing_cache_files,
        readRDS
    ) |>
        select(
            any_of(c(
                "address_line1",
                "city_name",
                "zip_code",
                "state_code",
                "latitude",
                "longitude"
            ))
        ) |>
        filter(!is.na(address_line1)) |>
        distinct(
            address_line1,
            city_name,
            zip_code,
            state_code,
            .keep_all = TRUE
        )

    pending_lookup <- address_lookup |>
        anti_join(
            existing_geocodes,
            by = c("address_line1", "city_name", "zip_code", "state_code")
        )
    chunks <- split(
        pending_lookup,
        ceiling(seq_len(nrow(pending_lookup)) / chunk_size)
    )

    geocode_chunk <- function(chunk, chunk_number) {
        cache_file <- file.path(
            cache_dir,
            str_glue(
                "{str_to_lower(state_label)}_{method}_",
                "{length(existing_cache_files) + chunk_number}.rds"
            )
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

    newly_geocoded <- if (length(chunks) == 0) {
        tibble()
    } else {
        map2_dfr(chunks, seq_along(chunks), geocode_chunk)
    }

    geocoded_lookup <- bind_rows(existing_geocodes, newly_geocoded) |>
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
######################## GEO CODEING ########################
addy_mi_water_pub <- addys_for_water_geocode(mi_water_pub, method = "osm")
addy_mn_water_pub <- addys_for_water_geocode(mn_water_pub, method = "osm")
addy_nj_water_pub <- addys_for_water_geocode(nj_water_pub, method = "osm")
addy_sd_water_pub <- addys_for_water_geocode(sd_water_pub, method = "osm")
addy_ga_water_pub <- addys_for_water_geocode(ga_water_pub, method = "osm")

# Count active community water systems (CWS) whose geocoded address point falls
# within each congressional district. These are administrative address points,
# so the result should not be interpreted as a service-area population count.
cws_water_system_points <- bind_rows(
    addy_mi_water_pub,
    addy_mn_water_pub,
    addy_nj_water_pub,
    addy_sd_water_pub,
    addy_ga_water_pub
) |>
    filter(
        pws_type_code == "CWS",
        is.finite(latitude),
        is.finite(longitude),
        between(latitude, 24, 50),
        between(longitude, -125, -66)
    ) |>
    distinct(pwsid, .keep_all = TRUE) |>
    st_as_sf(
        coords = c("longitude", "latitude"),
        crs = 4326,
        remove = FALSE
    ) |>
    st_transform(st_crs(target_districts_2024))

######################## EPA CWS Service Areas ########################

# Version 3.0 contains one national CWS polygon layer plus 2020 Census
# crosswalks. Restrict it to this study's five states and then to the active
# small CWS universe in `water_pub`. Model/verification fields are retained so
# authoritative and modeled boundaries remain distinguishable downstream.
service_area_path <-
    "data/SDWA_latest_downloads/3_0/Service_Areas_V_3_0.gpkg"

target_service_areas <- st_read(
    service_area_path,
    query = str_glue(
        "SELECT * FROM CWS WHERE substr(PWSID, 1, 2) IN (",
        str_c(str_c("'", state_list, "'"), collapse = ", "),
        ")"
    ),
    quiet = TRUE
) |>
    clean_names() |>
    inner_join(
        water_pub |>
            st_drop_geometry() |>
            select(pwsid),
        by = "pwsid",
        relationship = "many-to-one"
    )

target_service_areas <- target_service_areas |>
    mutate(
        service_area_sq_km = as.numeric(
            st_area(st_transform(target_service_areas, 5070))
        ) /
            1e6
    )

missing_service_area_cws <- read_csv(
    "data/SDWA_latest_downloads/3_0/Missing_CWS_V_3_0.csv",
    show_col_types = FALSE
) |>
    clean_names() |>
    rename(pwsid = pws_id) |>
    semi_join(water_pub, by = "pwsid")

service_area_coverage_summary <- water_pub |>
    summarise(
        target_cws_count = n_distinct(pwsid),
        cws_with_service_area = n_distinct(
            target_service_areas$pwsid
        ),
        cws_without_service_area = target_cws_count - cws_with_service_area,
        service_area_match_rate = cws_with_service_area / target_cws_count
    )

# Audit whether each successfully geocoded SDWIS administrative mailing address
# lies inside the service polygon for that same PWSID. A failure is not evidence
# that the service polygon is wrong: the address can be a billing office or an
# operator's address rather than an infrastructure location.
service_areas_for_address_check <- target_service_areas |>
    select(service_pwsid = pwsid) |>
    st_transform(st_crs(cws_water_system_points))

address_service_area_matches <- cws_water_system_points |>
    mutate(
        containing_service_area_rows = st_intersects(
            geometry,
            service_areas_for_address_check
        ),
        address_within_own_service_area = map2_lgl(
            containing_service_area_rows,
            pwsid,
            ~ any(
                service_areas_for_address_check$service_pwsid[.x] == .y
            )
        ),
        address_within_any_service_area = lengths(
            containing_service_area_rows
        ) >
            0
    ) |>
    select(-containing_service_area_rows)

address_service_area_summary <- address_service_area_matches |>
    st_drop_geometry() |>
    summarise(
        geocoded_address_count = n_distinct(pwsid),
        within_own_service_area_count = sum(address_within_own_service_area),
        within_any_service_area_count = sum(address_within_any_service_area),
        within_own_service_area_rate = mean(address_within_own_service_area)
    )

# EPA's tract crosswalk uses 2020 Census tracts. Pop20_BW is the building-
# weighted population estimate and is preferred to the area-weighted estimate.
# Multiple service polygons can overlap, so retain a gross sum and a capped
# estimate that cannot exceed the tract's 2020 population.
service_area_tract_crosswalk <- read_csv(
    "data/SDWA_latest_downloads/3_0/Census_Tables/Tracts_V_3_0.csv",
    show_col_types = FALSE
) |>
    clean_names() |>
    rename(tract_geoid = geoid20) |>
    semi_join(water_pub, by = "pwsid") |>
    inner_join(
        census_tract |>
            st_drop_geometry() |>
            transmute(
                tract_geoid = GEOID,
                tract_2020_population = decennial_population,
                tract_2024_households = total_households,
                tract_median_household_income = median_household_income
            ),
        by = "tract_geoid",
        relationship = "many-to-one"
    ) |>
    left_join(
        water_pub |>
            select(pwsid, active_component_count),
        by = "pwsid",
        relationship = "many-to-one"
    ) |>
    mutate(
        estimated_households_served_gross = tract_2024_households * bldg_weight
    )

service_area_tract_summary <- service_area_tract_crosswalk |>
    group_by(tract_geoid) |>
    summarise(
        cws_service_area_count = n_distinct(pwsid),
        cws_component_count = sum(
            active_component_count[!duplicated(pwsid)],
            na.rm = TRUE
        ),
        estimated_cws_service_population_gross = sum(pop20_bw, na.rm = TRUE),
        estimated_cws_service_population = pmin(
            estimated_cws_service_population_gross,
            first(tract_2020_population)
        ),
        estimated_cws_service_households_gross = sum(
            estimated_households_served_gross,
            na.rm = TRUE
        ),
        estimated_cws_service_households = pmin(
            estimated_cws_service_households_gross,
            first(tract_2024_households)
        ),
        estimated_service_area_median_household_income = if_else(
            estimated_cws_service_population > 0,
            first(tract_median_household_income),
            NA_real_
        ),
        .groups = "drop"
    )

# Exact polygon intersections provide service-area counts and area within each
# current congressional district. Both summed and dissolved area are retained;
# the dissolved measure avoids double-counting overlapping service polygons.
service_district_intersections <- suppressWarnings(
    st_intersection(
        target_service_areas |>
            select(pwsid) |>
            st_make_valid() |>
            st_transform(5070),
        target_districts_2024 |>
            select(congressional_district) |>
            st_make_valid() |>
            st_transform(5070)
    )
)

service_district_intersections <- service_district_intersections |>
    mutate(
        intersection_area_sq_km = as.numeric(
            st_area(service_district_intersections)
        ) /
            1e6
    ) |>
    filter(intersection_area_sq_km > 1e-6)

district_service_area_geometry_summary <- service_district_intersections |>
    group_by(congressional_district) |>
    summarise(
        cws_service_area_count = n_distinct(pwsid),
        cws_service_area_sq_km_gross = sum(intersection_area_sq_km),
        .groups = "drop"
    )

district_service_area_geometry_summary <-
    district_service_area_geometry_summary |>
    mutate(
        cws_service_area_sq_km = as.numeric(
            st_area(district_service_area_geometry_summary)
        ) /
            1e6
    ) |>
    st_drop_geometry()

district_component_summary <- service_district_intersections |>
    st_drop_geometry() |>
    distinct(congressional_district, pwsid) |>
    left_join(
        water_pub |> select(pwsid, active_component_count),
        by = "pwsid",
        relationship = "many-to-one"
    ) |>
    group_by(congressional_district) |>
    summarise(
        cws_component_count = sum(active_component_count, na.rm = TRUE),
        .groups = "drop"
    )

# Allocate tract crosswalk estimates to districts by the fraction of each tract
# overlapping the district, while requiring the PWS polygon itself to intersect
# that district. This is an estimate because population is not evenly spread
# inside a tract; the EPA building-weighted crosswalk reduces that limitation.
tract_district_overlaps <- suppressWarnings(
    st_intersection(
        census_tract |>
            transmute(
                tract_geoid = GEOID,
                tract_area_sq_m = as.numeric(
                    st_area(st_transform(geometry, 5070))
                )
            ) |>
            st_make_valid() |>
            st_transform(5070),
        target_districts_2024 |>
            select(congressional_district) |>
            st_make_valid() |>
            st_transform(5070)
    )
) |>
    mutate(
        district_tract_share = as.numeric(st_area(geometry)) /
            tract_area_sq_m
    ) |>
    st_drop_geometry() |>
    filter(district_tract_share > 1e-8)

district_service_population_by_tract <- service_area_tract_crosswalk |>
    inner_join(
        tract_district_overlaps,
        by = "tract_geoid",
        relationship = "many-to-many"
    ) |>
    semi_join(
        service_district_intersections |>
            st_drop_geometry() |>
            distinct(congressional_district, pwsid),
        by = c("congressional_district", "pwsid")
    ) |>
    mutate(
        allocated_service_population = pop20_bw * district_tract_share,
        allocated_service_households = estimated_households_served_gross *
            district_tract_share,
        allocated_tract_population = tract_2020_population *
            district_tract_share,
        allocated_tract_households = tract_2024_households *
            district_tract_share
    ) |>
    group_by(congressional_district, tract_geoid) |>
    summarise(
        service_population_gross = sum(
            allocated_service_population,
            na.rm = TRUE
        ),
        service_population = pmin(
            service_population_gross,
            first(allocated_tract_population)
        ),
        service_households_gross = sum(
            allocated_service_households,
            na.rm = TRUE
        ),
        service_households = pmin(
            service_households_gross,
            first(allocated_tract_households)
        ),
        tract_median_household_income = first(
            tract_median_household_income
        ),
        .groups = "drop"
    )

district_service_population_summary <-
    district_service_population_by_tract |>
    group_by(congressional_district) |>
    summarise(
        estimated_cws_service_population_gross = round(
            sum(service_population_gross, na.rm = TRUE)
        ),
        estimated_cws_service_population = round(
            sum(service_population, na.rm = TRUE)
        ),
        estimated_cws_service_households_gross = round(
            sum(service_households_gross, na.rm = TRUE)
        ),
        estimated_cws_service_households = round(
            sum(service_households, na.rm = TRUE)
        ),
        estimated_service_area_median_household_income = weighted.mean(
            tract_median_household_income,
            service_households,
            na.rm = TRUE
        ),
        .groups = "drop"
    )

district_service_summary <- district_service_area_geometry_summary |>
    full_join(
        district_component_summary,
        by = "congressional_district"
    ) |>
    full_join(
        district_service_population_summary,
        by = "congressional_district"
    )

cws_district_membership <- cws_water_system_points |>
    st_join(
        target_districts_2024 |>
            select(congressional_district),
        join = st_within,
        left = TRUE
    )

cws_district_counts <- cws_district_membership |>
    st_drop_geometry() |>
    filter(!is.na(congressional_district)) |>
    count(congressional_district, name = "cws_water_system_count")

unassigned_cws_water_systems <- cws_district_membership |>
    filter(is.na(congressional_district))

target_districts_2024 <- target_districts_2024 |>
    left_join(
        cws_district_counts,
        by = "congressional_district",
        relationship = "one-to-one"
    ) |>
    left_join(
        district_service_summary,
        by = "congressional_district",
        relationship = "one-to-one"
    ) |>
    mutate(
        across(
            c(
                cws_water_system_count,
                cws_service_area_count,
                cws_component_count,
                cws_service_area_sq_km_gross,
                cws_service_area_sq_km,
                estimated_cws_service_population_gross,
                estimated_cws_service_population,
                estimated_cws_service_households_gross,
                estimated_cws_service_households
            ),
            ~ replace_na(.x, 0)
        )
    )

######################## Census Tract Analysis ########################

# Assign each geocoded CWS administrative address to a Census tract and count
# distinct systems. Tracts without a matched CWS receive a count of zero.
cws_tract_membership <- cws_water_system_points |>
    st_transform(st_crs(census_tract)) |>
    st_join(
        census_tract |>
            transmute(tract_geoid = GEOID),
        join = st_within,
        left = TRUE
    )

cws_tract_counts <- cws_tract_membership |>
    st_drop_geometry() |>
    filter(!is.na(tract_geoid)) |>
    distinct(tract_geoid, pwsid) |>
    count(tract_geoid, name = "cws_water_system_count")

unassigned_cws_tracts <- cws_tract_membership |>
    filter(is.na(tract_geoid))

census_tract <- census_tract |>
    left_join(
        cws_tract_counts,
        by = c("GEOID" = "tract_geoid"),
        relationship = "one-to-one"
    ) |>
    left_join(
        service_area_tract_summary,
        by = c("GEOID" = "tract_geoid"),
        relationship = "one-to-one"
    ) |>
    mutate(
        across(
            c(
                cws_water_system_count,
                cws_service_area_count,
                cws_component_count,
                estimated_cws_service_population_gross,
                estimated_cws_service_population,
                estimated_cws_service_households_gross,
                estimated_cws_service_households
            ),
            ~ replace_na(.x, 0)
        )
    )

stopifnot(
    nrow(census_tract) == n_distinct(census_tract$GEOID),
    !anyNA(census_tract$cws_water_system_count),
    !anyNA(census_tract$cws_service_area_count)
)

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
        median_household_income = if_else(
            median_household_income > 0,
            median_household_income,
            NA_real_
        ),
        employed_population,
        unemployment_rate,
        poverty_rate,
        broadband_rate,
        urban_population,
        rural_population,
        rural_share,
        rural_percent = 100 * rural_share,
        rural_status,
        rural_majority,
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

# Combine successfully geocoded systems from all five targeted states and
# convert their longitude/latitude columns to an sf point layer.
water_systems_for_map <- bind_rows(
    addy_mi_water_pub,
    addy_mn_water_pub,
    addy_nj_water_pub,
    addy_sd_water_pub,
    addy_ga_water_pub
) |>
    filter(
        is.finite(latitude),
        is.finite(longitude),
        between(latitude, 24, 50),
        between(longitude, -125, -66)
    ) |>
    distinct(pwsid, .keep_all = TRUE) |>
    st_as_sf(
        coords = c("longitude", "latitude"),
        crs = 4326,
        remove = FALSE
    ) |>
    transmute(
        water_system_id = pwsid,
        water_system_name = pws_name,
        state = state_code,
        population_served = population_served_count,
        address = str_squish(
            str_c(address_line1, city_name, state_code, zip_code, sep = ", ")
        ),
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
        ),
        water_systems = freestile_layer(
            water_systems_for_map,
            min_zoom = 3,
            max_zoom = 14
        )
    ),
    census_tiles_file,
    overwrite = TRUE
)

# PMTiles need a local server that supports HTTP range requests. If port 8080
# is already occupied, run stop_server() or change the port here and below.
serve_tiles(census_tiles_file, port = 8080)

# Previous party-color styling; retained for easy reuse.
# party_colors <- c(
#     "Democrat" = "#2166ac",
#     "Republican" = "#b2182b",
#     "Multiple" = "#762a83",
#     "Other / unassigned" = "#969696"
# )

# Six Fisher-Jenks natural-break classes for median household income. The extra
# class provides more detail among lower-income block groups.
income_colors <- c(
    "#ffffcc",
    "#c7e9b4",
    "#7fcdbb",
    "#41b6c4",
    "#2c7fb8",
    "#253494"
)
income_jenks <- step_jenks(
    column = "median_household_income",
    data_values = block_groups_for_map$median_household_income |>
        discard(is.na),
    n = 6,
    colors = income_colors,
    na_color = "#d9d9d9"
)

census_map <- maplibre(
    # Use a complete token-free style as the map scaffold. The satellite raster
    # added below covers it, while this remains a fallback if imagery fails.
    style = openfreemap_style("dark"),
    bounds = c(-105, 30, -73, 49),
    projection = "mercator"
) |>
    # Token-free Esri World Imagery raster basemap. Attribution is required.
    add_raster_source(
        id = "satellite-source",
        tiles = c(
            paste0(
                "https://server.arcgisonline.com/ArcGIS/rest/services/",
                "World_Imagery/MapServer/tile/{z}/{y}/{x}"
            )
        ),
        tileSize = 256,
        maxzoom = 19,
        attribution = paste(
            "Sources: Esri, Maxar, Earthstar Geographics,",
            "and the GIS User Community"
        )
    ) |>
    add_raster_layer(
        id = "satellite-basemap",
        source = "satellite-source",
        raster_opacity = 1
    ) |>
    add_pmtiles_source(
        id = "census-source",
        url = paste0(
            "http://localhost:8080/",
            basename(census_tiles_file)
        ),
        promote_id = list(
            block_groups = "block_group_id",
            congressional_districts = "district_id",
            water_systems = "water_system_id"
        )
    ) |>
    # Bottom layer: block groups colored by Jenks-classified household income.
    add_fill_layer(
        id = "block-groups-fill",
        source = "census-source",
        source_layer = "block_groups",
        # Previous party-color version:
        # fill_color = match_expr(
        #     column = "party_category",
        #     values = names(party_colors),
        #     stops = unname(party_colors),
        #     default = "#969696"
        # ),
        fill_color = income_jenks$expression,
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
            "%<br><strong>Rural population:</strong> ",
            number_format(get_column("rural_population"), locale = "en"),
            "<br><strong>Rural share:</strong> ",
            number_format(
                get_column("rural_percent"),
                locale = "en",
                maximum_fraction_digits = 1
            ),
            "%<br><strong>Rural status:</strong> ",
            get_column("rural_status")
        ),
        tooltip_style = tooltip_style("light")
    ) |>
    # Top layer: congressional district outlines only. Adding this last keeps
    # the district boundaries above the block-group fills.
    add_line_layer(
        id = "congressional-district-outlines",
        source = "census-source",
        source_layer = "congressional_districts",
        line_color = "white",
        line_width = .5,
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
    # Top point layer: active water systems serving fewer than 3,300 people.
    add_circle_layer(
        id = "water-systems",
        source = "census-source",
        source_layer = "water_systems",
        circle_color = "#de2d26",
        circle_radius = 3,
        circle_opacity = 0.9,
        circle_stroke_color = "#ffffff",
        circle_stroke_width = 1,
        hover_options = list(circle_radius = 7),
        tooltip = concat(
            "<strong>",
            get_column("water_system_name"),
            "</strong><br><strong>PWSID:</strong> ",
            get_column("water_system_id"),
            "<br><strong>State:</strong> ",
            get_column("state"),
            "<br><strong>Population served:</strong> ",
            number_format(get_column("population_served"), locale = "en"),
            "<br><strong>Address:</strong> ",
            get_column("address")
        ),
        tooltip_style = tooltip_style("light")
    ) |>
    # Previous party legend:
    # add_categorical_legend(
    #     legend_title = "2024 House Party Win",
    #     values = names(party_colors),
    #     colors = unname(party_colors),
    #     position = "bottom-left"
    # ) |>
    add_legend(
        legend_title = "Median household income (Jenks)",
        values = get_legend_labels(
            income_jenks,
            format = "currency",
            digits = 0
        ),
        colors = get_legend_colors(income_jenks),
        type = "categorical",
        position = "bottom-left"
    )

census_map

# Stop the local PMTiles server when you are finished with the map:
stop_server()
