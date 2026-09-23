-- =============================================================================
-- Suivi des licences Dataiku DSS - Schéma PostgreSQL (modèle en étoile)
-- -----------------------------------------------------------------------------
-- Ordre d'exécution : 01_schema.sql -> 02_procedures.sql -> 03_vues.sql
--                     -> 04_referentiels.sql
-- Schéma cible : dss_licences (remplacer partout si besoin)
-- Les tables stg_* (zone de transit) sont créées par Dataiku (datasets de
-- sortie de la recette Python) : elles ne sont pas déclarées ici.
-- =============================================================================

CREATE SCHEMA IF NOT EXISTS dss_licences;

-- -----------------------------------------------------------------------------
-- Référentiels (alimentés à la main / par les admins)
-- -----------------------------------------------------------------------------

-- Liste officielle des ADS propriétaires de licences
CREATE TABLE IF NOT EXISTS dss_licences.ref_ads (
    code_ads     varchar(50)  PRIMARY KEY,
    libelle      varchar(200),
    direction    varchar(200),
    responsable  varchar(200),
    date_maj     timestamptz  NOT NULL DEFAULT now()
);

-- Harmonisation des noms d'ADS trouvés dans les groupes (remplace ALIAS_ADS)
CREATE TABLE IF NOT EXISTS dss_licences.ref_ads_alias (
    alias     varchar(50) PRIMARY KEY,
    code_ads  varchar(50) NOT NULL REFERENCES dss_licences.ref_ads (code_ads)
);

-- Types de licence (profils Dataiku). valide = false : type obsolète / interdit
CREATE TABLE IF NOT EXISTS dss_licences.ref_type_licence (
    type_licence  varchar(50)  PRIMARY KEY,
    libelle       varchar(200),
    valide        boolean      NOT NULL DEFAULT true
);

-- Profils utilisateur Dataiku (userProfile). exige_licence = false : le profil
-- ne consomme pas de licence (ex. NONE), un compte sans groupe de licence est normal.
CREATE TABLE IF NOT EXISTS dss_licences.ref_profil (
    profil         varchar(50)  PRIMARY KEY,
    libelle        varchar(200),
    exige_licence  boolean      NOT NULL DEFAULT true
);

-- Catalogue des anomalies détectées par l'extraction
CREATE TABLE IF NOT EXISTS dss_licences.ref_anomalie (
    code_anomalie  varchar(50)  PRIMARY KEY,
    libelle        varchar(200) NOT NULL,
    gravite        smallint     NOT NULL CHECK (gravite BETWEEN 1 AND 3)  -- 1 info, 2 à corriger, 3 critique
);

-- Paramètres métier (seuil d'inactivité, rétention RGPD...)
CREATE TABLE IF NOT EXISTS dss_licences.ref_parametre (
    cle          varchar(50)  PRIMARY KEY,
    valeur       varchar(200) NOT NULL,
    description  varchar(500)
);

-- Droits Qlik Sense (section access) : code_ads = '*' pour toutes les ADS
CREATE TABLE IF NOT EXISTS dss_licences.ref_acces_qlik (
    user_id   varchar(200) NOT NULL,              -- ex. DOMAINE\jdupont
    code_ads  varchar(50)  NOT NULL,
    role      varchar(10)  NOT NULL DEFAULT 'USER' CHECK (role IN ('USER', 'ADMIN')),
    PRIMARY KEY (user_id, code_ads)
);

-- -----------------------------------------------------------------------------
-- Dimension utilisateur (données personnelles : purgées après rétention)
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS dss_licences.dim_utilisateur (
    login                     varchar(100) PRIMARY KEY,
    nom                       varchar(200),
    email                     varchar(320),
    source                    varchar(50),
    date_creation             date,
    date_premiere_extraction  date NOT NULL,
    date_derniere_extraction  date NOT NULL
);

-- -----------------------------------------------------------------------------
-- Faits mensuels (une photo par mois ; clé : mois = 1er jour du mois)
-- -----------------------------------------------------------------------------

-- Grain : 1 ligne par utilisateur et par mois
CREATE TABLE IF NOT EXISTS dss_licences.fait_utilisateur_mois (
    mois                     date         NOT NULL,  -- 1er jour du mois de la photo
    date_extraction          date         NOT NULL,  -- date réelle de l'extraction
    login                    varchar(100) NOT NULL
                             REFERENCES dss_licences.dim_utilisateur (login) ON DELETE CASCADE,
    profil                   varchar(50),
    actif                    boolean      NOT NULL,
    date_derniere_connexion  date,
    jamais_connecte          boolean      NOT NULL,
    jours_sans_connexion     integer,      -- depuis la dernière connexion, sinon depuis la création
    nb_ads                   smallint     NOT NULL,
    nb_types_licence         smallint     NOT NULL,
    nb_anomalies             smallint     NOT NULL,
    PRIMARY KEY (mois, login)
);

-- Grain : 1 ligne par utilisateur, ADS et type de licence et par mois.
-- Un utilisateur sans groupe de licence a une ligne NON_ATTRIBUE / AUCUNE.
CREATE TABLE IF NOT EXISTS dss_licences.fait_licence_mois (
    mois             date         NOT NULL,
    login            varchar(100) NOT NULL,
    code_ads         varchar(50)  NOT NULL,
    type_licence     varchar(50)  NOT NULL,
    PRIMARY KEY (mois, login, code_ads, type_licence),
    FOREIGN KEY (mois, login)
        REFERENCES dss_licences.fait_utilisateur_mois (mois, login) ON DELETE CASCADE
);
CREATE INDEX IF NOT EXISTS ix_fait_licence_ads
    ON dss_licences.fait_licence_mois (code_ads, mois);

-- Grain : 1 ligne par utilisateur, groupe et par mois
CREATE TABLE IF NOT EXISTS dss_licences.fait_groupe_mois (
    mois                date         NOT NULL,
    login               varchar(100) NOT NULL,
    nom_groupe          varchar(200) NOT NULL,
    est_groupe_licence  boolean      NOT NULL,
    PRIMARY KEY (mois, login, nom_groupe),
    FOREIGN KEY (mois, login)
        REFERENCES dss_licences.fait_utilisateur_mois (mois, login) ON DELETE CASCADE
);

-- Grain : 1 ligne par utilisateur, anomalie et par mois
CREATE TABLE IF NOT EXISTS dss_licences.fait_anomalie_mois (
    mois             date         NOT NULL,
    login            varchar(100) NOT NULL,
    code_anomalie    varchar(50)  NOT NULL REFERENCES dss_licences.ref_anomalie (code_anomalie),
    PRIMARY KEY (mois, login, code_anomalie),
    FOREIGN KEY (mois, login)
        REFERENCES dss_licences.fait_utilisateur_mois (mois, login) ON DELETE CASCADE
);

-- Agrégat anonyme (aucune donnée personnelle) : conservé sans limite de durée
-- pour les tendances au-delà de la rétention RGPD.
CREATE TABLE IF NOT EXISTS dss_licences.agg_licence_mois (
    mois                      date        NOT NULL,
    date_extraction           date        NOT NULL,
    code_ads                  varchar(50) NOT NULL,
    type_licence              varchar(50) NOT NULL,
    nb_comptes                integer     NOT NULL,
    nb_comptes_actifs         integer     NOT NULL,
    nb_actifs_inactifs        integer     NOT NULL,  -- actifs sans connexion depuis > seuil
    nb_actifs_jamais_connectes integer    NOT NULL,
    nb_actifs_en_anomalie     integer     NOT NULL,
    seuil_inactivite_jours    integer     NOT NULL,  -- seuil appliqué ce mois-là
    PRIMARY KEY (mois, code_ads, type_licence)
);
