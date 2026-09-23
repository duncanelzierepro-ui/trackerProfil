"""Faux module `dataiku` pour tester la recette hors DSS, contre un vrai PostgreSQL.

État piloté par les tests : UTILISATEURS, ACTIVITES, DSN, TABLES (location des datasets).
"""
import psycopg2
import pandas as pd

DSN = None
SCHEMA = "dss_licences"
UTILISATEURS = []
ACTIVITES = {}
TABLES = {}   # nom du dataset -> (schema, table) si différent de la valeur par défaut

_TYPES = {"object": "text", "str": "text", "bool": "boolean", "int64": "bigint", "float64": "double precision"}


class _Activite:
    def __init__(self, login, last):
        self.login = login
        self.last_session_activity = last


class _Client:
    def list_users(self):
        return [dict(u) for u in UTILISATEURS]

    def list_users_activity(self):
        return [_Activite(u["login"], ACTIVITES.get(u["login"])) for u in UTILISATEURS]


def api_client():
    return _Client()


class Dataset:
    def __init__(self, name):
        self.name = name

    def get_location_info(self):
        schema, table = TABLES.get(self.name, (SCHEMA, self.name))
        return {"locationInfoType": "SQL", "info": {"schema": schema, "table": table}}

    def write_with_schema(self, df):
        cols = ", ".join(f'"{c}" {_TYPES[str(t)]}' for c, t in df.dtypes.items())
        table = f"{SCHEMA}.{self.name}"
        with psycopg2.connect(DSN) as cnx, cnx.cursor() as cur:
            cur.execute(f"DROP TABLE IF EXISTS {table}; CREATE TABLE {table} ({cols})")
            for row in df.itertuples(index=False):
                values = [None if (isinstance(v, float) and pd.isna(v)) else v for v in row]
                cur.execute(f"INSERT INTO {table} VALUES ({', '.join(['%s'] * len(values))})",
                            [v.item() if hasattr(v, "item") else v for v in values])


class SQLExecutor2:
    def __init__(self, connection=None):
        self.connection = connection

    def query_to_df(self, query, pre_queries=None, post_queries=None):
        cnx = psycopg2.connect(DSN)
        try:
            with cnx.cursor() as cur:
                for q in pre_queries or []:
                    cur.execute(q)
                cur.execute(query)
                df = pd.DataFrame(cur.fetchall(), columns=[c.name for c in cur.description])
                for q in post_queries or []:
                    cur.execute(q)
            return df
        finally:
            cnx.close()
