# CalCOFI.io database tour: Python walkthrough (2026-11-12)
#
# run one cell at a time in Positron (each "# %%" is a cell: Cmd+Enter runs it).
# The interpreter is this folder's .venv (calcofi4py, pandas, pyarrow, gsw).
# Same release, same bytes as the R walkthrough (01_tour.R): the two agree row for row.
# cells marked [live] are shown in the tour (about 2 minutes); the rest are take-home.

# %% 0. setup
import os

import calcofi4py as cc
import pandas as pd

pd.set_option("display.width", 160, "display.max_columns", 30)
VERSION = "v2026.11.09"              # pinned: the same rows tomorrow, next year, on your machine
os.makedirs("data", exist_ok=True)   # small outputs to open in Positron's Data Explorer

# %% 1. connect to the release [live]
con = cc.cc_get_db(VERSION)          # cc.cc_get_db() alone gives the newest release
con.sql("SHOW TABLES").df()

# %% 2. what one row of each core table means
con.sql("""
  SELECT dataset_key, sample_type, count(*) AS n
  FROM sample GROUP BY ALL ORDER BY dataset_key, sample_type""").df()

# %% 3. one pull, several datasets: the OR goes inside the SQL string [live]
#    (Nastassia's question: "e.dataset_key = 'a'" | "e.dataset_key = 'b'" is Python, not SQL)
con.sql("""
  SELECT dataset_key, measurement_type, count(*) AS n
  FROM obs_env
  WHERE dataset_key IN ('calcofi_bottle', 'calcofi_bottle-derived')
    AND measurement_type IN ('temperature', 'salinity', 'spiciness0', 'sigma_theta_teos10')
  GROUP BY ALL ORDER BY 1, 2""").df()

# %% 4. bottles + spiciness + their CTD cast's per-cast products, one row per bottle [live]
BOTTLE  = ["temperature", "salinity", "chlorophyll_a", "nitrate", "nitrite", "oxygen_ml_l"]
DERIVED = ["mld_temperature_02", "mld_sigma_theta_0125", "chl_max", "chl_max_depth",
           "chl_integrated", "pycnocline_depth", "nitracline_depth", "hypoxic_depth_14"]

def wide(types, t, v):
    return ",\n    ".join(f"max({t}.{v}) FILTER (WHERE {t}.measurement_type = '{x}') AS {x}" for x in types)

df = con.sql(f"""
  WITH btl AS (                                  -- one row per bottle
    SELECT c.cruise_key, c.order_occ, c.site_key, c.datetime, c.latitude, c.longitude,
           c.seafloor_depth_m, e.sample_key, e.depth_min_m AS depth_m,
    {wide(BOTTLE, 'e', 'value')}
    FROM obs_env e
    JOIN sample b ON b.sample_key = e.sample_key          -- the bottle
    JOIN sample c ON c.sample_key = b.root_sample_key     -- its cast (carries order_occ)
    WHERE e.dataset_key = 'calcofi_bottle' AND e.measurement_type IN {tuple(BOTTLE)}
      AND e.datetime BETWEEN '1996-04-01' AND '2021-12-31' AND e.qual_ok
    GROUP BY ALL),
  spice AS (                                     -- TEOS-10 spiciness at each bottle
    SELECT sample_key, value AS spiciness0
    FROM obs_env WHERE dataset_key = 'calcofi_bottle-derived' AND measurement_type = 'spiciness0'),
  ctd AS (                                       -- one row per CTD cast
    SELECT s.cruise_key, s.order_occ, s.sample_key AS ctd_cast,
    {wide(DERIVED, 'm', 'measurement_value')}
    FROM sample_measurement m JOIN sample s ON s.sample_key = m.sample_key
    WHERE m.dataset_key = 'calcofi_ctd-derived'
    GROUP BY s.cruise_key, s.order_occ, s.sample_key
    QUALIFY row_number() OVER (PARTITION BY s.cruise_key, s.order_occ ORDER BY s.sample_key) = 1)
  SELECT btl.*, spice.spiciness0, ctd.* EXCLUDE (cruise_key, order_occ)
  FROM btl
  LEFT JOIN spice USING (sample_key)
  LEFT JOIN ctd   USING (cruise_key, order_occ)                 -- the same station visit
  ORDER BY datetime, depth_m""").df()
print(df.shape)
df.head()

# %% 5. save it, then open data/*.parquet from the Files pane in Positron's Data Explorer
df.to_parquet("data/bottle_plus_derived_1996-2021_py.parquet", index=False)

# %% 6. after May 2021: the bottle database stops, the CTD cast files carry on [live]
#    The Bottle Database's last cruise is 2105. The CTD Cast Files run to the newest cruise
#    and carry the rosette's bottle values (btl_temperature, salinity_btl, oxygen_btl_ml_l,
#    btl_chlorophyll_a, btl_nitrate, ...) beside the sensor series (temperature_ave,
#    salinity_ave_corr, oxygen_ml_l_ave_sta_corr, est_chlorophyll_a_sta_corr).
con.sql("""
  SELECT dataset_key, measurement_type, any_value(units) AS units,
         min(datetime)::DATE AS first, max(datetime)::DATE AS last, count(*) AS n
  FROM obs_env
  WHERE dataset_key = 'calcofi_bottle'   AND measurement_type IN ('temperature', 'salinity', 'oxygen_ml_l', 'chlorophyll_a', 'nitrate')
     OR dataset_key = 'calcofi_ctd-cast' AND (measurement_type LIKE 'btl_%' OR measurement_type LIKE '%_btl%'
                                              OR measurement_type IN ('temperature_ave', 'salinity_ave_corr'))
  GROUP BY ALL ORDER BY dataset_key, measurement_type""").df()

# %% 7. quality flags: qual_ok is the materialized verdict; qual_ok_sql() is the same rule
print(cc.qual_ok_sql("o")[:200], "...")

# %% 8. the SQL behind any table, for any DuckDB (CLI, browser, another language)
catalog = cc.cc_catalog(VERSION)
src     = cc.release_sources(catalog, "taxon")
print(cc.read_parquet_sql(src))

# %% 9. cite what you used: the release first, then each dataset [live]
print("\n\n".join(cc.cc_cite(["calcofi_bottle", "calcofi_bottle-derived", "calcofi_ctd-derived"], version=VERSION)))

# %% 10. tidy up
con.close()
