"""FalkorDB connection.

Data is isolated per person: every profile gets its own graph named
``person_<id>``. A small registry graph (``REGISTRY_GRAPH``) holds the list of
profiles so the app can show a picker before any person is selected.

By default (``FALKORDB_EMBEDDED=0``) connects to a FalkorDB server over
FALKORDB_HOST / FALKORDB_PORT, with FALKORDB_USERNAME / FALKORDB_PASSWORD when
the server asks for them — a local docker-compose instance needs neither, a
managed/cloud one needs both. Set FALKORDB_EMBEDDED=1 to use the embedded
falkordblite engine instead (handy when Docker isn't available; install it
separately, it is not in requirements.txt).
"""
import os
import re
from functools import lru_cache

REGISTRY_GRAPH = os.getenv("FALKORDB_REGISTRY_GRAPH", "caresaath_people")

_ID_RE = re.compile(r"^[a-z0-9][a-z0-9_-]{0,63}$")


def graph_name(person_id: str) -> str:
    """Graph that holds one person's records. Isolated from every other person."""
    if not _ID_RE.match(person_id or ""):
        raise ValueError(f"Invalid person id: {person_id!r}")
    return f"person_{person_id}"


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
        # Left unset for a local server, which accepts no credentials at all.
        username=os.getenv("FALKORDB_USERNAME") or None,
        password=os.getenv("FALKORDB_PASSWORD") or None,
        # Bounded so an unreachable or sleeping server fails fast and /health
        # can report the graph as unavailable, instead of hanging the request.
        socket_connect_timeout=float(os.getenv("FALKORDB_CONNECT_TIMEOUT_S", "5")),
        socket_timeout=float(os.getenv("FALKORDB_SOCKET_TIMEOUT_S", "10")),
    )


def graph(name: str):
    return _client().select_graph(name)


def query(cypher: str, params: dict | None = None, *, name: str = REGISTRY_GRAPH):
    """Run a Cypher query against graph `name` and return rows as list of dicts."""
    res = graph(name).query(cypher, params or {})
    header = [h[1] if isinstance(h, (list, tuple)) else h for h in (res.header or [])]
    out = []
    for row in res.result_set or []:
        out.append({header[i]: _plain(v) for i, v in enumerate(row)})
    return out


def drop_graph(name: str):
    try:
        graph(name).delete()
    except Exception:
        pass  # nothing stored for this person yet


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
