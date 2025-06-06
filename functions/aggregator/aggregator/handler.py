import os
import json
import boto3

s3      = boto3.client("s3")
batch   = boto3.client("batch")

BUCKET        = os.environ["BUCKET"]        # e.g. mjones3-genome-seq-batch-demo
RESULT_PREFIX = os.environ.get("RESULT_PREFIX", "results/")
FINAL_KEY     = os.environ.get("FINAL_KEY", "results/master.json")

def handler(event, context):
    """
    1) EventBridge calls this for any child job SUCCEEDED.
    2) We pull detail.jobId and detail.arrayProperties.size from AWS Batch.
    3) We list S3 under RESULT_PREFIX to count how many chunk summaries exist.
    4) If count < size, exit without doing work.
    5) Once count == size, do final merge + write FINAL_KEY to S3.
    """
    print("EVENTBRIDGE EVENT:", json.dumps(event))

    detail = event.get("detail", {})
    job_id = detail.get("jobId")
    array_props = detail.get("arrayProperties", {})
    array_size  = array_props.get("size")       # total number of children

    if array_size is None:
        print("No array size in event; exiting.")
        return {"statusCode": 400, "body": "Not an array job event"}

    # 1) List all summary files under RESULT_PREFIX
    paginator = s3.get_paginator("list_objects_v2")
    pages = paginator.paginate(Bucket=BUCKET, Prefix=RESULT_PREFIX)

    summary_keys = []
    for page in pages:
        for obj in page.get("Contents", []):
            key = obj["Key"]
            # Skip the final merged file if it exists
            if key == FINAL_KEY:
                continue
            # Only include chunk-summary JSONs or CSVs, not partial
            if key.endswith(".json") or key.endswith(".csv"):
                summary_keys.append(key)

    count = len(summary_keys)
    print(f"Found {count} per-chunk summaries in S3; array size = {array_size}")

    # 2) If not all children have written their summary, exit
    if count < array_size:
        print("Not all chunk summaries are ready; exiting.")
        return {"statusCode": 200, "body": "Waiting for more children"}

    # 3) All children are done—perform final aggregation
    print("All chunk summaries present. Running final merge…")
    total_gc = 0
    total_bases = 0
    from collections import Counter
    global_kmers = Counter()

    for key in summary_keys:
        resp = s3.get_object(Bucket=BUCKET, Key=key)
        body = resp["Body"].read()
        data = json.loads(body)

        total_gc   += data.get("gc_count", 0)
        total_bases+= data.get("total_bases", 0)
        for kmer, cnt in data.get("kmer_counts", {}).items():
            global_kmers[kmer] += cnt

    global_gc_percent = round((total_gc / total_bases) * 100, 3) if total_bases else 0

    merged = {
        "total_bases":       total_bases,
        "total_gc":          total_gc,
        "global_gc_percent": global_gc_percent,
        "kmer_counts":       dict(global_kmers)
    }

    # 4) Write final merged JSON to S3
    merged_body = json.dumps(merged).encode("utf-8")
    s3.put_object(Bucket=BUCKET, Key=FINAL_KEY,
                  Body=merged_body, ContentType="application/json")
    print(f"Uploaded final aggregated file to s3://{BUCKET}/{FINAL_KEY}")

    return {
        "statusCode": 200,
        "body": json.dumps({
            "message": "Aggregation completed",
            "final_key": FINAL_KEY,
            "total_bases": total_bases,
            "total_gc": total_gc,
            "gc_percent": global_gc_percent,
            "unique_kmers": len(global_kmers)
        })
    }
