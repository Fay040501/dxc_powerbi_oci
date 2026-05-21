# ============================================================================
# SCRIPT 3/4 — tb_ftth_prepaid_recharges
# Chargement recharges FTTH Prepaid depuis CSV local → PostgreSQL
# Logique : INSERT avec ON CONFLICT DO NOTHING (ajout incrémental)
# Clé unique : nd + date_jour + montant_ttc
# ============================================================================

library(DBI); library(RPostgreSQL); library(readr)
library(dplyr); library(stringr); library(lubridate)

BASE_DATA <- Sys.getenv("BASE_DATA")
if (BASE_DATA == "") BASE_DATA <- getwd()

PATH_CSV <- file.path(BASE_DATA, "recharges")
LOG_DIR  <- file.path(BASE_DATA, "logs")
if (!dir.exists(LOG_DIR)) dir.create(LOG_DIR, recursive = TRUE)
LOG_FILE <- file.path(LOG_DIR, paste0("load_recharges_", format(Sys.time(), "%Y%m%d_%H%M%S"), ".txt"))
SEPARATOR <- strrep("=", 70); debut <- Sys.time()

write_log <- function(msg, level = "INFO") {
  line <- paste0("[", format(Sys.time(), "%Y-%m-%d %H:%M:%S"), "] [", level, "] ", msg)
  cat(line, "\n", file = LOG_FILE, append = TRUE); message(line)
}

clean_nd <- function(x) {
  val <- as.character(x) %>% str_trim() %>% str_replace_all("[^0-9]", "")
  case_when(
    str_starts(val, "225225") & str_detect(str_sub(val, 7), "^27[2-3][0-9]{7}$") ~ str_sub(val, 7),
    str_starts(val, "225")    & str_detect(str_sub(val, 4), "^27[2-3][0-9]{7}$") ~ str_sub(val, 4),
    str_starts(val, "25")     & str_detect(str_sub(val, 3), "^27[2-3][0-9]{7}$") ~ str_sub(val, 3),
    str_detect(val, "^27[2-3][0-9]{7}$") ~ val,
    TRUE ~ NA_character_
  )
}

write_log(SEPARATOR); write_log("DÉMARRAGE — tb_ftth_prepaid_recharges"); write_log(SEPARATOR)
write_log("Connexion à PostgreSQL...")
con <- tryCatch({
  dbConnect(PostgreSQL(), host=Sys.getenv("DB_HOST"), port=as.integer(Sys.getenv("DB_PORT")),
    dbname=Sys.getenv("DB_NAME"), user=Sys.getenv("DB_USER"), password=Sys.getenv("DB_PASSWORD"))
}, error = function(e) { write_log(paste("ERREUR :", e$message), "ERROR"); stop() })
write_log("✓ Connexion PostgreSQL établie")
on.exit(tryCatch(dbDisconnect(con), error = function(e) NULL), add = TRUE)

write_log("Création de la table si inexistante...")
dbExecute(con, "
  CREATE TABLE IF NOT EXISTS public.tb_ftth_prepaid_recharges (
    id                SERIAL PRIMARY KEY,
    nd                TEXT,
    montant_ttc       NUMERIC,
    date_rechargement DATE,
    date_jour         TEXT,
    date_jour_date    DATE,
    date_insertion    TIMESTAMP,
    cle_unique        TEXT UNIQUE
  );
  CREATE INDEX IF NOT EXISTS idx_recharges_nd      ON public.tb_ftth_prepaid_recharges(nd);
  CREATE INDEX IF NOT EXISTS idx_recharges_date    ON public.tb_ftth_prepaid_recharges(date_jour_date);
  CREATE INDEX IF NOT EXISTS idx_recharges_montant ON public.tb_ftth_prepaid_recharges(montant_ttc);
")
write_log("✓ Table tb_ftth_prepaid_recharges vérifiée")

write_log("Recherche des fichiers CSV...")
fichiers <- list.files(PATH_CSV, pattern="\\.csv$", full.names=TRUE, ignore.case=TRUE)
if (length(fichiers) == 0) { write_log(paste("Aucun CSV dans :", PATH_CSV), "ERROR"); stop() }
write_log(paste(length(fichiers), "fichier(s) trouvé(s) :"))
for (f in fichiers) write_log(paste("  -", basename(f)))

raw <- bind_rows(lapply(fichiers, function(f) {
  write_log(paste("Lecture :", basename(f)))
  df <- read_csv(f, show_col_types=FALSE, col_types=cols(id_client=col_character(), Recurrent=col_double(), derniere_date_rechargement=col_character(), date_jour=col_character()), locale=locale(encoding="UTF-8"))
  write_log(paste("  →", format(nrow(df), big.mark=" "), "lignes"))
  df
}))
write_log(paste("Total lignes brutes lues :", format(nrow(raw), big.mark=" ")))

write_log("Transformation des données...")
write_log(paste("  id_client manquants :", sum(is.na(raw$id_client) | raw$id_client == "")))

df_final <- raw %>%
  rename(nd_brut = id_client) %>%
  mutate(
    nd                = clean_nd(nd_brut),
    montant_ttc       = as.numeric(Recurrent),
    date_rechargement = ymd(as.character(derniere_date_rechargement), quiet=TRUE),
    date_jour         = as.character(date_jour),
    date_jour_date    = ymd(date_jour, quiet=TRUE),
    date_insertion    = Sys.time(),
    cle_unique        = paste(nd, date_jour, montant_ttc, sep="_")
  ) %>%
  filter(!is.na(nd), !is.na(date_jour_date)) %>%
  select(nd, montant_ttc, date_rechargement, date_jour, date_jour_date, date_insertion, cle_unique)

write_log(paste("  Lignes filtrées :", nrow(raw) - nrow(df_final)))
write_log(paste("  Lignes après transformation :", format(nrow(df_final), big.mark=" ")))

# ============================================================================
# INSERTION INCRÉMENTALE — ON CONFLICT DO NOTHING
# ============================================================================
write_log("Insertion incrémentale dans tb_ftth_prepaid_recharges...")
start_insert <- Sys.time()

tryCatch({
  dbWriteTable(con, name="temp_recharges", value=df_final,
               temporary=TRUE, overwrite=TRUE, row.names=FALSE)

  n_inserted <- dbExecute(con, "
    INSERT INTO public.tb_ftth_prepaid_recharges
      (nd, montant_ttc, date_rechargement, date_jour, date_jour_date, date_insertion, cle_unique)
    SELECT nd, montant_ttc, date_rechargement, date_jour, date_jour_date, date_insertion, cle_unique
    FROM temp_recharges
    ON CONFLICT (cle_unique) DO NOTHING
  ")

  duree <- round(as.numeric(difftime(Sys.time(), start_insert, units="secs")), 2)
  write_log(paste("✓ Insertion terminée en", duree, "secondes"))
  write_log(paste("  Nouvelles lignes insérées :", format(n_inserted, big.mark=" ")))
  write_log(paste("  Doublons ignorés          :", format(nrow(df_final) - n_inserted, big.mark=" ")))

}, error = function(e) {
  write_log(paste("ERREUR insertion :", e$message), "ERROR"); stop()
})

# ============================================================================
# VÉRIFICATION FINALE
# ============================================================================
stats <- dbGetQuery(con, "
  SELECT COUNT(*) AS total_lignes, COUNT(DISTINCT nd) AS nd_uniques,
    COUNT(DISTINCT date_jour_date) AS jours_distincts,
    MIN(date_jour_date) AS premiere_date, MAX(date_jour_date) AS derniere_date,
    SUM(montant_ttc) AS montant_total, AVG(montant_ttc) AS montant_moyen
  FROM public.tb_ftth_prepaid_recharges
")

top_montants <- dbGetQuery(con, "
  SELECT montant_ttc, COUNT(*) as nb FROM public.tb_ftth_prepaid_recharges
  GROUP BY montant_ttc ORDER BY nb DESC LIMIT 5
")

write_log(""); write_log(SEPARATOR); write_log("STATISTIQUES FINALES"); write_log(SEPARATOR)
write_log(paste("Total lignes en base :", format(stats$total_lignes, big.mark=" ")))
write_log(paste("ND uniques           :", format(stats$nd_uniques, big.mark=" ")))
write_log(paste("Jours distincts      :", stats$jours_distincts))
write_log(paste("Première date        :", format(stats$premiere_date, "%d/%m/%Y")))
write_log(paste("Dernière date        :", format(stats$derniere_date, "%d/%m/%Y")))
write_log(paste("Montant total        :", format(stats$montant_total, big.mark=" ", scientific=FALSE), "FCFA"))
write_log(paste("Montant moyen        :", format(round(stats$montant_moyen, 0), big.mark=" "), "FCFA"))
write_log("Top 5 montants de recharge :")
for (i in 1:nrow(top_montants)) {
  write_log(sprintf("  %d. %s FCFA — %s recharges", i,
    format(top_montants$montant_ttc[i], big.mark=" "),
    format(top_montants$nb[i], big.mark=" ")))
}
write_log(paste("Durée totale         :", round(as.numeric(difftime(Sys.time(), debut, units="secs")), 2), "secondes"))
write_log(""); write_log(SEPARATOR)
write_log("PROCESSUS TERMINÉ AVEC SUCCÈS — tb_ftth_prepaid_recharges")
write_log(SEPARATOR); write_log(paste("Log :", LOG_FILE))
