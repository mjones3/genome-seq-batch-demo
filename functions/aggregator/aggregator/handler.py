import os
import json
import boto3
from collections import Counter

s3    = boto3.client("s3")

BUCKET        = os.environ["BUCKET"]
RESULT_PREFIX = os.environ.get("RESULT_PREFIX", "results/")
FINAL_KEY     = os.environ.get("FINAL_KEY", "results/master.json")

def handler(event, context):
    print("EVENTBRIDGE EVENT:", json.dumps(event))

    detail = event.get("detail", {})
    arr    = detail.get("arrayProperties", {})
    size   = arr.get("size")

    if size is None:
        print("No arrayProperties.size → not an array job event. Exiting.")
        return {"statusCode": 400, "body": "Not an array job event"}

    # Case A: child-level event
    index = arr.get("index")
    if index is not None:
        print(f"Child event: index={index}, size={size}")
        if index < size - 1:
            print(f"Child {index} succeeded, waiting for final child ({size-1}).")
            return {"statusCode": 200, "body": "Waiting for final child…"}
        else:
            print("This is the final child. Proceeding to aggregate.")
    # Case B: parent-level event (no index, but statusSummary)
    else:
        summary = arr.get("statusSummary", {})
        succeeded_count = summary.get("SUCCEEDED", 0)
        print(f"Parent event: succeeded_count={succeeded_count}, size={size}")
        if succeeded_count < size:
            print(f"Only {succeeded_count}/{size} children succeeded so far. Exiting.")
            return {"statusCode": 200, "body": "Waiting for all children to finish…"}
        else:
            print("All children have succeeded. Proceeding to aggregate.")

    # At this point, either index == size-1 or succeeded_count == size
    # 1) List all per-chunk summary files under RESULT_PREFIX
    paginator = s3.get_paginator("list_objects_v2")
    pages     = paginator.paginate(Bucket=BUCKET, Prefix=RESULT_PREFIX)

    summary_keys = []
    for page in pages:
        for obj in page.get("Contents", []):
            key = obj["Key"]
            if key == FINAL_KEY:
                continue
            if key.endswith(".json") or key.endswith(".csv"):
                summary_keys.append(key)

    count = len(summary_keys)
    print(f"Found {count} summaries in S3; expected {size}.")

    if count < size:
        print("Not all chunk summaries are present yet; exiting.")
        return {"statusCode": 200, "body": "Waiting for more summaries…"}

    # 2) Merge them
    total_gc     = 0
    total_bases  = 0
    global_kmers = Counter()

    for key in summary_keys:
        resp = s3.get_object(Bucket=BUCKET, Key=key)
        data = json.loads(resp["Body"].read())
        total_gc    += data.get("gc_count", 0)
        total_bases += data.get("total_bases", 0)
        for kmer, cnt in data.get("kmer_counts", {}).items():
            global_kmers[kmer] += cnt

    global_gc_percent = round((total_gc / total_bases) * 100, 3) if total_bases else 0.0

    merged = {
        "total_bases":       total_bases,
        "total_gc":          total_gc,
        "global_gc_percent": global_gc_percent,
        "kmer_counts":       dict(global_kmers)
    }

    # 3) Write out the final master summary
    s3.put_object(
        Bucket      = BUCKET,
        Key         = FINAL_KEY,
        Body        = json.dumps(merged).encode("utf-8"),
        ContentType = "application/json"
    )
    print(f"Uploaded final aggregated file to s3://{BUCKET}/{FINAL_KEY}")

    return {
        "statusCode": 200,
        "body": json.dumps({
            "message":      "Aggregation completed",
            "final_key":    FINAL_KEY,
            "total_bases":  total_bases,
            "total_gc":     total_gc,
            "gc_percent":   global_gc_percent,
            "unique_kmers": len(global_kmers)
        })
    }
