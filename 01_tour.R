# CalCOFI.io database tour: R walkthrough (2026-11-12)
#
# run one section at a time in Positron (Cmd+Enter runs the line or selection; the
# outline at right lists the sections). Everything reads the public release over
# https: nothing to download, no login. Tables are views over remote parquet, so
# the first query of a table fetches it and later ones hit the local cache.
#
# sections marked [live] are the ones shown in the tour (about 6 minutes);
# the rest are take-home: each runs on its own after sections 0 and 1.

# 0. setup ----
librarian::shelf(
  calcofi/calcofi4r, DBI, dplyr, tidyr, ggplot2, arrow, connections, glue, tibble,
  quiet = T)

VERSION  <- "v2026.11.09"  # pinned: the same rows tomorrow, next year, on your machine
dir_data <- "data"         # small outputs to open in Positron's Data Explorer
dir.create(dir_data, showWarnings = F)

# 1. connect to the release [live] ----
con <- cc_get_db(VERSION)            # cc_get_db() alone gives the newest release
qry <- function(sql) as_tibble(dbGetQuery(con, sql))   # one connection for every query below
dbListTables(con)

# show it in Positron's Connections pane: expand a table to see its columns
if (interactive())
  connections::connection_view(con, connection_code = 'con <- calcofi4r::cc_get_db("v2026.11.09")')

cc_list_versions() |> head()         # every release, newest first, with its DOI

# 2. the core family: what one row means [live] ----
# sample:             where and when something was sampled (cast, bottle, net tow, ...)
# obs_env / obs_bio:  one value at one depth of a sample (environment / organisms)
# sample_measurement: one value for a whole sample (per-cast or per-tow)
# climatology:        the 1993-2013 baseline every anomaly subtracts
cc_describe_table("sample", con = con)

qry("
  SELECT dataset_key, sample_type, count(*) AS n
  FROM sample GROUP BY ALL ORDER BY dataset_key, sample_type")

# 3. the keys that join datasets: one station visit [live] ----
# a station visit is cruise_key + order_occ: the bottles, the CTD cast, the DIC
# samples and the net tows of that visit share it, whatever dataset they come from
visit <- qry("
  SELECT cruise_key, order_occ, any_value(site_key) AS site_key,
         count(DISTINCT dataset_key) AS n_datasets,
         string_agg(DISTINCT dataset_key, ', ' ORDER BY dataset_key) AS datasets
  FROM sample
  WHERE order_occ IS NOT NULL AND datetime BETWEEN '2015-01-01' AND '2020-12-31'
  GROUP BY 1, 2
  ORDER BY n_datasets DESC, cruise_key DESC, order_occ
  LIMIT 1")
visit

qry(glue("
  SELECT dataset_key, sample_type, count(*) AS n_samples,
         min(depth_min_m) AS depth_min, max(depth_max_m) AS depth_max
  FROM sample
  WHERE cruise_key = '{visit$cruise_key}' AND order_occ = {visit$order_occ}
  GROUP BY ALL ORDER BY dataset_key, sample_type"))

# a bottle points to its cast with root_sample_key (parent_sample_key for one level up)
qry(glue("
  SELECT b.sample_key AS bottle, b.depth_min_m, c.sample_key AS its_cast, c.seafloor_depth_m
  FROM sample b JOIN sample c ON c.sample_key = b.root_sample_key
  WHERE b.dataset_key = 'calcofi_bottle' AND b.sample_type = 'bottle'
    AND b.cruise_key = '{visit$cruise_key}' AND b.order_occ = {visit$order_occ}
  ORDER BY b.depth_min_m LIMIT 5"))

# 4. per depth vs per cast [live] ----
# spiciness is one value at each depth (obs_env); mixed-layer depth and integrated
# chlorophyll are one value per cast (sample_measurement), so they have no depth
qry("
  SELECT 'obs_env' AS tbl, dataset_key, measurement_type, count(*) AS n
  FROM obs_env WHERE dataset_key IN ('calcofi_ctd-derived', 'calcofi_bottle-derived')
  GROUP BY ALL
  UNION ALL
  SELECT 'sample_measurement', dataset_key, measurement_type, count(*)
  FROM sample_measurement WHERE dataset_key IN ('calcofi_ctd-derived', 'calcofi_bottle-derived')
  GROUP BY ALL
  ORDER BY tbl, dataset_key, measurement_type")

# 5. quality flags ----
# measurement_qual is each provider's own code; qual_ok is the verdict every app applies
qry("
  SELECT dataset_key, count(*) AS n, count(*) FILTER (WHERE NOT qual_ok) AS n_flagged
  FROM obs_env GROUP BY 1 ORDER BY n_flagged DESC")
cc_qual_ok_sql("o")                  # the same rule as a predicate, for sample_measurement

# 6. derived products: legacy beside modern ----
# bottle-derived values sit on the bottle's own sample_key, so the legacy DECODR
# sigma-theta and the TEOS-10 one join directly
d_sig <- qry("
  SELECT b.sample_key, b.datetime, b.depth_min_m AS depth_m,
         b.value AS sigma_theta_legacy, d.value AS sigma_theta_teos10,
         d.value - b.value AS diff
  FROM obs_env b
  JOIN obs_env d USING (sample_key)
  WHERE b.dataset_key = 'calcofi_bottle'         AND b.measurement_type = 'sigma_theta'
    AND d.dataset_key = 'calcofi_bottle-derived' AND d.measurement_type = 'sigma_theta_teos10'")
d_sig |>
  summarize(n = n(), median_abs_diff = median(abs(diff)), p99_abs_diff = quantile(abs(diff), 0.99))

# 7. Nastassia's table: bottles + their CTD cast's derived values, wide [live] ----
bottle_types  <- c("temperature", "salinity", "chlorophyll_a", "nitrate", "nitrite", "oxygen_ml_l")
derived_types <- c("mld_temperature_02", "mld_sigma_theta_0125", "chl_max", "chl_max_depth",
                   "chl_integrated", "pycnocline_depth", "nitracline_depth", "hypoxic_depth_14")
wide_sql <- function(types, tbl, col)
  paste(glue("max({tbl}.{col}) FILTER (WHERE {tbl}.measurement_type = '{types}') AS {types}"),
        collapse = ",\n    ")
in_sql <- function(x) paste0("('", paste(x, collapse = "', '"), "')")

d_btl <- qry(glue("
  WITH btl AS (                                  -- one row per bottle
    SELECT c.cruise_key, c.order_occ, c.site_key, c.datetime, c.latitude, c.longitude,
           c.seafloor_depth_m, e.sample_key, e.depth_min_m AS depth_m,
    {wide_sql(bottle_types, 'e', 'value')}
    FROM obs_env e
    JOIN sample b ON b.sample_key = e.sample_key          -- the bottle
    JOIN sample c ON c.sample_key = b.root_sample_key     -- its cast
    WHERE e.dataset_key = 'calcofi_bottle' AND e.measurement_type IN {in_sql(bottle_types)}
      AND e.datetime BETWEEN '1996-04-01' AND '2021-12-31' AND e.qual_ok
    GROUP BY ALL),
  spice AS (                                     -- TEOS-10 spiciness at each bottle
    SELECT sample_key, value AS spiciness0
    FROM obs_env WHERE dataset_key = 'calcofi_bottle-derived' AND measurement_type = 'spiciness0'),
  ctd AS (                                       -- one row per CTD cast
    SELECT s.cruise_key, s.order_occ, s.sample_key AS ctd_cast,
    {wide_sql(derived_types, 'm', 'measurement_value')}
    FROM sample_measurement m JOIN sample s ON s.sample_key = m.sample_key
    WHERE m.dataset_key = 'calcofi_ctd-derived'
    GROUP BY s.cruise_key, s.order_occ, s.sample_key     -- QUALIFY needs explicit columns
    QUALIFY row_number() OVER (PARTITION BY s.cruise_key, s.order_occ ORDER BY s.sample_key) = 1)
  SELECT btl.*, spice.spiciness0, ctd.* EXCLUDE (cruise_key, order_occ)
  FROM btl
  LEFT JOIN spice USING (sample_key)
  LEFT JOIN ctd   USING (cruise_key, order_occ)                 -- the same station visit
  ORDER BY datetime, depth_m"))
dim(d_btl)

f_btl <- file.path(dir_data, "bottle_plus_derived_1996-2021.parquet")
arrow::write_parquet(d_btl, f_btl)
# open it: Files pane > data > the .parquet (or View() below) for Positron's Data Explorer
if (interactive()) View(d_btl)

# 8. after May 2021: the bottle database stops, the CTD cast files carry on [live] ----
# "I can't pull bottle data past 2021": the Bottle Database's last cruise is 2105. The CTD
# Cast Files run to the newest cruise and carry the rosette's bottle values (btl_*) beside
# the sensor series. The names differ, because a CTD has two sensors of each kind:
names_btl_ctd <- tribble(
  ~quantity,     ~bottle,         ~ctd_bottle_value,   ~ctd_sensor,
  "temperature", "temperature",   "btl_temperature",   "temperature_ave",
  "salinity",    "salinity",      "salinity_btl",      "salinity_ave_corr",
  "oxygen",      "oxygen_ml_l",   "oxygen_btl_ml_l",   "oxygen_ml_l_ave_sta_corr",
  "chlorophyll", "chlorophyll_a", "btl_chlorophyll_a", "est_chlorophyll_a_sta_corr",
  "nitrate",     "nitrate",       "btl_nitrate",       "est_nitrate_sta_corr")
names_btl_ctd

qry(glue("
  SELECT dataset_key, measurement_type, any_value(units) AS units,
         min(datetime)::DATE AS first, max(datetime)::DATE AS last, count(*) AS n
  FROM obs_env
  WHERE dataset_key IN ('calcofi_bottle', 'calcofi_ctd-cast')
    AND measurement_type IN {in_sql(na.omit(unlist(names_btl_ctd[-1])))}
  GROUP BY ALL ORDER BY measurement_type, dataset_key"))
# (nutrients reach a new cruise after the lab runs them, so btl_nitrate ends a cruise earlier)
# every name, its units and its valid range: the measurement_type table, or calcofi.io/measurements

# 9. anomalies against the 1993-2013 baseline ----
# a per-cast product against each station's baseline for the cruise's month; a cast with
# no baseline is NA, never 0. Shown on a final cruise (fall 2015). The newest cruise is
# cruise_key "2026-11-33P4": it is preliminary, as posted by the ship, so read it as such.
cruise <- "2015-11-32OC"
d_anom <- cc_cast_anomaly(con, variables = "hypoxic_depth_14", cruise_key = cruise)
d_anom |> arrange(site_key) |> select(site_key, datetime, value, clim_mean, anomaly) |> print(n = 20)

# the same idea by hand, for CTD temperature at 10 m: join each value to its baseline cell
qry(glue("
  SELECT o.site_key, o.depth_bin, avg(o.value) AS temperature,
         any_value(c.clim_mean) AS clim_mean, avg(o.value) - any_value(c.clim_mean) AS anomaly
  FROM obs_env o
  JOIN climatology c
    ON  c.dataset_key = o.dataset_key AND c.site_key = o.site_key
    AND c.measurement_type = o.measurement_type AND c.depth_bin = o.depth_bin
    AND c.month = o.cruise_month
  WHERE o.dataset_key = 'calcofi_ctd-cast' AND o.measurement_type = 'temperature_ave'
    AND o.cruise_key = '{cruise}' AND o.depth_bin = 10 AND o.qual_ok
  GROUP BY ALL ORDER BY o.site_key"))

# 10. regions: Kahru's satellite areas ----
# sample_spatial says which region(s) every sample falls in, for any boundary layer.
# version 1 assigns whole station cells to an area (see CalCOFI/explore#44 for the
# straight-edged, area-weighted version that was asked for)
qry("
  SELECT ss.spatial_name AS area, count(DISTINCT o.cruise_key) AS n_cruises,
         round(avg(o.value), 2) AS mean_chl_ug_l, count(*) AS n
  FROM obs_env o
  JOIN sample_spatial ss ON ss.root_id = o.root_id      -- membership is by the root sample (the cast)
  WHERE ss.layer = 'Kahru Satellite Areas'
    AND o.dataset_key = 'calcofi_bottle' AND o.measurement_type = 'chlorophyll_a'
    AND o.depth_min_m <= 10 AND o.qual_ok
  GROUP BY 1 ORDER BY 1")

# 11. biology to environment in one call [live] ----
# the matching rule is in the arguments, not hidden: which temperature goes with a net tow?
# here: bottle temperature within 5 km and 72 h of the tow, the cast nearest in time, 0-10 m
d_sardine <- cc_match_ichthyo_by_name(
  "Sardinops sagax", env_var = "temperature", life_stage = "larva",
  date_min = "2018-01-01", date_max = "2018-03-31",
  depth_m_min = 0, depth_m_max = 10, relax_matching = TRUE, con = con)
d_sardine |> select(bio_datetime, bio_value, tally, env_value, env_depth_m, n_env, dist_km, time_diff_hr)
# the depth bounds matter: without them the mean runs over every bottle of the cast
# (about 11 degC at a mean depth of 150 m here, against about 15 degC for 0-10 m).
# so which layer should be the default for larvae: 10 m, the mixed layer, the tow's depth range?
cat(substr(attr(d_sardine, "sql"), 1, 400))   # the exact SQL: paste it into Python, db-query or DuckDB

# 12. two questions from the Explorer's feedback button ----
# "why can't I see the egg / CUFES data?": eggs are a life stage, and CUFES counts only eggs
qry("
  SELECT o.dataset_key, o.life_stage, count(*) AS n_obs,
         min(o.datetime)::DATE AS first, max(o.datetime)::DATE AS last
  FROM obs_bio o JOIN taxon t USING (taxon_key)
  WHERE t.scientific_name = 'Sardinops sagax' AND o.measurement_type = 'abundance'
  GROUP BY ALL ORDER BY 1, 2")

# "how do I get zooplankton biovolume?": displacement volume is one value per tow, so it
# is in sample_measurement, not obs_bio
qry("
  SELECT year(s.datetime) AS year, count(*) AS n_tows,
         round(median(m.measurement_value), 1) AS median_total_ml,
         any_value(m.measurement_type) AS measurement_type
  FROM sample_measurement m JOIN sample s USING (sample_key)
  WHERE m.dataset_key = 'swfsc_ichthyo' AND m.measurement_type = 'total_plankton_biomass'
  GROUP BY 1 ORDER BY 1 DESC LIMIT 10")
# cc_match_zooplankton_biomass() matches it to temperature the way section 11 does for larvae

# 13. cite what you used [live] ----
used <- c("calcofi_bottle", "calcofi_bottle-derived", "calcofi_ctd-derived")
cc_cite(used, version = VERSION, con = con)                      # the release first, then each dataset
cc_cite(used, version = VERSION, con = con, format = "bibtex")   # for a reference manager

# 14. coming next: sample_track ----
# a new core table for samples with extent: one path per sample (a survey effort
# segment, a line of sight), beside its point in sample. It arrives with a dataset that
# is still under provider review, so it is documented but not yet in a public release:
# calcofi.io/docs/db.html#sec-sample-track
#   SELECT s.sample_key, t.track_type, t.length_km, t.geom
#   FROM sample s JOIN sample_track t USING (sample_key)
#   WHERE t.track_type = 'effort_segment'

# 15. tidy up ----
dbDisconnect(con, shutdown = TRUE)
