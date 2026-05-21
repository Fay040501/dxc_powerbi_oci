-- ============================================================
-- CREATION DE LA TABLE tb_reclamations
-- A partir de tb_tts après chargement
-- ============================================================

DROP TABLE IF EXISTS tb_reclamations CASCADE;

CREATE TABLE tb_reclamations AS
SELECT
    id_hash,
    startdate,
    nd_clean,
    identite_client,
    contact,
    disponibilite_client,
    categorie_de_non_paiement,
    motif_non_paiement,
    commentaire,
    campagne,
    NULL::text          AS statut_appel,
    NULL::text          AS motif_reel,
    NULL::text          AS niveau,
    NULL::text          AS commentaire_bo,
    NULL::text          AS zone_client,
    NULL::text          AS assigne_a,
    'NON ASSIGNE'::text AS statut_traitement,
    NULL::timestamp     AS date_assignation,
    NULL::timestamp     AS date_traitement,
    NULL::text          AS sous_motif,
    NULL::text          AS id_dossier
FROM tb_tts
WHERE categorie_de_non_paiement IN ('DEMANDE DE RESILIATION', 'CHURN')
   OR motif_non_paiement IS NOT NULL;

ALTER TABLE tb_reclamations ADD PRIMARY KEY (id_hash);
