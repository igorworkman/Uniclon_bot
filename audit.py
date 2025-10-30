import collections, logging; from typing import Dict, Iterable, List
# REGION AI: meta hash audit helpers
def annotate_meta_hash(rows: Iterable[Dict[str, str]]) -> List[Dict[str, str]]:
    counter: collections.Counter[int] = collections.Counter(); annotated: List[Dict[str, str]] = []
    for row in rows:
        payload = dict(row); digest = hash("".join(payload.get(k) or "" for k in ("encoder", "software", "creation_time"))); payload["meta_hash"] = digest; annotated.append(payload); counter[digest] += 1
        if counter[digest] == 3: logging.warning("[MetaShift] meta_hash %s repeated %s times", digest, counter[digest])
    return annotated
# END REGION AI
