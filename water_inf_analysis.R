library(tidyverse)
library(tidycensus)
library(janitor)
## read data

water_faci <- read_csv("data/SDWA_latest_downloads/SDWA_FACILITIES.csv") |>
    clean_names() |>
    filter(facility_activity_code == "")

water_faci <- read_csv("data/SDWA_latest_downloads/SDWA_FACILITIES.csv") |>
    clean_names()

glimpse(water_faci)
