library(tidyverse)
library(tidycensus)
library(tidygeocoder)
library(janitor)
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
# read in census data
df <- load_variables(2024, "acs5")

census <- get_acs(
    geography = "congressional district",
    variables = "B19013_001",
    state = state_list,
    geometry = T
)

# tabulations

# number of active public water systems service less than 3,300 people
water_pub |>
    distinct(pwsid) |>
    nrow()

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

# reverse geocode, done

library(tidygeocoder)

addy_mi_water_pub <- mi_water_pub |>
    select(address_line1, city_name, zip_code, state_code, country_code) |>
    geocode(address_line1, method = 'osm', lat = latitude, long = longitude)

addy_sd_water_pub <- sd_water_pub |>
    select(address_line1, city_name, zip_code, state_code, country_code) |>
    geocode(address_line1, method = 'osm', lat = latitude, long = longitude)
