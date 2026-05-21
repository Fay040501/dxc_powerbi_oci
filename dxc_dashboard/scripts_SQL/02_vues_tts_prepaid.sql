-- ============================================================
-- VUES MATERIALISEES — TTS PREPAID
-- Etape 1 : TTS x Parc Prepaid
-- Etape 2 : TTS x Parc x Rechargements
-- Etape 3 : Agregation finale Power BI
-- ============================================================

-- ============================================================
-- ETAPE 1 — TTS x Parc Prepaid
-- ============================================================
CREATE MATERIALIZED VIEW mv_tts_parc_prepaid AS

SELECT
    t.nd_clean                                          AS nd,
    DATE(t.startdate)                                   AS jour,
    DATE_TRUNC('month', t.startdate)                    AS mois_appel,
    t.campagne,
    t.disponibilite_client,
    CASE
        WHEN TO_DATE(p_jour.date_expiration, 'DD/MM/YYYY') > DATE(t.startdate)
        THEN 1 ELSE 0
    END                                                 AS est_actif_au_appel,
    CASE
        WHEN TO_DATE(p_actuel.date_expiration, 'DD/MM/YYYY') > CURRENT_DATE
        THEN 1 ELSE 0
    END                                                 AS est_actif_aujourdhui
FROM (
    SELECT DISTINCT ON (nd_clean, DATE(startdate))
        nd_clean, startdate, campagne, disponibilite_client
    FROM tb_tts
    WHERE campagne NOT IN ('FACTURE OUVERTE', 'SUSPENSION')
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
    SELECT nd, date_expiration, date_id
    FROM tb_ftth_prepaid
) p_jour ON t.nd_clean = p_jour.nd
        AND p_jour.date_id = DATE(t.startdate)
LEFT JOIN (
    SELECT DISTINCT ON (nd) nd, date_expiration
    FROM tb_ftth_prepaid
    ORDER BY nd, date_id DESC
) p_actuel ON t.nd_clean = p_actuel.nd;

CREATE INDEX idx_tts_parc_prepaid_nd   ON mv_tts_parc_prepaid(nd);
CREATE INDEX idx_tts_parc_prepaid_jour ON mv_tts_parc_prepaid(jour);
CREATE INDEX idx_tts_parc_prepaid_mois ON mv_tts_parc_prepaid(mois_appel);
CREATE INDEX idx_tts_parc_prepaid_camp ON mv_tts_parc_prepaid(campagne);


-- ============================================================
-- ETAPE 2 — TTS x Parc x Rechargements
-- ============================================================
CREATE MATERIALIZED VIEW mv_tts_recharges_prepaid AS

SELECT
    p.nd, p.jour, p.mois_appel, p.campagne,
    p.disponibilite_client,
    p.est_actif_au_appel,
    p.est_actif_aujourdhui,
    CASE WHEN r.nd IS NOT NULL THEN 1 ELSE 0 END        AS a_recharge,
    COALESCE(r.montant_ttc, 0)                          AS montant_recharge
FROM mv_tts_parc_prepaid p
LEFT JOIN (
    SELECT nd, SUM(montant_ttc) AS montant_ttc
    FROM tb_ftth_prepaid_recharges
    WHERE date_rechargement >= DATE_TRUNC('month', CURRENT_DATE)
      AND date_rechargement <  DATE_TRUNC('month', CURRENT_DATE) + INTERVAL '1 month'
    GROUP BY nd
) r ON p.nd = r.nd;

CREATE INDEX idx_tts_recharges_nd   ON mv_tts_recharges_prepaid(nd);
CREATE INDEX idx_tts_recharges_jour ON mv_tts_recharges_prepaid(jour);
CREATE INDEX idx_tts_recharges_mois ON mv_tts_recharges_prepaid(mois_appel);
CREATE INDEX idx_tts_recharges_camp ON mv_tts_recharges_prepaid(campagne);


-- ============================================================
-- ETAPE 3 — Agregation finale Power BI
-- ============================================================
CREATE MATERIALIZED VIEW mv_retour_actif_prepaid AS

SELECT
    jour, mois_appel, campagne,
    COUNT(DISTINCT nd)                                          AS nb_contactes,
    SUM(CASE WHEN disponibilite_client = 'Le client a décroché'
             THEN 1 ELSE 0 END)                                 AS nb_decroches,
    SUM(est_actif_au_appel)                                     AS nb_actifs_au_appel,
    SUM(est_actif_aujourdhui)                                   AS nb_actifs_aujourdhui,
    COUNT(DISTINCT CASE WHEN a_recharge = 1 THEN nd END)        AS nb_recharges,
    SUM(montant_recharge)                                       AS montant_total,
    COUNT(DISTINCT CASE WHEN disponibilite_client = 'Le client a décroché'
             AND a_recharge = 1 THEN nd END)                    AS nb_decroche_et_recharge,
    COUNT(DISTINCT CASE WHEN disponibilite_client = 'Le client a décroché'
             AND est_actif_aujourdhui = 1 THEN nd END)          AS nb_decroche_et_actif,
    ROUND(COUNT(DISTINCT CASE WHEN a_recharge = 1 THEN nd END) * 100.0 /
          NULLIF(COUNT(DISTINCT nd), 0), 1)                     AS taux_retour,
    ROUND(SUM(CASE WHEN disponibilite_client = 'Le client a décroché'
                   THEN 1 ELSE 0 END) * 100.0 /
          NULLIF(COUNT(DISTINCT nd), 0), 1)                     AS taux_decroche,
    ROUND(SUM(est_actif_au_appel) * 100.0 /
          NULLIF(COUNT(DISTINCT nd), 0), 1)                     AS taux_actif_au_appel,
    ROUND(SUM(est_actif_aujourdhui) * 100.0 /
          NULLIF(COUNT(DISTINCT nd), 0), 1)                     AS taux_actif_aujourdhui
FROM mv_tts_recharges_prepaid
GROUP BY jour, mois_appel, campagne;

CREATE INDEX idx_mv_retour_prepaid_jour     ON mv_retour_actif_prepaid(jour);
CREATE INDEX idx_mv_retour_prepaid_mois     ON mv_retour_actif_prepaid(mois_appel);
CREATE INDEX idx_mv_retour_prepaid_campagne ON mv_retour_actif_prepaid(campagne);
