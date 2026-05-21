# ============================================================
# REFRESH DES VUES MATERIALISEES — DXC Orange CI
# A lancer après chaque chargement de données
# ============================================================

library(DBI)
library(RPostgreSQL)

# ---------------------------------------------------------
# Configuration connexion
# ---------------------------------------------------------
DB_HOST     <- "localhost"
DB_PORT     <- 5432
DB_NAME     <- "Analyse_perso_churn"
DB_USER     <- "postgres"
DB_PASSWORD <- "1234"

# ---------------------------------------------------------
# Fonction de log
# ---------------------------------------------------------
write_log <- function(message) {
  log_message <- paste(Sys.time(), "-", message)
  cat(log_message, "\n")
}

# ---------------------------------------------------------
# Vues à rafraîchir dans l'ordre de dépendance
# ---------------------------------------------------------
vues <- list(

  # Prepaid TTS
  list(vue = "mv_tts_parc_prepaid",        groupe = "TTS Prepaid — Etape 1"),
  list(vue = "mv_tts_recharges_prepaid",    groupe = "TTS Prepaid — Etape 2"),
  list(vue = "mv_retour_actif_prepaid",     groupe = "TTS Prepaid — Etape 3 (Power BI)"),

  # Postpaid TTS
  list(vue = "mv_tts_parc_postpaid",        groupe = "TTS Postpaid — Etape 1"),
  list(vue = "mv_tts_paiements_postpaid",   groupe = "TTS Postpaid — Etape 2"),
  list(vue = "mv_retour_actif_postpaid",    groupe = "TTS Postpaid — Etape 3 (Power BI)"),

  # Reclamations Prepaid
  list(vue = "mv_recla_parc_prepaid",       groupe = "Reclamations Prepaid — Etape 1"),
  list(vue = "mv_retour_actif_recla_prepaid", groupe = "Reclamations Prepaid — Etape 2 (Power BI)"),

  # Reclamations Postpaid
  list(vue = "mv_recla_parc_postpaid",      groupe = "Reclamations Postpaid — Etape 1"),
  list(vue = "mv_retour_actif_recla_postpaid", groupe = "Reclamations Postpaid — Etape 2 (Power BI)")
)

# ---------------------------------------------------------
# Fonction principale
# ---------------------------------------------------------
main <- function() {

  write_log("=== DEBUT REFRESH VUES MATERIALISEES ===")
  t_start <- Sys.time()

  # Connexion PostgreSQL
  write_log("Connexion a la base de donnees...")
  tryCatch({
    con <- dbConnect(
      PostgreSQL(),
      host     = DB_HOST,
      port     = DB_PORT,
      dbname   = DB_NAME,
      user     = DB_USER,
      password = DB_PASSWORD
    )
    write_log("Connexion reussie")
  }, error = function(e) {
    write_log(paste("ERREUR connexion :", e$message))
    stop(e)
  })

  # Compteurs
  nb_succes <- 0
  nb_erreur <- 0

  # Refresh de chaque vue
  for (item in vues) {
    vue    <- item$vue
    groupe <- item$groupe

    write_log(paste("---", groupe))
    write_log(paste("Refresh :", vue))

    t0 <- Sys.time()
    tryCatch({
      dbExecute(con, paste0("REFRESH MATERIALIZED VIEW ", vue, ";"))
      elapsed <- round(as.numeric(Sys.time() - t0), 1)
      write_log(paste("✅ OK en", elapsed, "secondes"))
      nb_succes <- nb_succes + 1
    }, error = function(e) {
      write_log(paste("❌ ERREUR :", e$message))
      nb_erreur <- nb_erreur + 1
    })
  }

  # Résumé
  t_total <- round(as.numeric(Sys.time() - t_start), 1)
  write_log("=========================================")
  write_log(paste("TERMINE en", t_total, "secondes"))
  write_log(paste("Succes :", nb_succes, "/ Erreurs :", nb_erreur))
  write_log("=== FIN REFRESH VUES MATERIALISEES ===")

  # Fermeture connexion
  dbDisconnect(con)
  write_log("Connexion fermee")

  return(list(
    succes    = nb_succes,
    erreurs   = nb_erreur,
    duree     = t_total,
    timestamp = Sys.time()
  ))
}

# ---------------------------------------------------------
# Execution
# ---------------------------------------------------------
resultat <- main()
print(resultat)
