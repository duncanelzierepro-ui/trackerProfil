-- =============================================================================
-- Données de référence initiales (réexécutable sans doublon)
-- Les lignes marquées "À COMPLÉTER" sont à adapter à votre contexte.
-- =============================================================================

INSERT INTO dss_licences.ref_parametre (cle, valeur, description) VALUES
    ('seuil_inactivite_jours', '90', 'Au-delà, un compte actif sans connexion est considéré dormant'),
    ('retention_mois',         '6',  'Durée de conservation des données nominatives (RGPD)')
ON CONFLICT (cle) DO NOTHING;

INSERT INTO dss_licences.ref_anomalie (code_anomalie, libelle, gravite) VALUES
    ('SANS_LICENCE',           'Compte actif sans groupe de licence (profil soumis à licence)', 3),
    ('MULTI_ADS',              'Plusieurs ADS propriétaires',                      2),
    ('MULTI_TYPE',             'Plusieurs types de licence',                       2),
    ('PROFIL_DIFFERENT',       'Profil différent du groupe de licence',            2),
    ('TYPE_NON_VALIDE',        'Type de licence absent du référentiel ou non valide', 2),
    ('ADS_INCONNUE',           'ADS absente du référentiel',                       1),
    ('DESACTIVE_AVEC_LICENCE', 'Compte désactivé avec groupe de licence',          1)
ON CONFLICT (code_anomalie) DO UPDATE
    SET libelle = EXCLUDED.libelle, gravite = EXCLUDED.gravite;

-- ADS : NON_ATTRIBUE est obligatoire (utilisateurs sans groupe de licence)
INSERT INTO dss_licences.ref_ads (code_ads, libelle) VALUES
    ('NON_ATTRIBUE', 'Licence non attribuée'),
    ('AAE_CSDIA',    'AAE CSDIA')                    -- À COMPLÉTER : libellé, direction, responsable
    -- , ('AUTRE_ADS', 'Libellé')                     -- À COMPLÉTER : autres ADS
ON CONFLICT (code_ads) DO NOTHING;

-- Alias repris de l'ancien script (à confirmer : CSDIA-AAE == AAE_CSDIA ?)
INSERT INTO dss_licences.ref_ads_alias (alias, code_ads) VALUES
    ('CNDAAE',    'AAE_CSDIA'),
    ('CSDIA-AAE', 'AAE_CSDIA'),
    ('AAE-CDSIA', 'AAE_CSDIA')
ON CONFLICT (alias) DO NOTHING;

-- Types de licence (suffixe des groupes <ADS>_licences_<TYPE>)
-- AUCUNE est obligatoire (valide = false, ce n'est pas une licence)
INSERT INTO dss_licences.ref_type_licence (type_licence, libelle, valide) VALUES
    ('AUCUNE',   'Aucune licence', false),
    ('DESIGNER', 'Designer',       true),
    ('EXPLORER', 'Explorer',       true),
    ('READER',   'Reader',         true)
ON CONFLICT (type_licence) DO NOTHING;

-- Profils attribuables dans Dataiku. Un compte NONE n'a pas besoin de groupe
-- de licence. PLATFORM_ADMIN : passer exige_licence à false si les comptes
-- d'administration ne sont rattachés à aucune ADS.
INSERT INTO dss_licences.ref_profil (profil, libelle, exige_licence) VALUES
    ('DESIGNER',       'Designer',       true),
    ('EXPLORER',       'Explorer',       true),
    ('READER',         'Reader',         true),
    ('PLATFORM_ADMIN', 'Platform admin', true),
    ('NONE',           'Aucun profil',   false)
ON CONFLICT (profil) DO NOTHING;

-- Droits Qlik (section access) : user_id tel qu'il apparaît dans Qlik (DOMAINE\login)
-- INSERT INTO dss_licences.ref_acces_qlik (user_id, code_ads, role) VALUES
--     ('DOMAINE\admin_dataiku', '*',         'ADMIN'),  -- admins : toutes les ADS
--     ('DOMAINE\directeur',     '*',         'USER'),   -- direction : toutes les ADS
--     ('DOMAINE\resp_csdia',    'AAE_CSDIA', 'USER');   -- responsable : son ADS
