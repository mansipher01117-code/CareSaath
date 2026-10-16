"""FalkorDB connection.

By default connects to a FalkorDB server (docker compose). Set
FALKORDB_EMBEDDED=1 to use the embedded falkordblite engine instead
(handy when Docker isn't available).
"""
import os
from functools import lru_cache

GRAPH_NAME = os.getenv("FALKORDB_GRAPH", "caresaath")


@lru_cache(maxsize=1)
def _client():
    if os.getenv("FALKORDB_EMBEDDED") == "1":
        from redislite.falkordb_client import FalkorDB  # pip install falkordblite

        path = os.getenv("FALKORDB_LITE_PATH", "./data/caresaath.db")
        os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
        return FalkorDB(path)

    from falkordb import FalkorDB

    return FalkorDB(
        host=os.getenv("FALKORDB_HOST", "localhost"),
        port=int(os.getenv("FALKORDB_PORT", "6379")),
    )


def graph():
    return _client().select_graph(GRAPH_NAME)


def query(cypher: str, params: dict | None = None):
    """Run a Cypher query and return rows as list of dicts."""
    res = graph().query(cypher, params or {})
    header = [h[1] if isinstance(h, (list, tuple)) else h for h in (res.header or [])]
    out = []
    for row in res.result_set or []:
        out.append({header[i]: _plain(v) for i, v in enumerate(row)})
    return out


def _plain(v):
    # Convert falkordb Node/Edge objects to dicts
    if hasattr(v, "properties") and hasattr(v, "labels"):
        return {"labels": list(v.labels or []), **dict(v.properties)}
    if hasattr(v, "properties") and hasattr(v, "relation"):
        return {"type": v.relation, **dict(v.properties)}
    if isinstance(v, list):
        return [_plain(x) for x in v]
    return v


def ping() -> bool:
    try:
        query("RETURN 1 AS ok")
        return True
    except Exception:
        return False
