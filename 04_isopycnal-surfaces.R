# conditions on isopycnal surfaces (sigma-theta 25.6 and 26.6): every cruise 1993-2026 at the
# stations occupied in fall 2026, by region, and maps of each surface on the 2026-11 cruise
#
# Rasmus Swalethorp's script of 2026-11-17 (email "Missing data"), reworked:
# - cc_isopycnal_anomaly() takes the surfaces as `sigma =` (there is no `surfaces =`: the error);
# - with calcofi4r >= 1.35.0 the values and the baselines are both read from the release's
#   `isopycnal` and `climatology` tables, so a plain cc_get_db() is enough (no 1 m casts) and every
#   cruise at ~60 stations takes seconds, not a recomputation of thousands of casts;
# - the cruise's year, month and season come with each row (the median cast date, the rule every
#   baseline files a cast under), so no SQL on the cruise or sample tables is needed;
# - new: maps of each surface (its depth, and the anomalies of depth, temperature, salinity, spice
#   and oxygen on it) for one cruise, interpolated as the Explorer's Contours lens does
#   (cc_interpolate(), ordinary kriging), with the stations where the surface outcrops or is never
#   reached marked, since an interpolated map would otherwise hide them.
#
# needs data/St_Stations.csv: Rasmus's stations list with its "Modified regions" column (provisional,
# so not in this repo; data/ is git-ignored). Outputs go to data/: the table, a PDF, two maps.

# remotes::install_github("CalCOFI/calcofi4r") # once: >= 1.35.0
librarian::shelf(
  calcofi4r, dplyr, ggplot2, patchwork, readr, rnaturalearth, rnaturalearthdata, sf, terra, tidyr,
  quiet = T)
stopifnot(
  "update calcofi4r: remotes::install_github('CalCOFI/calcofi4r')" =
    packageVersion("calcofi4r") >= "1.35.0")

# parameters ----
surfaces     <- c(25.6, 26.6)       # sigma-theta, kg/m3 (any of the release's 18)
yr_rng       <- c(1993, 2026)       # years to plot
cruise_map   <- "2026-11-33P4"      # the cruise to map, and whose stations to follow
stations_csv <- "data/St_Stations.csv"
dir_out      <- "data"
dir.create(dir_out, showWarnings = F)

# variable on a surface -> short name in the table, label in the plots
vars <- tibble::tribble(
  ~variable,                  ~short,        ~label,
  "depth_m",                  "depth_m",     "depth (m)",
  "temperature_ave",          "temperature", "temperature (°C)",
  "salinity_ave_corr",        "salinity",    "salinity",
  "spiciness0",               "spice",       "spice (kg/m³)",
  "oxygen_ml_l_ave_sta_corr", "oxygen",      "oxygen, station-corrected (mL/L)",
  "est_nitrate_sta_corr",     "nitrate",     "nitrate, estimated (µmol/kg)")

# regions: the "Modified regions" column of the stations list ----
region_order <- c("SCCOOS", "SCB-Coast", "SCB", "Up", "CC", "Off")
st_regions <- read_csv(stations_csv, show_col_types = F) |>
  transmute(
    site_key = trimws(Sta_ID),                          # "093.3 030.0", as sample.site_key
    region   = na_if(trimws(`Modified regions`), "")) |>
  mutate(region = if_else(toupper(region) == "OFF", "Off", region)) |>
  filter(!is.na(region)) |>
  distinct(site_key, region)

# connect (v2026.11.14+: the isopycnal table and its baseline) ----
con <- cc_get_db()

# 1. the mapped cruise: every station, both surfaces, against the Sep-Nov baseline ----
an_cr <- cc_isopycnal_anomaly(con, sigma = surfaces, cruise_key = cruise_map, season = T)

# its stations in a region: the ones to follow through time
sta <- an_cr |>
  distinct(site_key, longitude, latitude) |>
  inner_join(st_regions, by = "site_key") |>
  mutate(region = factor(region, levels = intersect(region_order, unique(region)))) |>
  arrange(region, desc(site_key))
message(nrow(sta), " stations of ", cruise_map, " in a region: ",
        paste(names(table(sta$region)), table(sta$region), sep = " ", collapse = ", "))

# 2. every cruise at those stations, all seasons ----
# each cruise against its own season's baseline (1993-2013, >= 5 cruises); NA where there is none
an <- cc_isopycnal_anomaly(con, sigma = surfaces, site_key = sta$site_key, season = T) |>
  filter(year >= yr_rng[1], year <= yr_rng[2]) |>
  mutate(season = cc_season_label(month))

# one row per cruise x station (a station occupied twice on a cruise is averaged), and per surface
# and variable its value, its anomaly and the surface's status (ok, at_surface = outcrops,
# not_reached = never that dense, ...)
by_occ <- an |>
  inner_join(vars, by = "variable") |>
  summarize(
    value   = mean(value, na.rm = T),
    anomaly = if (all(is.na(anomaly))) NA_real_ else mean(anomaly, na.rm = T),
    status  = paste(sort(unique(status)), collapse = "/"),
    n_casts = n_distinct(sample_key),
    .by     = c(cruise_key, year, month, season, site_key, sigma_theta, short)) |>
  mutate(
    value = if_else(is.nan(value), NA_real_, value),
    col   = sprintf("iso%.1f_%s", sigma_theta, short))

col_order <- c(outer(c("", "_anom"), sprintf("iso%.1f_%s", rep(surfaces, each = nrow(vars)), vars$short),
                     \(sfx, col) paste0(col, sfx)))
iso_wide <- by_occ |>
  select(cruise_key, year, month, season, site_key, n_casts, col, value, anom = anomaly) |>
  pivot_wider(
    id_cols     = c(cruise_key, year, month, season, site_key),
    names_from  = col,
    values_from = c(value, anom),
    names_glue  = "{col}{ifelse(.value == 'anom', '_anom', '')}",
    values_fn   = mean) |>
  left_join(
    by_occ |>
      filter(short == "depth_m") |>
      select(cruise_key, site_key, sigma_theta, status) |>
      mutate(col = sprintf("iso%.1f_status", sigma_theta)) |>
      pivot_wider(id_cols = c(cruise_key, site_key), names_from = col, values_from = status),
    by = c("cruise_key", "site_key")) |>
  left_join(st_regions, by = "site_key") |>
  select(cruise_key, year, month, season, region, site_key, ends_with("_status"),
         any_of(col_order)) |>
  arrange(year, month, cruise_key, region, desc(site_key))

csv_out <- file.path(dir_out, sprintf(
  "isopycnal_%s_%d-%d.csv", paste(surfaces, collapse = "_"), yr_rng[1], yr_rng[2]))
write_csv(iso_wide, csv_out, na = "")
message("wrote ", nrow(iso_wide), " cruise x station rows: ", csv_out)

# 3. fall (Sep-Nov) time series by region: each station, and the regional mean per year ----
fall <- by_occ |>
  filter(season == "Sep–Nov") |>
  inner_join(sta |> select(site_key, region), by = "site_key")

plot_region_ts <- function(d, reg, y, ylab, reverse = F, zero = F) {
  d <- filter(d, region == reg, !is.na(.data[[y]]))
  p <- ggplot(d, aes(year, .data[[y]])) +
    scale_x_continuous(limits = yr_rng, breaks = seq(1995, 2025, by = 5)) +
    labs(title = reg, x = NULL, y = ylab, color = NULL) +
    theme_bw(base_size = 9) +
    theme(plot.title = element_text(face = "bold"), legend.key.size = unit(0.3, "cm"))
  if (!nrow(d))
    return(p + annotate("text", x = mean(yr_rng), y = 0, label = "no values", color = "grey50"))
  if (zero) p <- p + geom_hline(yintercept = 0, linetype = "dashed", color = "grey50")
  if (reverse) p <- p + scale_y_reverse()
  p +
    geom_point(aes(color = site_key), alpha = 0.7, size = 1.4) +
    stat_summary(fun = mean, geom = "line", color = "black", linewidth = 0.8) +
    stat_summary(fun = mean, geom = "point", color = "black", size = 1.2)
}

pdf_out <- file.path(dir_out, sprintf("isopycnal_fall_by_region_%s.pdf", paste(surfaces, collapse = "_")))
cairo_pdf(pdf_out, width = 14, height = 9, onefile = T) # cairo: pdf() can't encode σθ
for (s in surfaces) for (i in seq_len(nrow(vars))) for (y in c("value", "anomaly")) {
  d <- filter(fall, abs(sigma_theta - s) < 1e-6, short == vars$short[i])
  if (all(is.na(d[[y]]))) next
  is_depth <- vars$variable[i] == "depth_m"
  ylab <- if (y == "anomaly") paste(if (is_depth) "deeper (m)" else vars$label[i], "anomaly") else vars$label[i]
  ps <- lapply(levels(droplevels(sta$region)), \(reg)
    plot_region_ts(d, reg, y, ylab, reverse = is_depth && y == "value", zero = y == "anomaly"))
  print(wrap_plots(ps, ncol = 3) + plot_annotation(
    title    = sprintf("σθ %.1f: %s%s, fall cruises", s, vars$label[i],
                       if (y == "anomaly") " anomaly vs Sep–Nov 1993–2013" else ""),
    subtitle = sprintf("stations occupied on %s; black: mean of the region's stations", cruise_map)))
}
dev.off()
message("wrote ", pdf_out)

# 4. maps of each surface on the mapped cruise ----
land <- ne_countries(scale = "medium", returnclass = "sf")
bb   <- with(an_cr, c(range(longitude, na.rm = T) + c(-0.4, 0.4), range(latitude, na.rm = T) + c(-0.4, 0.4)))

# kriged surface of one variable from the casts' points, as a lon/lat data frame
krige_df <- function(pts) {
  s <- cc_interpolate(pts, method = "ok", se = F)
  r <- cc_interpolate_rast(s) |> project("EPSG:4326")
  as.data.frame(r[["value"]], xy = T, na.rm = T)
}

map_panel <- function(d_s, v, what = c("value", "anomaly")) {
  what <- match.arg(what)
  lbl  <- vars$label[vars$variable == v]
  ttl  <- if (what == "value") lbl else
    if (v == "depth_m") "depth anomaly (m, + deeper)" else paste(sub(" \\(.*", "", lbl), "anomaly")
  pts  <- d_s |>
    filter(variable == v, status == "ok") |>
    summarize(z = mean(.data[[what]], na.rm = T), .by = c(site_key, longitude, latitude)) |>
    filter(is.finite(z)) |>
    transmute(lon = longitude, lat = latitude, z)
  # where the surface has no depth: it outcrops (lighter water is absent) or is never reached
  miss <- d_s |>
    filter(variable == "depth_m", status %in% c("at_surface", "not_reached")) |>
    distinct(longitude, latitude, status)
  p <- ggplot() +
    geom_sf(data = land, fill = "grey85", color = "grey60", linewidth = 0.2) +
    labs(title = ttl, x = NULL, y = NULL, fill = NULL, shape = NULL) +
    theme_bw(base_size = 8) + theme(legend.key.width = unit(0.3, "cm"))
  if (nrow(pts) >= 5) {
    g <- krige_df(pts)
    p <- p + geom_raster(data = g, aes(x, y, fill = value), interpolate = T)
    p <- p + if (what == "value") {
      scale_fill_viridis_c(direction = if (v == "depth_m") -1 else 1)
    } else {
      lim <- c(-1, 1) * max(abs(g$value), na.rm = T)
      scale_fill_gradient2(low = "#2166ac", mid = "white", high = "#b2182b", limits = lim)
    }
  } else {
    p <- p + annotate("text", x = mean(bb[1:2]), y = mean(bb[3:4]), label = "too few casts", color = "grey40")
  }
  p +
    geom_point(data = pts, aes(lon, lat), size = 0.5) +
    geom_point(data = miss, aes(longitude, latitude, shape = status), size = 1.6, color = "grey20") +
    scale_shape_manual(values = c(at_surface = 2, not_reached = 4), drop = F,
                       labels = c(at_surface = "outcrops", not_reached = "not reached")) +
    coord_sf(xlim = bb[1:2], ylim = bb[3:4], expand = F)
}

for (s in surfaces) {
  d_s <- filter(an_cr, abs(sigma_theta - s) < 1e-6)
  ps  <- list(
    map_panel(d_s, "depth_m", "value"),
    map_panel(d_s, "depth_m", "anomaly"),
    map_panel(d_s, "temperature_ave", "anomaly"),
    map_panel(d_s, "salinity_ave_corr", "anomaly"),
    map_panel(d_s, "spiciness0", "anomaly"),
    map_panel(d_s, "oxygen_ml_l_ave_sta_corr", "anomaly"))
  png_out <- file.path(dir_out, sprintf("isopycnal_surface_%s_sigma%.1f.png", cruise_map, s))
  ggsave(png_out, wrap_plots(ps, ncol = 3) + plot_annotation(
    title    = sprintf("σθ %.1f surface, cruise %s", s, cruise_map),
    subtitle = "anomalies vs Sep–Nov 1993–2013 at each station; kriged between casts (cc_interpolate)"),
    width = 13, height = 6, dpi = 150)
  message("wrote ", png_out)
}

# 5. one figure to share: where the surface sank, and how far against past falls ----
# left: the first surface's depth anomaly on the mapped cruise; right: the fall mean depth anomaly
# of each region's stations, both surfaces, 1993-2026, the mapped cruise's value labelled
ink      <- "#0b0b0b"; ink_2 <- "#52514e"; surface <- "#fcfcfb"; grid_ink <- "#e8e7e3"
sig_lbl  <- sprintf("σθ %.1f", surfaces)
pal      <- setNames(c("#2a78d6", "#eb6834")[seq_along(surfaces)], sig_lbl)  # categorical slots 1-2, validated
yr_map   <- as.integer(substr(cruise_map, 1, 4))
theme_share <- theme_minimal(base_size = 10) + theme(
  plot.background  = element_rect(fill = surface, color = NA),
  panel.grid.minor = element_blank(),
  panel.grid.major = element_line(color = grid_ink, linewidth = 0.3),
  text             = element_text(color = ink),
  axis.text        = element_text(color = ink_2),
  strip.text       = element_text(face = "bold", hjust = 0, color = ink),
  plot.title       = element_text(face = "bold"))

ts <- fall |>
  filter(short == "depth_m", !is.na(anomaly)) |>
  summarize(anomaly = mean(anomaly), n = n(), .by = c(region, year, sigma_theta)) |>
  mutate(surface = factor(sprintf("σθ %.1f", sigma_theta), levels = sig_lbl)) |>
  droplevels()
# the mapped cruise's values as a small table right of each panel: one column per surface, in the
# legend's order, under a header in the first panel (text in ink; the marks carry the colour)
col_x <- yr_rng[2] + 1.8 + (seq_along(sig_lbl) - 1) * 3.4
lab <- ts |>
  filter(year == yr_map) |>
  mutate(x = col_x[as.integer(surface)], y = max(max(anomaly), 28), .by = region) # clear of the zero line
hdr <- tibble::tibble(
  region = factor(levels(ts$region)[1], levels = levels(ts$region)),
  x = col_x, y = max(lab$y) + 32, label = sprintf("%.1f", surfaces))
p_ts <- ggplot(ts, aes(year, anomaly, color = surface)) +
  geom_hline(yintercept = 0, color = ink_2, linewidth = 0.4) +
  geom_line(linewidth = 0.7) +
  geom_point(data = filter(ts, year == yr_map), size = 2.6, stroke = 0.8, fill = surface, shape = 21) +
  geom_text(data = lab, aes(x, y, label = sprintf("%+.0f", anomaly)), color = ink, size = 3.1,
            hjust = 0, vjust = 0.5, inherit.aes = F) +
  geom_text(data = hdr, aes(x, y, label = label), color = ink_2, size = 2.8, hjust = 0,
            fontface = "bold", inherit.aes = F) +
  facet_wrap(~ region, ncol = 1, strip.position = "top") +
  scale_color_manual(values = pal, name = NULL) +
  scale_x_continuous(limits = c(yr_rng[1], max(col_x) + 3), breaks = seq(1995, 2025, by = 10)) +
  scale_y_continuous(breaks = c(0, 50, 100)) +
  labs(title = "How far, against past falls", x = NULL,
       y = "fall depth anomaly, region mean (m, + deeper)") +
  theme_share + theme(legend.position = "top", legend.justification = "left")

d_m  <- filter(an_cr, abs(sigma_theta - surfaces[1]) < 1e-6)
pts  <- d_m |>
  filter(variable == "depth_m", status == "ok") |>
  summarize(z = mean(anomaly, na.rm = T), .by = c(longitude, latitude)) |>
  filter(is.finite(z)) |>
  transmute(lon = longitude, lat = latitude, z)
g    <- krige_df(pts)
miss <- d_m |> filter(variable == "depth_m", status == "not_reached") |> distinct(longitude, latitude)
lim  <- c(-1, 1) * max(abs(g$value))
p_map <- ggplot() +
  geom_raster(data = g, aes(x, y, fill = value), interpolate = T) +
  geom_sf(data = land, fill = "#e3e2de", color = "#b9b8b2", linewidth = 0.2) +
  geom_point(data = pts, aes(lon, lat), size = 0.6, color = ink) +
  geom_point(data = miss, aes(longitude, latitude), shape = 4, size = 1.8, color = ink) +
  scale_fill_gradient2(low = "#184f95", mid = "#f0efec", high = "#b8302f", limits = lim,
                       name = "m deeper\nthan normal") +
  coord_sf(xlim = bb[1:2], ylim = bb[3:4], expand = F) +
  labs(title = sprintf("Where: %s, cruise %s", sig_lbl[1], cruise_map), x = NULL, y = NULL,
       caption = "× station too shallow to reach the surface") +
  # the legend in the open water south-east of the stations, clear of the coast where the signal is
  theme_share + theme(legend.position = "inside", legend.position.inside = c(0.9, 0.2),
                      legend.direction = "vertical",
                      legend.background = element_rect(fill = surface, color = NA),
                      plot.caption = element_text(color = ink_2, hjust = 0))

fig <- (p_map | p_ts) + plot_layout(widths = c(1.35, 1)) + plot_annotation(
  title    = sprintf("Fall %d: density surfaces off Southern California sank about 100 m near the coast, twice 2015", yr_map),
  subtitle = paste0(
    "Depth of the isopycnal on each CTD cast against its station's Sep–Nov 1993–2013 mean. ",
    "Below the mixed layer, much of a warm anomaly at a fixed depth is this displacement."),
  caption  = paste0(
    "Regions (provisional): R. Swalethorp. Right: mean over each region's stations occupied on ", cruise_map,
    "; SCCOOS stations are too shallow to reach ", sig_lbl[1], ".\n",
    "Data: CalCOFI.io release v2026.11.14 (doi:10.5281/zenodo.24223907), calcofi4r ",
    format(packageVersion("calcofi4r")), "; map kriged between casts (cc_interpolate)."),
  theme = theme_share + theme(
    plot.title = element_text(face = "bold", size = 14),
    plot.subtitle = element_text(color = ink_2),
    plot.caption = element_text(color = ink_2, hjust = 0)))
png_share <- file.path(dir_out, sprintf("isopycnal_%s_share.png", cruise_map))
ggsave(png_share, fig, width = 12, height = 8, dpi = 200, bg = surface)
message("wrote ", png_share)

DBI::dbDisconnect(con, shutdown = T)
