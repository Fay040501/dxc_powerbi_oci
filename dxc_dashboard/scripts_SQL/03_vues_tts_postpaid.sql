-- ============================================================
-- VUES MATERIALISEES — TTS POSTPAID
-- Etape 1 : TTS x Parc Postpaid
-- Etape 2 : TTS x Parc x Paiements Factures
-- Etape 3 : Agregation finale Power BI
-- ============================================================

-- ============================================================
-- ETAPE 1 — TTS x Parc Postpaid
-- ============================================================
CREATE MATERIALIZED VIEW mv_tts_parc_postpaid AS

SELECT
    t.nd_clean                                          AS nd,
    DATE(t.startdate)                                   AS jour,
    DATE_TRUNC('month', t.startdate)                    AS mois_appel,
    t.campagne,
    t.disponibilite_client,
    CASE
        WHEN p_jour.etat = 'Actif'
        THEN 1 ELSE 0
    END                                                 AS est_actif_au_appel,
    CASE
        WHEN p_actuel.etat = 'Actif'
        THEN 1 ELSE 0
    END                                                 AS est_actif_aujourdhui
FROM (
    SELECT DISTINCT ON (nd_clean, DATE(startdate))
        nd_clean, startdate, campagne, disponibilite_client
    FROM tb_tts
    WHERE campagne IN ('FACTURE OUVERTE', 'SUSPENSION')
      AND nd_clean IS NOT NULL
      AND nd_clean != ''
      AND startdate IS NOT NULL
    ORDER BY
        nd_clean, DATE(startdate),
        CASE disponibilite_client
            WHEN 'Le client a décroché'                     THEN 1
            WHEN 'Le numéro du client sonne en vain'        THEN 2
            WHEN 'Le numéro du client n''est pas joignable' THEN 3
            ELSE 4
        END ASC,
        startdate
) t
LEFT JOIN (
    SELECT nd, etat, date_id
    FROM tb_ftth_postpaid
) p_jour ON t.nd_clean = p_jour.nd
        AND p_jour.date_id = DATE(t.startdate)
LEFT JOIN (
    SELECT DISTINCT ON (nd) nd, etat
    FROM tb_ftth_postpaid
    ORDER BY nd, date_id DESC
) p_actuel ON t.nd_clean = p_actuel.nd;

CREATE INDEX idx_tts_parc_postpaid_nd   ON mv_tts_parc_postpaid(nd);
CREATE INDEX idx_tts_parc_postpaid_jour ON mv_tts_parc_postpaid(jour);
CREATE INDEX idx_tts_parc_postpaid_mois ON mv_tts_parc_postpaid(mois_appel);
CREATE INDEX idx_tts_parc_postpaid_camp ON mv_tts_parc_postpaid(campagne);


-- ============================================================
-- ETAPE 2 — TTS x Parc x Paiements Factures
-- ============================================================
CREATE MATERIALIZED VIEW mv_tts_paiements_postpaid AS

SELECT
    p.nd, p.jour, p.mois_appel, p.campagne,
    p.disponibilite_client,
    p.est_actif_au_appel,
    p.est_actif_aujourdhui,
    CASE
        WHEN f.nd IS NOT NULL AND f.statut_fact = 'paye'
        THEN 1 ELSE 0
    END                                                 AS a_paye,
    COALESCE(f.mnt_fact_mois_m, 0)                      AS montant_paiement
FROM mv_tts_parc_postpaid p
LEFT JOIN (
    SELECT DISTINCT ON (nd)
        nd, statut_fact, mnt_fact_mois_m
    FROM tb_ftth_postpaid_paiements
    WHERE date_paiement >= DATE_TRUNC('month', CURRENT_DATE)
      AND date_paiement <  DATE_TRUNC('month', CURRENT_DATE) + INTERVAL '1 month'
    ORDER BY nd, date_paiement DESC
) f ON p.nd = f.nd;

CREATE INDEX idx_tts_paiements_nd   ON mv_tts_paiements_postpaid(nd);
CREATE INDEX idx_tts_paiements_jour ON mv_tts_paiements_postpaid(jour);
CREATE INDEX idx_tts_paiements_mois ON mv_tts_paiements_postpaid(mois_appel);
CREATE INDEX idx_tts_paiements_camp ON mv_tts_paiements_postpaid(campagne);


-- ============================================================
-- ETAPE 3 — Agregation finale Power BI
-- ============================================================
CREATE MATERIALIZED VIEW mv_retour_actif_postpaid AS

SELECT
    jour, mois_appel, campagne,
    COUNT(DISTINCT nd)                                              AS nb_contactes,
    SUM(CASE WHEN disponibilite_client = 'Le client a décroché'
             THEN 1 ELSE 0 END)                                     AS nb_decroches,
    SUM(est_actif_au_appel)                                         AS nb_actifs_au_appel,
    SUM(est_actif_aujourdhui)                                       AS nb_actifs_aujourdhui,
    COUNT(DISTINCT CASE WHEN a_paye = 1 THEN nd END)                AS nb_payes,
    SUM(montant_paiement)                                           AS montant_total,
    COUNT(DISTINCT CASE WHEN disponibilite_client = 'Le client a décroché'
             AND a_paye = 1 THEN nd END)                            AS nb_decroche_et_paye,
    COUNT(DISTINCT CASE WHEN disponibilite_client = 'Le client a décroché'
             AND est_actif_aujourdhui = 1 THEN nd END)              AS nb_decroche_et_actif,
    ROUND(COUNT(DISTINCT CASE WHEN a_paye = 1 THEN nd END) * 100.0 /
          NULLIF(COUNT(DISTINCT nd), 0), 1)                         AS taux_retour,
    ROUND(SUM(CASE WHEN disponibilite_client = 'Le client a décroché'
                   THEN 1 ELSE 0 END) * 100.0 /
          NULLIF(COUNT(DISTINCT nd), 0), 1)                         AS taux_decroche,
    ROUND(SUM(est_actif_au_appel) * 100.0 /
          NULLIF(COUNT(DISTINCT nd), 0), 1)                         AS taux_actif_au_appel,
    ROUND(SUM(est_actif_aujourdhui) * 100.0 /
          NULLIF(COUNT(DISTINCT nd), 0), 1)                         AS taux_actif_aujourdhui
FROM mv_tts_paiements_postpaid
GROUP BY jour, mois_appel, campagne;

CREATE INDEX idx_mv_retour_postpaid_jour     ON mv_retour_actif_postpaid(jour);
CREATE INDEX idx_mv_retour_postpaid_mois     ON mv_retour_actif_postpaid(mois_appel);
CREATE INDEX idx_mv_retour_postpaid_campagne ON mv_retour_actif_postpaid(campagne);
