# -*- coding: utf-8 -*-
"""
Recette Python Dataiku : photo quotidienne des licences DSS -> PostgreSQL.

Sorties (datasets Dataiku sur la connexion PostgreSQL, schéma SCHEMA_PG) :
    stg_utilisateur, stg_licence, stg_groupe, stg_anomalie
Les tables stg_* sont écrasées à chaque exécution puis la procédure
p_charger_snapshot() les historise dans les tables fait_* ; p_purger_rgpd()
supprime ensuite les données nominatives au-delà de la rétention.
"""
import dataiku
from dataiku import SQLExecutor2
import pandas as pd

# --- Paramètres -------------------------------------------------------------
CONNEXION_PG = "pg_licences"      # À RENSEIGNER : connexion PostgreSQL dans Dataiku
SCHEMA_PG = "dss_licences"        # Doit correspondre au schéma des scripts sql/
FUSEAU = "Europe/Paris"           # Fuseau de la date d'extraction
LICENCE_MARKER = "_licences_"     # comparé en minuscules
ADS_NON_ATTRIBUE = "NON_ATTRIBUE"
TYPE_AUCUNE = "AUCUNE"

COLONNES = {
    "stg_utilisateur": ["date_extraction", "login", "nom", "email", "source", "profil",
                        "actif", "date_creation", "date_derniere_connexion",
                        "jamais_connecte", "jours_sans_connexion", "nb_ads",
                        "nb_types_licence", "nb_anomalies"],
    "stg_licence": ["date_extraction", "login", "code_ads", "type_licence"],
    "stg_groupe": ["date_extraction", "login", "nom_groupe", "est_groupe_licence"],
    "stg_anomalie": ["date_extraction", "login", "code_anomalie"],
}


def normalise(txt):
    """Pour comparer 'Designer' / 'DESIGNER' / 'Data_Scientist' / 'DATA_SCIENTIST'."""
    return "".join(c for c in str(txt).upper() if c.isalnum())


def ts_to_date(ts_ms):
    if not ts_ms:
        return None
    return pd.Timestamp(ts_ms, unit="ms", tz="UTC").tz_convert(FUSEAU).date()


def iso(d):
    """Dates envoyées en texte ISO : type stable dans les tables stg_*, casté en SQL."""
    return d.isoformat() if d else None


def analyse_groupes(groups, alias_ads):
    """Renvoie l'ensemble des couples (ADS, type de licence) portés par les groupes."""
    licences = set()
    for g in groups:
        pos = g.lower().find(LICENCE_MARKER)
        if pos == -1:
            continue
        ads = g[:pos].upper()
        type_lic = g[pos + len(LICENCE_MARKER):].upper()
        licences.add((alias_ads.get(ads, ads), type_lic))
    return licences


def detecte_anomalies(actif, profil, licences, ads_connues, types_valides):
    """Codes d'anomalie (cf. table ref_anomalie)."""
    proprietaires = {ads for ads, _ in licences}
    types_licence = {t for _, t in licences}
    anomalies = []
    if actif:
        # Contrôles de cohérence uniquement pour les comptes actifs
        if not licences:
            anomalies.append("SANS_LICENCE")
        if len(proprietaires) > 1:
            anomalies.append("MULTI_ADS")
        if len(types_licence) > 1:
            anomalies.append("MULTI_TYPE")
        if types_licence and normalise(profil) not in {normalise(t) for t in types_licence}:
            anomalies.append("PROFIL_DIFFERENT")
        if types_valides and any(normalise(t) not in types_valides for t in types_licence):
            anomalies.append("TYPE_NON_VALIDE")
        if ads_connues and proprietaires - ads_connues:
            anomalies.append("ADS_INCONNUE")
    elif licences:
        # Un compte désactivé n'a normalement plus de groupes
        anomalies.append("DESACTIVE_AVEC_LICENCE")
    return anomalies


def lire_referentiels(executor):
    alias = executor.query_to_df(f"SELECT alias, code_ads FROM {SCHEMA_PG}.ref_ads_alias")
    ads = executor.query_to_df(f"SELECT code_ads FROM {SCHEMA_PG}.ref_ads")
    types = executor.query_to_df(
        f"SELECT type_licence FROM {SCHEMA_PG}.ref_type_licence WHERE valide")
    alias_ads = {str(a).upper(): str(c).upper() for a, c in zip(alias["alias"], alias["code_ads"])}
    ads_connues = {str(c).upper() for c in ads["code_ads"]} - {ADS_NON_ATTRIBUE}
    types_valides = {normalise(t) for t in types["type_licence"]}
    return alias_ads, ads_connues, types_valides


def dernieres_connexions(client):
    """Toutes les dernières activités en un appel ; None si l'API n'est pas disponible."""
    try:
        return {a.login: a.last_session_activity for a in client.list_users_activity()}
    except Exception as e:
        print(f"list_users_activity indisponible ({e}) : lecture utilisateur par utilisateur")
        return None


def derniere_connexion(client, login, activites):
    if activites is not None:
        return activites.get(login)
    try:
        return client.get_user(login).get_activity().last_session_activity
    except Exception as e:
        print(f"Activité illisible pour {login} : {e}")
        return None


def verifier_table_stg(nom):
    """Les procédures SQL lisent SCHEMA_PG.<nom> : le dataset doit y écrire."""
    info = dataiku.Dataset(nom).get_location_info().get("info", {})
    table, schema = info.get("table"), info.get("schema")
    if table is not None and (table != nom or schema != SCHEMA_PG):
        raise ValueError(
            f"Le dataset {nom} écrit dans {schema}.{table} : configurer sa table "
            f"en {SCHEMA_PG}.{nom} (Settings > Connection).")


# --- Extraction -------------------------------------------------------------
client = dataiku.api_client()
executor = SQLExecutor2(connection=CONNEXION_PG)

date_extraction = pd.Timestamp.now(tz=FUSEAU).date()
alias_ads, ads_connues, types_valides = lire_referentiels(executor)
activites = dernieres_connexions(client)

lignes = {nom: [] for nom in COLONNES}
d = iso(date_extraction)

for u in client.list_users():
    login = u["login"]
    groups = u.get("groups") or []
    profil = u.get("userProfile", "")
    actif = u.get("enabled")
    if actif is None:  # sécurité si la clé n'est pas renvoyée
        actif = client.get_user(login).get_settings().enabled

    last = derniere_connexion(client, login, activites)
    date_derniere = last.date() if last else None
    date_creation = ts_to_date(u.get("creationDate"))
    reference = date_derniere or date_creation
    jours = (date_extraction - reference).days if reference else None

    licences = analyse_groupes(groups, alias_ads)
    anomalies = detecte_anomalies(bool(actif), profil, licences, ads_connues, types_valides)

    lignes["stg_utilisateur"].append({
        "date_extraction": d,
        "login": login,
        "nom": u.get("displayName", ""),
        "email": u.get("email", ""),
        "source": u.get("sourceType", ""),
        "profil": profil,
        "actif": bool(actif),
        "date_creation": iso(date_creation),
        "date_derniere_connexion": iso(date_derniere),
        "jamais_connecte": date_derniere is None,
        "jours_sans_connexion": str(jours) if jours is not None else None,
        "nb_ads": len({ads for ads, _ in licences}),
        "nb_types_licence": len({t for _, t in licences}),
        "nb_anomalies": len(anomalies),
    })
    for ads, type_lic in sorted(licences or {(ADS_NON_ATTRIBUE, TYPE_AUCUNE)}):
        lignes["stg_licence"].append(
            {"date_extraction": d, "login": login, "code_ads": ads, "type_licence": type_lic})
    for g in sorted(set(groups)):
        lignes["stg_groupe"].append(
            {"date_extraction": d, "login": login, "nom_groupe": g,
             "est_groupe_licence": LICENCE_MARKER in g.lower()})
    for code in anomalies:
        lignes["stg_anomalie"].append(
            {"date_extraction": d, "login": login, "code_anomalie": code})

# --- Écriture ---------------------------------------------------------------
for nom in COLONNES:
    verifier_table_stg(nom)
for nom, colonnes in COLONNES.items():
    df =pd.DataFrame(lignes[nom], columns=colonnes)
    dataiku.Dataset(nom).write_with_schema(df)
    print(f"{nom} : {len(df)} lignes")

# Historisation puis purge RGPD, dans une même transaction
executor.query_to_df(
    "SELECT 1 AS ok",
    pre_queries=[f"CALL {SCHEMA_PG}.p_charger_snapshot()",
                 f"CALL {SCHEMA_PG}.p_purger_rgpd()"],
    post_queries=["COMMIT"],
)
print(f"Photo du {d} historisée dans {SCHEMA_PG}")
