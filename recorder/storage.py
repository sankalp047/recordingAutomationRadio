"""R2 access via the S3-compatible API."""
import boto3, botocore.config, pathlib
from . import config as C

_client = None

def client():
    global _client
    if _client is None:
        missing = [k for k, v in (("R2_ACCOUNT_ID", C.R2_ACCOUNT_ID),
                                  ("R2_ACCESS_KEY_ID", C.R2_ACCESS_KEY_ID),
                                  ("R2_SECRET_ACCESS_KEY", C.R2_SECRET_ACCESS_KEY)) if not v]
        if missing:
            raise RuntimeError("missing env: " + ", ".join(missing))
        _client = boto3.client(
            "s3",
            endpoint_url=f"https://{C.R2_ACCOUNT_ID}.r2.cloudflarestorage.com",
            aws_access_key_id=C.R2_ACCESS_KEY_ID,
            aws_secret_access_key=C.R2_SECRET_ACCESS_KEY,
            region_name="auto",
            config=botocore.config.Config(retries={"max_attempts": 5, "mode": "standard"}),
        )
    return _client

def key_for(kind, station, day, filename):
    """kind/station/YYYY/MM/DD/filename - date-partitioned so lifecycle rules
    and listings stay cheap, and lexical order is chronological."""
    return f"{kind}/{station}/{day[0:4]}/{day[5:7]}/{day[8:10]}/{filename}"

def upload(local: pathlib.Path, key: str, content_type="audio/mpeg"):
    client().upload_file(str(local), C.R2_BUCKET, key,
                         ExtraArgs={"ContentType": content_type})

def list_day(kind, station, day):
    """[{Name, Size, LastModified}] for one station-day."""
    prefix = f"{kind}/{station}/{day[0:4]}/{day[5:7]}/{day[8:10]}/"
    out, token = [], None
    while True:
        kw = {"Bucket": C.R2_BUCKET, "Prefix": prefix}
        if token:
            kw["ContinuationToken"] = token
        r = client().list_objects_v2(**kw)
        for o in r.get("Contents", []):
            out.append({"Name": o["Key"].rsplit("/", 1)[-1],
                        "Size": o["Size"],
                        "LastModified": o["LastModified"].isoformat()})
        if not r.get("IsTruncated"):
            return out
        token = r.get("NextContinuationToken")

def healthcheck():
    client().head_bucket(Bucket=C.R2_BUCKET)
