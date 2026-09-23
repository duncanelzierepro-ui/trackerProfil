# trackerProfil : suivi des licences Dataiku DSS

Chaque mois, une photo des utilisateurs Dataiku DSS 14 (environ 180 comptes) est prise :
ADS propriétaire, type de licence, dernière connexion et anomalies. Elle est historisée
dans PostgreSQL puis restituée dans Qlik Sense.

```
Dataiku (scénario mensuel)         PostgreSQL (schéma dss_licences)                Qlik Sense
recette extraction_licences ──►  stg_*  ── p_charger_snapshot() ──►  fait_*_mois  ──►  vues v_qlik_*
  (API DSS + référentiels ref_*)  (écrasées)                          dim_utilisateur     + section access
                                                                      agg_licence_mois    par ADS
                                            p_purger_rgpd() : données nominatives > 6 mois
```

## Contenu

| Fichier | Rôle |
|---|---|
| `sql/01_schema.sql` | Tables : référentiels `ref_*`, `dim_utilisateur`, faits `fait_*_mois`, agrégat `agg_licence_mois` |
| `sql/02_procedures.sql` | `p_charger_snapshot()` (historisation idempotente), `p_purger_rgpd()` |
| `sql/03_vues.sql` | Vues `v_qlik_*` pour Qlik, `v_etat_courant` pour la consultation SQL |
| `sql/04_referentiels.sql` | Données initiales : paramètres, anomalies, ADS, alias, types de licence |
| `dataiku/extraction_licences.py` | Recette Python Dataiku |
| `qlik/chargement_licences.qvs` | Script de chargement Qlik Sense (avec section access) |
| `qlik/maquette_feuilles.md` | Maquette des 5 feuilles et mesures de base |
| `tests/` | Test de bout en bout (faux module `dataiku` et vrai PostgreSQL) |

## Modèle de données

- **Faits mensuels** (clé `mois` + `login`, `mois` = 1er jour du mois ; `date_extraction` garde la date réelle) :
  - `fait_utilisateur_mois` : actif, profil, dernière connexion, nombre de jours sans connexion ;
  - `fait_licence_mois` : un couple ADS / type de licence par ligne. Un compte sans licence
    y figure en `NON_ATTRIBUE` / `AUCUNE` ;
  - `fait_groupe_mois` : un groupe par ligne ;
  - `fait_anomalie_mois` : une anomalie par ligne.
- **Dimensions et référentiels** : `dim_utilisateur`, `ref_ads`, `ref_ads_alias`,
  `ref_type_licence`, `ref_profil`, `ref_anomalie`, `ref_parametre`, `ref_acces_qlik`.
- **Type de licence et profil** : un groupe `AAE_CSDIA_licences_DESIGNER` indique l'ADS qui détient
  la licence (`code_ads`) et le type de licence (`type_licence`). Le profil vient du compte
  Dataiku (Designer, Explorer, Reader, None, Platform admin). Les deux doivent correspondre.
- **RGPD** : les données nominatives sont supprimées au-delà de `retention_mois` (6).
  `agg_licence_mois` ne contient aucune donnée personnelle et est conservé pour les tendances longues.

Anomalies détectées (voir `ref_anomalie`) :

| Code | Condition |
|---|---|
| `SANS_LICENCE` | Compte actif sans groupe de licence, alors que son profil en exige une (`ref_profil.exige_licence`, faux pour NONE) |
| `MULTI_ADS` | Plusieurs ADS propriétaires |
| `MULTI_TYPE` | Plusieurs types de licence |
| `PROFIL_DIFFERENT` | Profil DSS différent du type porté par le groupe |
| `TYPE_NON_VALIDE` | Type absent de `ref_type_licence` ou marqué non valide |
| `ADS_INCONNUE` | ADS absente de `ref_ads` |
| `DESACTIVE_AVEC_LICENCE` | Compte désactivé qui a encore un groupe de licence |

## Mise en place

### 1. PostgreSQL

Exécuter dans l'ordre `sql/01_schema.sql`, `02_procedures.sql`, `03_vues.sql` et
`04_referentiels.sql`, avec un compte propriétaire du schéma (PostgreSQL 11 ou plus, pour
`CALL`). Ensuite :

- compléter `ref_ads` (libellé, direction, responsable) et `ref_acces_qlik` (droits Qlik) ;
  vérifier `ref_type_licence` (DESIGNER, EXPLORER, READER) et `ref_profil` (dont
  `exige_licence` pour PLATFORM_ADMIN) ;
- donner au compte de la connexion Dataiku les droits `USAGE, CREATE` sur le schéma,
  `SELECT, INSERT, UPDATE, DELETE` sur les tables et `EXECUTE` sur les procédures ;
- donner au compte Qlik le droit `SELECT` sur les vues `v_qlik_*`, `dim_utilisateur`,
  `ref_*` et `agg_licence_mois`.

Pour utiliser un autre nom de schéma, remplacer `dss_licences` dans tous les fichiers.

### 2. Dataiku

1. Créer une recette Python avec le contenu de `dataiku/extraction_licences.py`.
2. Lui déclarer 4 datasets de sortie sur la connexion PostgreSQL : `stg_utilisateur`,
   `stg_licence`, `stg_groupe` et `stg_anomalie`. Pour chacun, dans *Settings > Connection*,
   régler **schéma = `dss_licences`** et **table = nom du dataset** (sans le préfixe projet).
   La recette vérifie ce réglage et s'arrête avec un message clair s'il est incorrect.
3. Renseigner `CONNEXION_PG` en tête du script.
4. La recette utilise `dataiku.api_client()` : son compte d'exécution doit être
   administrateur DSS (ou disposer d'une clé API admin) pour lister les utilisateurs.
5. Créer un scénario *Build* des 4 datasets, avec un déclencheur mensuel (par exemple le 1er
   du mois à 06:00), et un reporter e-mail en cas d'échec.

Relancer la recette dans le même mois, même un autre jour, remplace la photo du mois : il n'y a pas
de doublon. Avec une rétention de 6 mois, Qlik dispose de 6 photos nominatives ; `agg_licence_mois`
prend le relais pour l'historique plus ancien.

### 3. Qlik Sense

1. Créer une connexion de données PostgreSQL nommée `PostgreSQL_Licences`, ou adapter le
   `LIB CONNECT` du script.
2. Coller `qlik/chargement_licences.qvs`. Les marqueurs `///$tab` indiquent les onglets.
3. **Avant la première activation de la section access, garder une copie de l'application.**
   Un utilisateur absent de `ref_acces_qlik` n'y a plus accès.
4. Planifier un rechargement mensuel après le scénario Dataiku (par exemple le 1er du mois à
   07:00). Un rechargement plus fréquent est inutile : les données ne changent qu'une fois par mois.
5. Construire les feuilles d'après `qlik/maquette_feuilles.md`.

## Tests

```bash
pip install pandas psycopg2-binary pytest
LICENCES_PG_DSN="dbname=licences user=... password=... host=localhost" pytest tests
```

Le test exécute la recette avec un faux module `dataiku` contre un vrai PostgreSQL. Il vérifie
les anomalies, les alias, l'idempotence, la purge RGPD, les droits Qlik et la vérification des
datasets.
