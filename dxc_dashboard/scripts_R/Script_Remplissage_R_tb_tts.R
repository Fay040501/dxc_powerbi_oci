# =========================================================
# Script complet de transfert Excel vers PostgreSQL - tb_tts
# VERSION CORRIGEE + LOGIQUE ND AMELIOREE
# =========================================================

library(DBI)
library(RPostgreSQL)
library(readxl)
library(dplyr)
library(stringr)
library(lubridate)
library(purrr)
library(digest)

# ---------------------------------------------------------
# Configuration des chemins
# ---------------------------------------------------------
base_path <- Sys.getenv("BASE_PATH")
log_path  <- Sys.getenv("LOG_PATH_TTS")

if (!dir.exists(dirname(log_path))) dir.create(dirname(log_path), recursive = TRUE)

# ---------------------------------------------------------
# Fonction de log
# ---------------------------------------------------------
write_log <- function(message) {
  log_message <- paste(Sys.time(), "-", message)
  write(log_message, file = log_path, append = TRUE)
  cat(message, "\n")
}

# ---------------------------------------------------------
# Standardisation des motifs non paiement
# Appliquee au chargement pour eviter de relancer les UPDATE SQL
# ---------------------------------------------------------
motif_mapping <- c(
  # RÉSILIATION
  "DEMANDE RÉSILIATION"                      = "DEMANDE DE RESILIATION",

  # SUSPENSION
  "DEMANDE SUSPENSION"                       = "SUSPENSION A LA DEMANDE DU CLIENT",

  # VOIP
  "VOIP NON ACTIVÉ"                          = "VOIP NON ACTIVE",

  # VOYANTS
  "VOYANTS VERT- PAS DE CONNEXION"           = "VOYANTS VERT - PAS DE CONNEXION",

  # FAIBLE COUVERTURE
  "FAIBLE COUVERTURE RÉSEAU"                 = "FAIBLE COUVERTURE RESEAU",

  # DYSFONCTIONNEMENT MAXIT
  "DYSFONNEMENT PAIEMENT DIGITAL MAXIT"      = "DYSFONCTIONNEMENT PAIEMENT DIGITAL MAXIT",

  # AVANTAGES CÉSARS
  "AVANTAGES CESARS NON RECU"                = "AVANTAGES CÉSARS NON REÇUS",
  "AVANTAGES CÉSARS NON RECU"                = "AVANTAGES CÉSARS NON REÇUS",
  "AVANTAGES CÉSARS NON REÇU"                = "AVANTAGES CÉSARS NON REÇUS",
  "AVANTAGES CESARS NON REÇU"                = "AVANTAGES CÉSARS NON REÇUS",
  "SIGNALISATION AVANTAGES NON REÇU"         = "AVANTAGES CÉSARS NON REÇUS",

  # CONTESTATION DE FACTURE
  "CONTESTATION DE FACTURES"                 = "CONTESTATION DE FACTURE",

  # ETAT RÉCLAMATION
  "ÉTAT DE RECLAMATION DANS LE DÉLAIS"       = "ETAT DE LA RÉCLAMATION DANS LE DÉLAIS",

  # INSTALLATION
  "INSTALLATION NON ÉFFECTUÉE"               = "INSTALLATION NON EFFECTUÉE",
  "PAS ENCORE INSTALLÉ"                      = "INSTALLATION NON EFFECTUÉE",

  # RESTITUTIONS DE JOURS
  "RESTITUTION DE JOURS"                     = "RESTITUTIONS DE JOURS",

  # TRANSFERT NON EFFECTUE
  "TRANSFERT NON EFFECTUÉ"                   = "TRANSFERT NON EFFECTUE",

  # CESSION DE LIGNE
  "DEMANDE CESSION DE LIGNE"                 = "CESSION DE LIGNE",

  # TRANSFERT DE LIGNE / DÉMÉNAGEMENT
  "DÉMÉNAGEMENT"                             = "TRANSFERT DE LIGNE / DÉMÉNAGEMENT",
  "DEMANDE TRANSFERT DE LIGNE"               = "TRANSFERT DE LIGNE / DÉMÉNAGEMENT",
  "DÉPLACEMENT/VOYAGE"                       = "TRANSFERT DE LIGNE / DÉMÉNAGEMENT",
  "DEPLACEMENT / VOYAGE"                     = "TRANSFERT DE LIGNE / DÉMÉNAGEMENT",

  # ERREUR DE PAIEMENT
  "ERREUR DE PAIEMENT"                       = "ERREUR DE CHOIX DE PAIEMENT DU MOIS",

  # DÉJÀ PAYÉ
  "DÉJA PAYÉ"                                = "DÉJÀ PAYÉ"
)

# ---------------------------------------------------------
# Fonction de normalisation d'une valeur brute
# ---------------------------------------------------------
normaliser_valeur <- function(val) {
  if (is.na(val) || is.null(val)) return(NA_character_)
  val <- as.character(val) %>% str_trim()
  if (str_detect(val, regex("e", ignore_case = TRUE))) {
    tryCatch({
      val <- as.character(as.integer(as.numeric(str_replace(val, ",", "."))))
    }, warning = function(w) {},
       error   = function(e) {})
  }
  val <- str_replace_all(val, "[^0-9]", "")
  if (nchar(val) == 0) return(NA_character_)
  return(val)
}

# ---------------------------------------------------------
# Extraction d'un ND Fibre valide depuis une valeur brute
# ---------------------------------------------------------
extraire_nd_fibre <- function(val_brute) {
  val <- normaliser_valeur(val_brute)
  if (is.na(val)) return(NA_character_)
  prefixes <- c("225225", "225", "25")
  for (pfx in prefixes) {
    if (str_starts(val, pfx)) {
      candidat <- str_sub(val, nchar(pfx) + 1)
      if (str_detect(candidat, "^27[2-3][0-9]{7}$")) return(candidat)
    }
  }
  if (str_detect(val, "^27[2-3][0-9]{7}$")) return(val)
  return(NA_character_)
}

# ---------------------------------------------------------
# Recherche d'un ND Fibre dans la colonne contact
# ---------------------------------------------------------
chercher_nd_dans_contact <- function(val_contact) {
  val <- normaliser_valeur(val_contact)
  if (is.na(val)) return(NA_character_)
  prefixes <- c("225225", "225", "25")
  for (pfx in prefixes) {
    if (str_starts(val, pfx)) {
      candidat <- str_sub(val, nchar(pfx) + 1)
      if (str_detect(candidat, "^27[2-3][0-9]{7}$")) return(candidat)
    }
  }
  if (str_detect(val, "^27[2-3][0-9]{7}$")) return(val)
  m <- str_extract(val, "27[2-3][0-9]{7}")
  if (!is.na(m)) return(m)
  return(NA_character_)
}

# ---------------------------------------------------------
# Nettoyage ND principal
# ---------------------------------------------------------
nettoyer_nd <- function(nd_fibre_vec, contact_vec) {
  n <- length(nd_fibre_vec)
  nd_clean  <- character(n)
  nd_source <- character(n)
  for (i in seq_len(n)) {
    nd1 <- extraire_nd_fibre(nd_fibre_vec[i])
    if (!is.na(nd1)) {
      nd_clean[i]  <- nd1
      nd_source[i] <- "nd_fibre"
      next
    }
    nd2 <- chercher_nd_dans_contact(contact_vec[i])
    if (!is.na(nd2)) {
      nd_clean[i]  <- nd2
      nd_source[i] <- "contact_nd"
      next
    }
    nd_clean[i]  <- ifelse(is.na(nd_fibre_vec[i]), "", as.character(nd_fibre_vec[i]))
    nd_source[i] <- "suspect"
  }
  return(list(nd_clean = nd_clean, nd_source = nd_source))
}

# ---------------------------------------------------------
# Colonnes a garder
# ---------------------------------------------------------
cols_keep <- c(
  "StartDate", "FirstResponseDate", "EndDate",
  "BON INTERLOCUTEUR", "COMMENTAIRE", "COMMENTAIRE_PREOCCUPATION",
  "CONTACT", "DISPONIBILITE CLIENT",
  "IDENTITE CLIENT", "IDENTITE DU TELECONSEILLER", "MOTIF NON PAIEMENT",
  "ND_FIBRE", "PREOCCUPATION",
  "CATEGORIE DE NON PAIEMENT", "TYPE DE BASE"
)

# ---------------------------------------------------------
# Normalisation des noms de colonnes
# ---------------------------------------------------------
normalize_colnames <- function(names_vector) {
  names_vector %>%
    tolower() %>%
    str_replace_all("/", "_") %>%
    str_replace_all(" ", "_") %>%
    str_replace_all("'", "") %>%
    str_replace_all("\\(", "") %>%
    str_replace_all("\\)", "")
}

# ---------------------------------------------------------
# Lecture et nettoyage d'un fichier
# ---------------------------------------------------------
read_and_normalize <- function(file_path) {
  tryCatch({
    df_raw <- read_excel(file_path, guess_max = 1000)
    if (nrow(df_raw) == 0) {
      write_log(paste("  Fichier", basename(file_path), "est vide"))
      return(NULL)
    }
    colnames(df_raw) <- normalize_colnames(colnames(df_raw))
    cols_keep_norm   <- normalize_colnames(cols_keep)
    available_cols   <- intersect(cols_keep_norm, colnames(df_raw))
    missing_cols     <- setdiff(cols_keep_norm, colnames(df_raw))
    if (length(missing_cols) > 0) {
      write_log(paste("  Colonnes manquantes dans", basename(file_path), ":",
                      paste(missing_cols, collapse = ", ")))
    }
    df <- df_raw
    for (col in missing_cols) df[[col]] <- NA
    df <- df %>% select(all_of(cols_keep_norm))

    resultat_nd <- nettoyer_nd(df$nd_fibre, df$contact)

    df <- df %>%
      mutate(
        startdate = if ("startdate" %in% names(.)) {
          as.POSIXct(startdate,
                     tryFormats = c("%d/%m/%Y %H:%M", "%Y-%m-%d %H:%M:%S", "%Y-%m-%d"))
        } else NA,
        firstresponsedate = if ("firstresponsedate" %in% names(.)) {
          as.POSIXct(firstresponsedate,
                     tryFormats = c("%d/%m/%Y %H:%M", "%Y-%m-%d %H:%M:%S", "%Y-%m-%d"))
        } else NA,
        enddate = if ("enddate" %in% names(.)) {
          as.POSIXct(enddate,
                     tryFormats = c("%d/%m/%Y %H:%M", "%Y-%m-%d %H:%M:%S", "%Y-%m-%d"))
        } else NA,
        nd_fibre  = if ("nd_fibre" %in% names(.)) as.character(nd_fibre) else NA_character_,
        nd_clean  = resultat_nd$nd_clean,
        nd_source = resultat_nd$nd_source,
        contact         = if ("contact" %in% names(.)) as.character(contact) else NA_character_,
        identite_client = if ("identite_client" %in% names(.)) as.character(identite_client) else NA_character_,
        date_insertion  = as.Date(Sys.time()),
        campagne        = basename(dirname(file_path)),
        fichier         = basename(file_path),

        # CORRECTION : standardisation motifs au chargement
        motif_non_paiement = if ("motif_non_paiement" %in% names(.)) {
          recode(as.character(motif_non_paiement), !!!motif_mapping)
        } else NA_character_
      )

    write_log(paste("  Fichier", basename(file_path), ":", nrow(df), "lignes"))
    return(df)

  }, error = function(e) {
    write_log(paste("ERREUR fichier", basename(file_path), ":", e$message))
    return(NULL)
  })
}

# ---------------------------------------------------------
# Creation du hash unique par ligne
# CORRECTION : tronque a la minute pour eviter les faux doublons
# ---------------------------------------------------------
create_hash <- function(df) {
  df %>%
    rowwise() %>%
    mutate(
      id_hash = digest(
        paste(
          ifelse(is.na(startdate), "NA", format(startdate, "%Y-%m-%d %H:%M")),
          ifelse(is.na(nd_clean),  "NA", nd_clean),
          ifelse(is.na(contact),   "NA", contact),
          ifelse(is.na(identite_client), "NA", identite_client),
          ifelse(is.na(identite_du_teleconseiller), "NA", identite_du_teleconseiller),
          ifelse(is.na(campagne),  "NA", campagne),
          sep = "||"
        ),
        algo = "md5"
      )
    ) %>%
    ungroup()
}

# ---------------------------------------------------------
# Preparation du dataframe pour insertion
# ---------------------------------------------------------
prepare_for_db <- function(df) {
  df %>%
    select(
      startdate,
      firstresponsedate,
      enddate,
      identite_du_teleconseiller,
      identite_client,
      contact,
      nd_fibre,
      nd_clean,
      nd_source,
      bon_interlocuteur,
      disponibilite_client,
      categorie_de_non_paiement,
      motif_non_paiement,
      commentaire,
      preoccupation,
      commentaire_preoccupation,
      type_de_base,
      date_insertion,
      campagne,
      fichier,
      id_hash
    )
}

# ---------------------------------------------------------
# Creation de la table tb_tts
# ---------------------------------------------------------
create_table_tts <- function(con) {
  query <- "
    CREATE TABLE IF NOT EXISTS public.tb_tts (
      id                          SERIAL PRIMARY KEY,
      startdate                   TIMESTAMP,
      firstresponsedate           TIMESTAMP,
      enddate                     TIMESTAMP,
      identite_du_teleconseiller  TEXT,
      identite_client             TEXT,
      contact                     TEXT,
      nd_fibre                    TEXT,
      nd_clean                    TEXT,
      nd_source                   TEXT,
      bon_interlocuteur           TEXT,
      disponibilite_client        TEXT,
      categorie_de_non_paiement   TEXT,
      motif_non_paiement          TEXT,
      commentaire                 TEXT,
      preoccupation               TEXT,
      commentaire_preoccupation   TEXT,
      type_de_base                TEXT,
      date_insertion              DATE,
      campagne                    TEXT,
      fichier                     TEXT,
      id_hash                     TEXT UNIQUE
    );
    CREATE INDEX IF NOT EXISTS idx_tb_tts_nd_clean    ON public.tb_tts(nd_clean);
    CREATE INDEX IF NOT EXISTS idx_tb_tts_nd_source   ON public.tb_tts(nd_source);
    CREATE INDEX IF NOT EXISTS idx_tb_tts_campagne    ON public.tb_tts(campagne);
    CREATE INDEX IF NOT EXISTS idx_tb_tts_date_ins    ON public.tb_tts(date_insertion);
    CREATE INDEX IF NOT EXISTS idx_tb_tts_startdate   ON public.tb_tts(startdate);
    CREATE INDEX IF NOT EXISTS idx_tb_tts_telecons    ON public.tb_tts(identite_du_teleconseiller);
  "
  tryCatch({
    dbExecute(con, query)
    write_log("Table tb_tts creee avec succes (ou deja existante)")
    return(TRUE)
  }, error = function(e) {
    write_log(paste("Erreur creation table :", e$message))
    return(FALSE)
  })
}

# ---------------------------------------------------------
# Fonction principale
# ---------------------------------------------------------
main <- function() {
  tryCatch({

    write_log("=== Debut integration TTS ===")

    write_log("Connexion a la base de donnees...")
    con <- dbConnect(
      PostgreSQL(),
      host     = Sys.getenv("DB_HOST"),
      port     = as.integer(Sys.getenv("DB_PORT")),
      dbname   = Sys.getenv("DB_NAME"),
      user     = Sys.getenv("DB_USER"),
      password = Sys.getenv("DB_PASSWORD")
    )
    write_log("Connexion reussie a PostgreSQL")

    create_table_tts(con)

    write_log("Recherche des fichiers Excel...")
    files <- list.files(
      path        = base_path,
      pattern     = "\\.(xlsx|xls|xlsm)$",
      recursive   = TRUE,
      full.names  = TRUE,
      ignore.case = TRUE
    )
    write_log(paste(length(files), "fichiers detectes"))
    if (length(files) == 0) stop("Aucun fichier Excel trouve dans le dossier specifie.")

    write_log("Fichiers trouves :")
    for (file in files) {
      write_log(paste("  -", basename(file), "dans", basename(dirname(file))))
    }

    write_log("Lecture et normalisation des fichiers...")
    df_list <- list()
    for (file in files) {
      df <- read_and_normalize(file)
      if (!is.null(df) && nrow(df) > 0) df_list[[length(df_list) + 1]] <- df
    }
    if (length(df_list) == 0) stop("Aucun fichier n'a pu etre lu correctement.")

    write_log("Combinaison des donnees...")
    all_cols <- unique(unlist(lapply(df_list, names)))
    df_list_filled <- lapply(df_list, function(df) {
      missing_cols <- setdiff(all_cols, names(df))
      for (col in missing_cols) df[[col]] <- NA
      df[all_cols]
    })
    df_all <- bind_rows(df_list_filled)
    write_log(paste("Total :", nrow(df_all), "lignes chargees depuis", length(df_list), "fichiers"))

    nb_nd_fibre   <- sum(df_all$nd_source == "nd_fibre",   na.rm = TRUE)
    nb_contact_nd <- sum(df_all$nd_source == "contact_nd", na.rm = TRUE)
    nb_suspect    <- sum(df_all$nd_source == "suspect",    na.rm = TRUE)
    write_log(paste("ND valides (nd_fibre)   :", nb_nd_fibre))
    write_log(paste("ND recuperes (contact)  :", nb_contact_nd))
    write_log(paste("ND suspects             :", nb_suspect))

    write_log("Creation des hash uniques...")
    df_all <- create_hash(df_all)
    write_log(paste("Nombre de hash uniques :", n_distinct(df_all$id_hash)))

    df_all <- prepare_for_db(df_all)

    write_log("Preparation de l'insertion...")
    dbWriteTable(
      con,
      name      = "temp_tts_insert",
      value     = df_all,
      temporary = TRUE,
      overwrite = TRUE,
      row.names = FALSE
    )
    write_log("Table temporaire creee")

    query_insert <- "
      INSERT INTO public.tb_tts (
        startdate, firstresponsedate, enddate,
        identite_du_teleconseiller, identite_client, contact,
        nd_fibre, nd_clean, nd_source,
        bon_interlocuteur, disponibilite_client,
        categorie_de_non_paiement, motif_non_paiement,
        commentaire, preoccupation, commentaire_preoccupation,
        type_de_base, date_insertion, campagne, fichier, id_hash
      )
      SELECT
        startdate, firstresponsedate, enddate,
        identite_du_teleconseiller, identite_client, contact,
        nd_fibre, nd_clean, nd_source,
        bon_interlocuteur, disponibilite_client,
        categorie_de_non_paiement, motif_non_paiement,
        commentaire, preoccupation, commentaire_preoccupation,
        type_de_base, date_insertion, campagne, fichier, id_hash
      FROM temp_tts_insert
      ON CONFLICT (id_hash) DO NOTHING
    "
    n_inserted <- dbExecute(con, query_insert)
    write_log(paste("Insertion terminee :", n_inserted, "nouvelles lignes inserees"))

    if (n_inserted > 0) {
      stats_camp <- dbGetQuery(con, "
        SELECT campagne, COUNT(*) as nb
        FROM public.tb_tts
        WHERE date_insertion = CURRENT_DATE
        GROUP BY campagne
        ORDER BY nb DESC
      ")
      if (nrow(stats_camp) > 0) {
        write_log("Lignes inserees aujourd'hui par campagne :")
        for (i in 1:nrow(stats_camp)) {
          write_log(paste("  -", stats_camp$campagne[i], ":", stats_camp$nb[i], "lignes"))
        }
      }
    }

    stats_suspect <- dbGetQuery(con, "
      SELECT identite_du_teleconseiller, COUNT(*) as nb_suspects
      FROM public.tb_tts
      WHERE nd_source = 'suspect'
      AND date_insertion = CURRENT_DATE
      GROUP BY identite_du_teleconseiller
      ORDER BY nb_suspects DESC
      LIMIT 10
    ")
    if (nrow(stats_suspect) > 0) {
      write_log("Top fauteurs du jour (nd_source = suspect) :")
      for (i in 1:nrow(stats_suspect)) {
        write_log(paste("  -", stats_suspect$identite_du_teleconseiller[i],
                        ":", stats_suspect$nb_suspects[i], "suspects"))
      }
    }

    total_rows <- dbGetQuery(con, "SELECT COUNT(*) as nb FROM public.tb_tts")$nb
    write_log(paste("Total dans la table apres operation :", total_rows, "lignes"))

    stats_nd <- dbGetQuery(con, "
      SELECT
        COUNT(*) as total,
        SUM(CASE WHEN nd_source = 'nd_fibre'   THEN 1 ELSE 0 END) as nd_fibre,
        SUM(CASE WHEN nd_source = 'contact_nd' THEN 1 ELSE 0 END) as contact_nd,
        SUM(CASE WHEN nd_source = 'suspect'    THEN 1 ELSE 0 END) as suspect
      FROM public.tb_tts
    ")
    write_log(paste("Stats globales ND — nd_fibre:", stats_nd$nd_fibre,
                    "| contact_nd:", stats_nd$contact_nd,
                    "| suspect:", stats_nd$suspect))

    dbDisconnect(con)
    write_log("Connexion fermee")
    write_log("=== Fin integration TTS ===")

    return(list(
      success        = TRUE,
      rows_processed = nrow(df_all),
      new_rows       = n_inserted,
      timestamp      = Sys.time()
    ))

  }, error = function(e) {
    write_log(paste("ERREUR dans main() :", e$message))
    write_log(paste("Trace :", paste(traceback(), collapse = "\n")))
    if (exists("con")) {
      try(dbDisconnect(con), silent = TRUE)
      write_log("Connexion fermee suite a erreur")
    }
    return(list(success = FALSE, error = e$message, timestamp = Sys.time()))
  })
}

# ---------------------------------------------------------
# Execution
# ---------------------------------------------------------
if (interactive()) {
  resultat <- main()
  print(resultat)
} else {
  resultat <- main()
  if (resultat$success) {
    quit(save = "no", status = 0)
  } else {
    quit(save = "no", status = 1)
  }
}
