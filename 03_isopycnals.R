remotes::install_github("calcofi/calcofi4r", force = T)
library(calcofi4r)
con <- cc_get_db(supplemental = TRUE) # v2026.11.12, with obs_ctd_full

scb <- c(
  "093.3 026.7",
  "093.3 028.0",
  "093.3 030.0",
  "090.0 028.0",
  "090.0 030.0",
  "086.7 033.0",
  "086.7 035.0"
)

# 1. bottle (1949-2021) + CTD (1993-) in 10 m bins, each against its own baseline
b <- cc_bin_anomaly(con, site_key = scb, depth_max = 200, season = TRUE)
l <- cc_layer_mean(b, top = 0, bottom = 40) # 0-50 m, one row per cast

# other variables: name each dataset's type
b_o2 <- cc_bin_anomaly(
  con,
  c(
    calcofi_bottle = "oxygen_ml_l",
    "calcofi_ctd-cast" = "oxygen_ml_l_ave_sta_corr"
  ),
  site_key = scb,
  season = TRUE
)

# 2. isopycnals at 1 m: depth, T, S, O2 and nitrate on each surface, and their anomalies
iso <- cc_isopycnal_anomaly(
  con,
  site_key = scb,
  season = TRUE,
  cruise_key = c("1997-09-32NM", "2015-11-32OC", "2026-11-33P4")
)
