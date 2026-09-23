-- =============================================================================
-- Procédures de chargement et de purge
-- -----------------------------------------------------------------------------
-- Appelées par la recette Python Dataiku après écriture des tables stg_* :
--   CALL dss_licences.p_charger_snapshot();
--   CALL dss_licences.p_purger_rgpd();
-- =============================================================================

-- Charge la photo du jour depuis les tables de transit stg_* vers les faits.
-- Idempotent : relancer le même jour remplace la photo de ce jour.
CREATE OR REPLACE PROCEDURE dss_licences.p_charger_snapshot()
LANGUAGE plpgsql
AS $$
DECLARE
    v_date      date;
    v_nb        integer;
    v_nb_dates  integer;
    v_seuil     integer;
BEGIN
    SELECT count(*), count(DISTINCT date_extraction), max(date_extraction::date)
      INTO v_nb, v_nb_dates, v_date
      FROM dss_licences.stg_utilisateur;

    IF v_nb = 0 THEN
        RAISE EXCEPTION 'stg_utilisateur est vide : chargement annulé';
    END IF;
    IF v_nb_dates > 1 THEN
        RAISE EXCEPTION 'stg_utilisateur contient % dates d''extraction différentes', v_nb_dates;
    END IF;

    SELECT valeur::integer INTO v_seuil
      FROM dss_licences.ref_parametre WHERE cle = 'seuil_inactivite_jours';
    v_seuil := coalesce(v_seuil, 90);

    -- Suppression de la photo du jour (cascade sur licences, groupes, anomalies)
    DELETE FROM dss_licences.fait_utilisateur_jour WHERE date_extraction = v_date;
    DELETE FROM dss_licences.agg_licence_jour      WHERE date_extraction = v_date;

    -- Dimension utilisateur : insertion ou mise à jour
    INSERT INTO dss_licences.dim_utilisateur AS d
           (login, nom, email, source, date_creation,
            date_premiere_extraction, date_derniere_extraction)
    SELECT login, nullif(nom, ''), nullif(email, ''), nullif(source, ''),
           date_creation::date, v_date, v_date
      FROM dss_licences.stg_utilisateur
    ON CONFLICT (login) DO UPDATE SET
           nom           = EXCLUDED.nom,
           email         = EXCLUDED.email,
           source        = EXCLUDED.source,
           date_creation = EXCLUDED.date_creation,
           date_premiere_extraction = LEAST(d.date_premiere_extraction, EXCLUDED.date_premiere_extraction),
           date_derniere_extraction = GREATEST(d.date_derniere_extraction, EXCLUDED.date_derniere_extraction);

    INSERT INTO dss_licences.fait_utilisateur_jour
           (date_extraction, login, profil, actif, date_derniere_connexion,
            jamais_connecte, jours_sans_connexion, nb_ads, nb_types_licence, nb_anomalies)
    SELECT v_date, login, nullif(profil, ''), actif::boolean,
           date_derniere_connexion::date, jamais_connecte::boolean,
           jours_sans_connexion::integer, nb_ads::smallint,
           nb_types_licence::smallint, nb_anomalies::smallint
      FROM dss_licences.stg_utilisateur;

    INSERT INTO dss_licences.fait_licence_jour (date_extraction, login, code_ads, type_licence)
    SELECT DISTINCT v_date, login, code_ads, type_licence
      FROM dss_licences.stg_licence;

    INSERT INTO dss_licences.fait_groupe_jour (date_extraction, login, nom_groupe, est_groupe_licence)
    SELECT DISTINCT v_date, login, nom_groupe, est_groupe_licence::boolean
      FROM dss_licences.stg_groupe;

    INSERT INTO dss_licences.fait_anomalie_jour (date_extraction, login, code_anomalie)
    SELECT DISTINCT v_date, login, code_anomalie
      FROM dss_licences.stg_anomalie;

    -- Agrégat anonyme conservé au-delà de la rétention RGPD
    INSERT INTO dss_licences.agg_licence_jour
           (date_extraction, code_ads, type_licence, nb_comptes, nb_comptes_actifs,
            nb_actifs_inactifs, nb_actifs_jamais_connectes, nb_actifs_en_anomalie,
            seuil_inactivite_jours)
    SELECT l.date_extraction, l.code_ads, l.type_licence,
           count(*),
           count(*) FILTER (WHERE u.actif),
           count(*) FILTER (WHERE u.actif AND u.jours_sans_connexion > v_seuil),
           count(*) FILTER (WHERE u.actif AND u.jamais_connecte),
           count(*) FILTER (WHERE u.actif AND u.nb_anomalies > 0),
           v_seuil
      FROM dss_licences.fait_licence_jour l
      JOIN dss_licences.fait_utilisateur_jour u USING (date_extraction, login)
     WHERE l.date_extraction = v_date
     GROUP BY l.date_extraction, l.code_ads, l.type_licence;

    RAISE NOTICE 'Photo du % chargée : % utilisateurs', v_date, v_nb;
END;
$$;


-- Purge RGPD : supprime les données nominatives au-delà de la rétention
-- (paramètre retention_mois, 6 par défaut). L'agrégat anonyme est conservé.
CREATE OR REPLACE PROCEDURE dss_licences.p_purger_rgpd()
LANGUAGE plpgsql
AS $$
DECLARE
    v_mois    integer;
    v_limite  date;
    v_faits   integer;
    v_users   integer;
BEGIN
    SELECT valeur::integer INTO v_mois
      FROM dss_licences.ref_parametre WHERE cle = 'retention_mois';
    v_limite := (current_date - make_interval(months => coalesce(v_mois, 6)))::date;

    -- Cascade sur fait_licence_jour, fait_groupe_jour, fait_anomalie_jour
    DELETE FROM dss_licences.fait_utilisateur_jour WHERE date_extraction < v_limite;
    GET DIAGNOSTICS v_faits = ROW_COUNT;

    -- Utilisateurs absents de toutes les extractions depuis la limite
    DELETE FROM dss_licences.dim_utilisateur WHERE date_derniere_extraction < v_limite;
    GET DIAGNOSTICS v_users = ROW_COUNT;

    RAISE NOTICE 'Purge RGPD avant le % : % photos utilisateur, % utilisateurs supprimés',
                 v_limite, v_faits, v_users;
END;
$$;
