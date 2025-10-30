import datetime as _dt, random; from typing import Any, Dict
# REGION AI: metadata variants generator
_ENCODER_POOL=[("Lavf62.108.108",0.32),("Lavf62.110.102",0.27),("Lavf63.12.100",0.18),("Lavf61.5.100",0.13),("Lavf58.76.100",0.10)];_SOFTWARE_POOL=[("Lavf62",0.35),("iMovie 10.3",0.22),("Premiere Rush 2.5",0.21),("Shotcut 23.07",0.22)];_COMPATIBLE_POOL=[("isommp42",0.36),("mp42isom",0.28),("mp41isom",0.18),("isomiso2mp41",0.18)];_PICK=lambda pool:random.choices([v for v,_ in pool],weights=[w for _,w in pool],k=1)[0]

def generate_meta_variants(profile:Dict[str,Any])->Dict[str,str]:
    bundle=profile or {}; seed=bundle.get("creation_time") or bundle.get("base_creation_time")
    if isinstance(seed,_dt.datetime): base=seed
    else:
        text=str(seed or "").strip()
        try: base=_dt.datetime.fromisoformat(text.replace("Z","+00:00")) if text else _dt.datetime.now(tz=_dt.timezone.utc)
        except ValueError: base=_dt.datetime.now(tz=_dt.timezone.utc)
    base=base.astimezone(_dt.timezone.utc)+_dt.timedelta(seconds=random.uniform(1.0,60.0))
    iso=base.strftime("%Y-%m-%dT%H:%M:%S.%f")[:-3]+"Z"; encoder=bundle.get("encoder") or _PICK(_ENCODER_POOL); software=bundle.get("software") or _PICK(_SOFTWARE_POOL); compat=bundle.get("compatible_brands")
    compat=compat.strip() if isinstance(compat,str) and compat.strip() else _PICK(_COMPATIBLE_POOL); return {"encoder":encoder,"software":software,"creation_time":iso,"compatible_brands":compat}
# END REGION AI
