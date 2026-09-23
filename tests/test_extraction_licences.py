"""Test de bout en bout : recette Python (faux dataiku) + scripts SQL sur PostgreSQL.

    LICENCES_PG_DSN="dbname=licences user=dss password=dss host=localhost" pytest tests
"""
import os
import runpy
import sys
from datetime import datetime, timedelta
from pathlib import Path

import pandas as pd
import pytest

psycopg2 = pytest.importorskip("psycopg2")

RACINE = Path(__file__).resolve().parents[1]
SCRIPT = RACINE / "dataiku" / "extraction_licences.py"
DSN = os.environ.get("LICENCES_PG_DSN")

sys.path.insert(0, str(Path(__file__).parent / "fake_dataiku"))
import dataiku  # noqa: E402  (faux module)

pytestmark = pytest.mark.skipif(not DSN, reason="LICENCES_PG_DSN non défini")

AUJOURDHUI = pd.Timestamp.now(tz="Europe/Paris").date()


def il_y_a(jours):
    return datetime.combine(AUJOURDHUI - timedelta(days=jours), datetime.min.time())


def ms(jours):
    return int(il_y_a(jours).timestamp() * 1000)


UTILISATEURS = [
    # Conforme
    {"login": "alice", "displayName": "Alice", "email": "alice@x.fr", "userProfile": "DESIGNER",
     "enabled": True, "groups": ["AAE_CSDIA_licences_DESIGNER", "readers"], "creationDate": ms(400)},
    # Alias + deux ADS dont une inconnue + deux types
    {"login": "bob", "displayName": "O'Brien", "userProfile": "EXPLORER", "enabled": True,
     "groups": ["CNDAAE_licences_Designer", "AUTRE_licences_EXPLORER"], "creationDate": ms(50)},
    # Sans licence, jamais connecté, créé il y a 200 jours
    {"login": "carol", "userProfile": "DESIGNER", "enabled": True, "groups": [], "creationDate": ms(200)},
    # Désactivé avec licence
    {"login": "dave", "userProfile": "DESIGNER", "enabled": False,
     "groups": ["AAE_CSDIA_licences_DESIGNER"], "creationDate": ms(300)},
    # Type non valide, dormant (100 jours)
    {"login": "eve", "userProfile": "ANALYST", "enabled": True,
     "groups": ["AAE_CSDIA_licences_ANALYST"], "creationDate": ms(365)},
    # Profil différent du groupe
    {"login": "frank", "userProfile": "Designer", "enabled": True,
     "groups": ["AAE_CSDIA_licences_READER"], "creationDate": ms(30)},
    # Profil NONE sans groupe : ne consomme pas de licence, aucune anomalie
    {"login": "gus", "userProfile": "NONE", "enabled": True, "groups": ["readers"],
     "creationDate": ms(40)},
]
ACTIVITES = {"alice": il_y_a(10), "bob": il_y_a(1), "dave": il_y_a(250), "gus": il_y_a(3),
             "eve": il_y_a(100), "frank": il_y_a(5)}


def sql(requete, params=None):
    with psycopg2.connect(DSN) as cnx, cnx.cursor() as cur:
        cur.execute(requete, params)
        return cur.fetchall() if cur.description else None


@pytest.fixture(autouse=True)
def base():
    sql("DROP SCHEMA IF EXISTS dss_licences CASCADE")
    for f in sorted((RACINE / "sql").glob("*.sql")):
        sql(f.read_text(encoding="utf-8"))
    sql("INSERT INTO dss_licences.ref_acces_qlik VALUES "
        "('dom\\admin', '*', 'ADMIN'), ('dom\\resp', 'AAE_CSDIA', 'USER')")
    dataiku.DSN = DSN
    dataiku.UTILISATEURS = UTILISATEURS
    dataiku.ACTIVITES = ACTIVITES
    dataiku.TABLES = {}


def lancer():
    runpy.run_path(str(SCRIPT), run_name="__main__")


def test_chargement_et_anomalies():
    lancer()
    anomalies = sql("SELECT login, code_anomalie FROM dss_licences.fait_anomalie_mois")
    assert set(anomalies) == {
        ("bob", "MULTI_ADS"), ("bob", "MULTI_TYPE"), ("bob", "ADS_INCONNUE"),
        ("carol", "SANS_LICENCE"), ("dave", "DESACTIVE_AVEC_LICENCE"),
        ("eve", "TYPE_NON_VALIDE"), ("frank", "PROFIL_DIFFERENT"),
    }
    licences = sql("SELECT login, code_ads, type_licence FROM dss_licences.fait_licence_mois")
    assert ("bob", "AAE_CSDIA", "DESIGNER") in licences          # alias appliqué
    assert ("carol", "NON_ATTRIBUE", "AUCUNE") in licences
    assert sql("SELECT nom FROM dss_licences.dim_utilisateur WHERE login = 'bob'") == [("O'Brien",)]

    vue = dict(sql("SELECT login, est_inactif FROM dss_licences.v_qlik_utilisateur_mois"))
    assert vue == {"alice": 0, "bob": 0, "carol": 1, "dave": 0, "eve": 1, "frank": 0, "gus": 0}
    assert sql("SELECT jours_sans_connexion FROM dss_licences.fait_utilisateur_mois "
               "WHERE login = 'carol'") == [(200,)]

    agg = sql("SELECT nb_comptes, nb_comptes_actifs, nb_actifs_inactifs FROM "
              "dss_licences.agg_licence_mois WHERE code_ads = 'AAE_CSDIA' AND type_licence = 'DESIGNER'")
    assert agg == [(3, 2, 0)]   # alice, bob actifs ; dave désactivé

    acces = sql("SELECT userid, code_ads FROM dss_licences.v_qlik_acces")
    assert {c for u, c in acces if u == "DOM\\ADMIN"} == {"AAE_CSDIA", "AUTRE", "NON_ATTRIBUE"}
    assert {c for u, c in acces if u == "DOM\\RESP"} == {"AAE_CSDIA"}
    assert len(sql("SELECT * FROM dss_licences.v_etat_courant")) == 7


def test_relance_meme_mois_idempotente():
    lancer()
    lancer()
    assert sql("SELECT count(*) FROM dss_licences.fait_utilisateur_mois") == [(7,)]
    assert sql("SELECT count(*) FROM dss_licences.fait_anomalie_mois") == [(7,)]


def test_relance_autre_jour_du_mois_remplace_la_photo():
    mois = AUJOURDHUI.replace(day=1)
    sql("INSERT INTO dss_licences.dim_utilisateur VALUES ('parti', 'Parti', NULL, NULL, NULL, %s, %s)",
        (mois, mois))
    sql("INSERT INTO dss_licences.fait_utilisateur_mois VALUES (%s, %s, 'parti', 'DESIGNER', true, "
        "NULL, true, 10, 0, 0, 0)", (mois, mois))
    lancer()
    assert sql("SELECT count(*), max(date_extraction) FROM dss_licences.fait_utilisateur_mois "
               "WHERE mois = %s", (mois,)) == [(7, AUJOURDHUI)]
    assert sql("SELECT DISTINCT mois FROM dss_licences.agg_licence_mois") == [(mois,)]


def test_purge_rgpd_conserve_agregat():
    ancienne = AUJOURDHUI - timedelta(days=220)
    sql("INSERT INTO dss_licences.dim_utilisateur VALUES ('parti', 'Parti', NULL, NULL, NULL, %s, %s)",
        (ancienne, ancienne))
    ancien_mois = ancienne.replace(day=1)
    sql("INSERT INTO dss_licences.fait_utilisateur_mois VALUES (%s, %s, 'parti', 'DESIGNER', true, "
        "NULL, true, 10, 0, 0, 1)", (ancien_mois, ancienne))
    sql("INSERT INTO dss_licences.agg_licence_mois VALUES (%s, %s, 'AAE_CSDIA', 'DESIGNER', 1, 1, 0, 1, 1, 90)",
        (ancien_mois, ancienne))
    lancer()
    assert sql("SELECT count(*) FROM dss_licences.dim_utilisateur WHERE login = 'parti'") == [(0,)]
    assert sql("SELECT count(*) FROM dss_licences.fait_utilisateur_mois WHERE mois = %s",
               (ancien_mois,)) == [(0,)]
    assert sql("SELECT count(*) FROM dss_licences.agg_licence_mois WHERE mois = %s",
               (ancien_mois,)) == [(1,)]


def test_dataset_mal_configure():
    dataiku.TABLES = {"stg_licence": ("dss_licences", "PROJET_stg_licence")}
    with pytest.raises(ValueError, match="stg_licence"):
        lancer()
