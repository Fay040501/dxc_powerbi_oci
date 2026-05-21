-- ============================================================
-- VUES MATERIALISEES — RECLAMATIONS PREPAID
-- ============================================================

CREATE MATERIALIZED VIEW mv_recla_parc_prepaid AS

SELECT
    r.nd_clean                                              AS nd,
    DATE(r.startdate)                                       AS jour,
    DATE_TRUNC('month', r.startdate)                        AS mois_recla,
    r.campagne,
    r.statut_appel,
    r.statut_traitement,
    DATE_PART('day', r.date_assignation - r.startdate)      AS delai_assignation,
    DATE_PART('day', r.date_traitement - r.startdate)       AS delai_traitement,
    CASE
        WHEN TO_DATE(p_jour.date_expiration, 'DD/MM/YYYY') > DATE(r.startdate)
        THEN 1 ELSE 0
    END                                                     AS est_actif_au_appel,
    CASE
        WHEN TO_DATE(p_actuel.date_expiration, 'DD/MM/YYYY') > CURRENT_DATE
        THEN 1 ELSE 0
    END                                                     AS est_actif_aujourdhui,
    CASE WHEN rech.nd IS NOT NULL THEN 1 ELSE 0 END         AS a_recharge,
    COALESCE(rech.montant_ttc, 0)                           AS montant_recharge
FROM (
    SELECT DISTINCT ON (nd_clean, DATE(startdate))
        nd_clean, startdate, campagne,
        statut_appel, statut_traitement,
        date_assignation, date_traitement
    FROM tb_reclamations
    WHERE campagne NOT IN ('FACTURE OUVERTE', 'SUSPENSION')
      AND nd_clean IS NOT NULL
      AND nd_clean != ''
      AND startdate IS NOT NULL
    ORDER BY nd_clean, DATE(startdate),
        CASE statut_traitement
            WHEN 'TRAITE'      THEN 1
            WHEN 'ASSIGNE'     THEN 2
            WHEN 'NON ASSIGNE' THEN 3
            ELSE 4
        END ASC,
        startdate DESC
) r
LEFT JOIN (
    SELECT nd, date_expiration, date_id FROM tb_ftth_prepaid
) p_jour ON r.nd_clean = p_jour.nd AND p_jour.date_id = DATE(r.startdate)
LEFT JOIN (
    SELECT DISTINCT ON (nd) nd, date_expiration
    FROM tb_ftth_prepaid ORDER BY nd, date_id DESC
) p_actuel ON r.nd_clean = p_actuel.nd
LEFT JOIN (
    SELECT nd, SUM(montant_ttc) AS montant_ttc
    FROM tb_ftth_prepaid_recharges
    WHERE date_rechargement >= DATE_TRUNC('month', CURRENT_DATE)
      AND date_rechargement <  DATE_TRUNC('month', CURRENT_DATE) + INTERVAL '1 month'
    GROUP BY nd
) rech ON r.nd_clean = rech.nd;

CREATE INDEX idx_recla_parc_prepaid_nd   ON mv_recla_parc_prepaid(nd);
CREATE INDEX idx_recla_parc_prepaid_jour ON mv_recla_parc_prepaid(jour);
CREATE INDEX idx_recla_parc_prepaid_mois ON mv_recla_parc_prepaid(mois_recla);
CREATE INDEX idx_recla_parc_prepaid_camp ON mv_recla_parc_prepaid(campagne);


-- ============================================================
-- Agregation finale Reclamations Prepaid
-- ============================================================
CREATE MATERIALIZED VIEW mv_retour_actif_recla_prepaid AS

SELECT
    jour, mois_recla, campagne,
    COUNT(DISTINCT nd)                                              AS nb_reclamations,
    COUNT(DISTINCT CASE WHEN statut_traitement = 'TRAITE'
                        THEN nd END)                                AS nb_traites,
    COUNT(DISTINCT CASE WHEN statut_traitement = 'ASSIGNE'
                        THEN nd END)                                AS nb_assignes,
    COUNT(DISTINCT CASE WHEN statut_traitement = 'NON ASSIGNE'
                        THEN nd END)                                AS nb_non_assignes,
    COUNT(DISTINCT CASE WHEN statut_appel = 'DECROCHE'
                        THEN nd END)                                AS nb_decroches,
    SUM(est_actif_au_appel)                                         AS nb_actifs_au_appel,
    SUM(est_actif_aujourdhui)                                       AS nb_actifs_aujourdhui,
    COUNT(DISTINCT CASE WHEN a_recharge = 1 THEN nd END)            AS nb_recharges,
    SUM(montant_recharge)                                           AS montant_total,
    COUNT(DISTINCT CASE WHEN statut_appel = 'DECROCHE'
                        AND a_recharge = 1 THEN nd END)             AS nb_decroche_et_recharge,
    COUNT(DISTINCT CASE WHEN statut_appel = 'DECROCHE'
                        AND est_actif_aujourdhui = 1 THEN nd END)   AS nb_decroche_et_actif,
    COUNT(DISTINCT CASE WHEN statut_traitement = 'TRAITE'
                        AND a_recharge = 1 THEN nd END)             AS nb_traite_et_recharge,
    ROUND(AVG(delai_assignation)::numeric, 1)                       AS delai_moyen_assignation,
    ROUND(AVG(delai_traitement)::numeric, 1)                        AS delai_moyen_traitement,
    ROUND(COUNT(DISTINCT CASE WHEN statut_traitement = 'TRAITE'
                              THEN nd END) * 100.0 /
          NULLIF(COUNT(DISTINCT nd), 0), 1)                         AS taux_traitement,
    ROUND(COUNT(DISTINCT CASE WHEN statut_appel = 'DECROCHE'
                              THEN nd END) * 100.0 /
          NULLIF(COUNT(DISTINCT nd), 0), 1)                         AS taux_decroche,
    ROUND(COUNT(DISTINCT CASE WHEN a_recharge = 1
                              THEN nd END) * 100.0 /
          NULLIF(COUNT(DISTINCT nd), 0), 1)                         AS taux_retour,
    ROUND(SUM(est_actif_aujourdhui) * 100.0 /
          NULLIF(COUNT(DISTINCT nd), 0), 1)                         AS taux_actif_aujourdhui
FROM mv_recla_parc_prepaid
GROUP BY jour, mois_recla, campagne;

CREATE INDEX idx_mv_recla_prepaid_jour ON mv_retour_actif_recla_prepaid(jour);
CREATE INDEX idx_mv_recla_prepaid_mois ON mv_retour_actif_recla_prepaid(mois_recla);
CREATE INDEX idx_mv_recla_prepaid_camp ON mv_retour_actif_recla_prepaid(campagne);


-- ============================================================
-- VUES MATERIALISEES — RECLAMATIONS POSTPAID
-- ============================================================

CREATE MATERIALIZED VIEW mv_recla_parc_postpaid AS

SELECT
    r.nd_clean                                              AS nd,
    DATE(r.startdate)                                       AS jour,
    DATE_TRUNC('month', r.startdate)                        AS mois_recla,
    r.campagne,
    r.statut_appel,
    r.statut_traitement,
    DATE_PART('day', r.date_assignation - r.startdate)      AS delai_assignation,
    DATE_PART('day', r.date_traitement - r.startdate)       AS delai_traitement,
    CASE WHEN p_jour.etat = 'Actif' THEN 1 ELSE 0 END       AS est_actif_au_appel,
    CASE WHEN p_actuel.etat = 'Actif' THEN 1 ELSE 0 END     AS est_actif_aujourdhui,
    CASE WHEN f.nd IS NOT NULL AND f.statut_fact = 'paye'
         THEN 1 ELSE 0 END                                  AS a_paye,
    COALESCE(f.mnt_fact_mois_m, 0)                          AS montant_paiement
FROM (
    SELECT DISTINCT ON (nd_clean, DATE(startdate))
        nd_clean, startdate, campagne,
        statut_appel, statut_traitement,
        date_assignation, date_traitement
    FROM tb_reclamations
    WHERE campagne IN ('FACTURE OUVERTE', 'SUSPENSION')
      AND nd_clean IS NOT NULL
      AND nd_clean != ''
      AND startdate IS NOT NULL
    ORDER BY nd_clean, DATE(startdate),
        CASE statut_traitement
            WHEN 'TRAITE'      THEN 1
            WHEN 'ASSIGNE'     THEN 2
            WHEN 'NON ASSIGNE' THEN 3
            ELSE 4
        END ASC,
        startdate DESC
) r
LEFT JOIN (
    SELECT nd, etat, date_id FROM tb_ftth_postpaid
) p_jour ON r.nd_clean = p_jour.nd AND p_jour.date_id = DATE(r.startdate)
LEFT JOIN (
    SELECT DISTINCT ON (nd) nd, etat
    FROM tb_ftth_postpaid ORDER BY nd, date_id DESC
) p_actuel ON r.nd_clean = p_actuel.nd
LEFT JOIN (
    SELECT DISTINCT ON (nd) nd, statut_fact, mnt_fact_mois_m
    FROM tb_ftth_postpaid_paiements
    WHERE date_paiement >= DATE_TRUNC('month', CURRENT_DATE)
      AND date_paiement <  DATE_TRUNC('month', CURRENT_DATE) + INTERVAL '1 month'
    ORDER BY nd, date_paiement DESC
) f ON r.nd_clean = f.nd;

CREATE INDEX idx_recla_parc_postpaid_nd   ON mv_recla_parc_postpaid(nd);
CREATE INDEX idx_recla_parc_postpaid_jour ON mv_recla_parc_postpaid(jour);
CREATE INDEX idx_recla_parc_postpaid_mois ON mv_recla_parc_postpaid(mois_recla);
CREATE INDEX idx_recla_parc_postpaid_camp ON mv_recla_parc_postpaid(campagne);


-- ============================================================
-- Agregation finale Reclamations Postpaid
-- ============================================================
CREATE MATERIALIZED VIEW mv_retour_actif_recla_postpaid AS

SELECT
    jour, mois_recla, campagne,
    COUNT(DISTINCT nd)                                              AS nb_reclamations,
    COUNT(DISTINCT CASE WHEN statut_traitement = 'TRAITE'
                        THEN nd END)                                AS nb_traites,
    COUNT(DISTINCT CASE WHEN statut_traitement = 'ASSIGNE'
                        THEN nd END)                                AS nb_assignes,
    COUNT(DISTINCT CASE WHEN statut_traitement = 'NON ASSIGNE'
                        THEN nd END)                                AS nb_non_assignes,
    COUNT(DISTINCT CASE WHEN statut_appel = 'DECROCHE'
                        THEN nd END)                                AS nb_decroches,
    SUM(est_actif_au_appel)                                         AS nb_actifs_au_appel,
    SUM(est_actif_aujourdhui)                                       AS nb_actifs_aujourdhui,
    COUNT(DISTINCT CASE WHEN a_paye = 1 THEN nd END)                AS nb_payes,
    SUM(montant_paiement)                                           AS montant_total,
    COUNT(DISTINCT CASE WHEN statut_appel = 'DECROCHE'
                        AND a_paye = 1 THEN nd END)                 AS nb_decroche_et_paye,
    COUNT(DISTINCT CASE WHEN statut_appel = 'DECROCHE'
                        AND est_actif_aujourdhui = 1 THEN nd END)   AS nb_decroche_et_actif,
    COUNT(DISTINCT CASE WHEN statut_traitement = 'TRAITE'
                        AND a_paye = 1 THEN nd END)                 AS nb_traite_et_paye,
    ROUND(AVG(delai_assignation)::numeric, 1)                       AS delai_moyen_assignation,
    ROUND(AVG(delai_traitement)::numeric, 1)                        AS delai_moyen_traitement,
    ROUND(COUNT(DISTINCT CASE WHEN statut_traitement = 'TRAITE'
                              THEN nd END) * 100.0 /
          NULLIF(COUNT(DISTINCT nd), 0), 1)                         AS taux_traitement,
    ROUND(COUNT(DISTINCT CASE WHEN statut_appel = 'DECROCHE'
                              THEN nd END) * 100.0 /
          NULLIF(COUNT(DISTINCT nd), 0), 1)                         AS taux_decroche,
    ROUND(COUNT(DISTINCT CASE WHEN a_paye = 1
                              THEN nd END) * 100.0 /
          NULLIF(COUNT(DISTINCT nd), 0), 1)                         AS taux_retour,
    ROUND(SUM(est_actif_aujourdhui) * 100.0 /
          NULLIF(COUNT(DISTINCT nd), 0), 1)                         AS taux_actif_aujourdhui
FROM mv_recla_parc_postpaid
GROUP BY jour, mois_recla, campagne;

CREATE INDEX idx_mv_recla_postpaid_jour ON mv_retour_actif_recla_postpaid(jour);
CREATE INDEX idx_mv_recla_postpaid_mois ON mv_retour_actif_recla_postpaid(mois_recla);
CREATE INDEX idx_mv_recla_postpaid_camp ON mv_retour_actif_recla_postpaid(campagne);
