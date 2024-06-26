#!/usr/bin/env Rscript
rm(list = ls())
args <- commandArgs(trailingOnly = TRUE)
require(ggplot2)
require(rgbif)
require(gbifdb)
require(plotly)
require(data.table)

require(DBI)
require(RPostgreSQL)
require(lubridate)
require(uuid)
require(tidyr)
require(dplyr)
library(sentryR)
library(jsonlite)

source("helpers.R")
source("init_report.R")

# Generate the output filename for cached plots.
tryCatch(
  {
    # Start loading phase.
    updateReport(report_id, "LOADING", con)

    cat("-------------------------------------", "Filtering GBIF occurrences:", taxon_name, taxonomic_rank, "-------------------------------------", sep = "\n")

    # Read in GBIF occurrences.
    gbif <- gbif_local()

    # Read in Tronko output and filter it.
    tronko_input <- tbl(con, "Occurence")
    tronko_filtered <- tronko_input %>%
      filter(Taxon == taxon_name) %>%
      filter(rank == taxonomic_rank) %>%
      select(-c(id, Taxon, rank, year)) %>%
      distinct(.keep_all = TRUE)
    tronko_db <- as.data.frame(tronko_filtered)
    tronko_db <- tronko_db[complete.cases(tronko_db), ]
    gbif_taxon_key <- name_backbone(name = taxon_name, rank = taxonomic_rank)$usageKey

    # Start buil1ding phase.
    updateReport(report_id, "BUILDING", con)

    # Filter GBIF occurrences to a particular taxon.
    gbif_db <- gbif %>%
      filter(
        basisofrecord %in% c("HUMAN_OBSERVATION", "OBSERVATION", "MACHINE_OBSERVATION"),
        coordinateuncertaintyinmeters <= 100 & !is.na(coordinateuncertaintyinmeters),
        occurrencestatus == "PRESENT", taxonkey == gbif_taxon_key
      ) %>%
      select(decimallongitude, decimallatitude)
    gbif_db <- as.data.frame(gbif_db)
    colnames(gbif_db) <- c("lng", "lat")
    cat("GBIF occurrences filtered:", nrow(gbif_db), "\n")

    # Get unique taxon locations
    if (nrow(gbif_db) < 1) {
      taxon_map <- data.frame(matrix(nrow = 1, ncol = 2))
      colnames(taxon_map) <- c("lng", "lat")
      taxon_map$lng <- " "
      taxon_map$lat <- " "
    }
    if (nrow(gbif_db) >= 1) {
      taxon_map <- gbif_db[, c("lng", "lat")]
      taxon_map <- taxon_map[complete.cases(taxon_map), ]
      taxon_map <- taxon_map[!duplicated(taxon_map), ]
    }
    cat("Unique taxon occurrences:", nrow(taxon_map), "\n")

    # Rename latitude and longitude
    names(tronko_db)[names(tronko_db) == "longitude"] <- "lng"
    names(tronko_db)[names(tronko_db) == "latitude"] <- "lat"
    cat("Unique taxon occurrences after renaming:", nrow(tronko_db), "\n")

    # Generate JSON object for export and mapping.
    datasets <- list(datasets = list(eDNA = tronko_db, GBIF = taxon_map))
    cat("Generated datasets for mapping\n")

    # Export file for mapping
    write(toJSON(datasets, auto_unbox = TRUE), filename)
    file_key <- paste("projects/", project_id, "/plots/", filename, sep = "")
    system(paste("aws s3 cp ", filename, " s3://", bucket, "/", file_key, " --endpoint-url ", ENDPOINT_URL, sep = ""), intern = TRUE)
    system(paste("rm ", filename, sep = ""))
    cat("Exported datasets for mapping to: ", file_key, "\n")

    # Update report with file key.
    sql_query <- sprintf(
      "UPDATE \"Report\" SET \"fileKey\" = '%s' WHERE \"id\" = '%s'",
      file_key, report_id
    )
    print(paste("Updating report", report_id, "with file key", file_key, sep = " "))
    dbExecute(con, sql_query)
    updateReport(report_id, "COMPLETED", con)
    RPostgreSQL::dbDisconnect(con, shutdown = TRUE)
  },
  error = function(e) {
    process_error(e, report_id, project_id, con)
  }
)
