-- =============================================================================
-- Vues de restitution pour Qlik Sense
-- -----------------------------------------------------------------------------
-- cle_util_jour relie les faits entre eux dans Qlik (évite les clés synthétiques).
-- Les indicateurs sont en 0/1 pour pouvoir être sommés directement.
-- =============================================================================

-- Photo quotidienne des utilisateurs, enrichie des indicateurs métier
CREATE OR REPLACE VIEW dss_licences.v_qlik_utilisateur_jour AS
WITH p AS (
    SELECT coalesce((SELECT valeur::integer FROM dss_licences.ref_parametre
                      WHERE cle = 'seuil_inactivite_jours'), 90) AS seuil
), m AS (
    SELECT max(date_extraction) AS derniere FROM dss_licences.fait_utilisateur_jour
)
SELECT f.date_extraction::text || '|' || f.login           AS cle_util_jour,
       f.date_extraction,
       f.login,
       f.profil,
       f.actif::int                                         AS est_actif,
       (f.actif AND f.jours_sans_connexion > p.seuil)::int  AS est_inactif,
       f.jamais_connecte::int                               AS est_jamais_connecte,
       (f.nb_anomalies > 0)::int                            AS est_en_anomalie,
       (f.date_extraction = m.derniere)::int                AS est_dernier_snapshot,
       f.date_derniere_connexion,
       f.jours_sans_connexion,
       CASE WHEN f.jamais_connecte               THEN 5
            WHEN f.jours_sans_connexion <= 30    THEN 1
            WHEN f.jours_sans_connexion <= 90    THEN 2
            WHEN f.jours_sans_connexion <= 180   THEN 3
            ELSE 4 END                                      AS tranche_inactivite_ordre,
       CASE WHEN f.jamais_connecte               THEN 'Jamais connecté'
            WHEN f.jours_sans_connexion <= 30    THEN '0-30 j'
            WHEN f.jours_sans_connexion <= 90    THEN '31-90 j'
            WHEN f.jours_sans_connexion <= 180   THEN '91-180 j'
            ELSE '> 180 j' END                              AS tranche_inactivite,
       f.nb_ads,
       f.nb_types_licence,
       f.nb_anomalies
  FROM dss_licences.fait_utilisateur_jour f
 CROSS JOIN p
 CROSS JOIN m;

CREATE OR REPLACE VIEW dss_licences.v_qlik_licence_jour AS
SELECT date_extraction::text || '|' || login AS cle_util_jour,
       upper(code_ads)                       AS code_ads,
       type_licence
  FROM dss_licences.fait_licence_jour;

CREATE OR REPLACE VIEW dss_licences.v_qlik_groupe_jour AS
SELECT date_extraction::text || '|' || login AS cle_util_jour,
       nom_groupe,
       est_groupe_licence::int               AS est_groupe_licence
  FROM dss_licences.fait_groupe_jour;

CREATE OR REPLACE VIEW dss_licences.v_qlik_anomalie_jour AS
SELECT date_extraction::text || '|' || login AS cle_util_jour,
       code_anomalie
  FROM dss_licences.fait_anomalie_jour;

-- Section access Qlik : le joker '*' de ref_acces_qlik est développé en la
-- liste explicite des ADS (dans Qlik, '*' ne couvre que les valeurs présentes
-- dans la table de section access, d'où ce développement).
CREATE OR REPLACE VIEW dss_licences.v_qlik_acces AS
WITH toutes_ads AS (
    SELECT code_ads FROM dss_licences.ref_ads
    UNION SELECT code_ads FROM dss_licences.fait_licence_jour
    UNION SELECT code_ads FROM dss_licences.agg_licence_jour
)
SELECT upper(a.role) AS access, upper(a.user_id) AS userid, upper(a.code_ads) AS code_ads
  FROM dss_licences.ref_acces_qlik a
 WHERE a.code_ads <> '*'
UNION
SELECT upper(a.role), upper(a.user_id), upper(t.code_ads)
  FROM dss_licences.ref_acces_qlik a
 CROSS JOIN toutes_ads t
 WHERE a.code_ads = '*';

-- Vue de consultation SQL (hors Qlik) : état courant, une ligne par utilisateur
CREATE OR REPLACE VIEW dss_licences.v_etat_courant AS
SELECT u.login, d.nom, d.email, u.profil, u.actif,
       u.date_derniere_connexion, u.jours_sans_connexion,
       (SELECT string_agg(DISTINCT l.code_ads, ', ' ORDER BY l.code_ads)
          FROM dss_licences.fait_licence_jour l
         WHERE l.date_extraction = u.date_extraction AND l.login = u.login)     AS ads,
       (SELECT string_agg(DISTINCT l.type_licence, ', ' ORDER BY l.type_licence)
          FROM dss_licences.fait_licence_jour l
         WHERE l.date_extraction = u.date_extraction AND l.login = u.login)     AS types_licence,
       (SELECT string_agg(r.libelle, ' | ' ORDER BY r.gravite DESC, r.libelle)
          FROM dss_licences.fait_anomalie_jour a
          JOIN dss_licences.ref_anomalie r USING (code_anomalie)
         WHERE a.date_extraction = u.date_extraction AND a.login = u.login)     AS anomalies,
       u.date_extraction
  FROM dss_licences.fait_utilisateur_jour u
  JOIN dss_licences.dim_utilisateur d USING (login)
 WHERE u.date_extraction = (SELECT max(date_extraction) FROM dss_licences.fait_utilisateur_jour);
