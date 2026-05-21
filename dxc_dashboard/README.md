# Dashboard DXC Orange CI — Documentation Technique
## Conception et mise en place d'un tableau de bord de suivi et de performance de l'activité de recouvrement

---

## Architecture Globale

```
Starburst/Trino
      ↓ (Scripts R)
PostgreSQL
      ↓ (Vues matérialisées SQL)
Power BI (4 tables finales)
```

---

## Structure du projet

```
dxc_dashboard/
│
├── scripts_R/
│   ├── load_prepaid.R                  → Chargement parc FTTH prepaid
│   ├── load_postpaid.R                 → Chargement parc FTTH postpaid
│   ├── load_recharges.R                → Chargement rechargements prepaid
│   ├── load_paiements.R                → Chargement paiements factures postpaid
│   ├── Script_Remplissage_R_tb_tts.R   → Chargement appels TTS depuis Excel
│   └── refresh_vues_materialisees.R    → Refresh des 10 vues matérialisées
│
├── scripts_SQL/
│   ├── 01_creation_tables.sql          → Création table tb_reclamations
│   ├── 02_vues_tts_prepaid.sql         → 3 vues TTS Prepaid
│   ├── 03_vues_tts_postpaid.sql        → 3 vues TTS Postpaid
│   └── 04_vues_reclamations.sql        → 4 vues Réclamations
│
├── app_python/
│   └── app_retour_actif.py             → Application Streamlit v8
│
└── mesures_DAX/
    └── mesures_DAX.dax                 → Toutes les mesures Power BI
```

---

## Tables PostgreSQL

| Table | Description | Origine |
|-------|-------------|---------|
| tb_tts | Appels prestataire (août 2025 → mai 2026) | Excel via R |
| tb_reclamations | Réclamations issues de tb_tts | SQL depuis tb_tts |
| tb_ftth_prepaid | Parc clients prepaid (snapshots) | Starburst via R |
| tb_ftth_postpaid | Parc clients postpaid (snapshots) | Starburst via R |
| tb_ftth_prepaid_recharges | Rechargements prepaid | Starburst via R |
| tb_ftth_postpaid_paiements | Paiements factures postpaid | Starburst via R |

---

## Vues Matérialisées (12 au total)

### TTS Prepaid
- mv_tts_parc_prepaid (intermédiaire)
- mv_tts_recharges_prepaid (intermédiaire)
- mv_retour_actif_prepaid ✅ Power BI

### TTS Postpaid
- mv_tts_parc_postpaid (intermédiaire)
- mv_tts_paiements_postpaid (intermédiaire)
- mv_retour_actif_postpaid ✅ Power BI

### Réclamations Prepaid
- mv_recla_parc_prepaid (intermédiaire)
- mv_retour_actif_recla_prepaid ✅ Power BI

### Réclamations Postpaid
- mv_recla_parc_postpaid (intermédiaire)
- mv_retour_actif_recla_postpaid ✅ Power BI

---

## Tables Power BI (4 tables finales)

1. mv_retour_actif_prepaid
2. mv_retour_actif_postpaid
3. mv_retour_actif_recla_prepaid
4. mv_retour_actif_recla_postpaid
+ tb_tts
+ tb_reclamations
+ DimDate (générée en DAX)
+ dim_campagne (table de dimension)

---

## Ordre d'exécution

1. Lancer les scripts R de chargement (load_*.R)
2. Lancer Script_Remplissage_R_tb_tts.R
3. Exécuter 01_creation_tables.sql
4. Exécuter 02_vues_tts_prepaid.sql
5. Exécuter 03_vues_tts_postpaid.sql
6. Exécuter 04_vues_reclamations.sql
7. Lancer refresh_vues_materialisees.R
8. Actualiser Power BI

---

## Connexion PostgreSQL

- Host : localhost
- Port : 5432
- Database : Analyse_perso_churn
- User : postgres

---

## Application Streamlit

Lancement :
```
streamlit run app_retour_actif.py
```

Dépendances :
```
pip install streamlit pandas openpyxl pyodbc
```
