import os
import json
import re
import boto3

# ── Configuration via Environment Variables ────────────────────────────────────
BUCKET         = os.environ["BUCKET"]          # e.g. "mjones3-genome-seq-batch-demo"
CHUNK_PREFIX   = os.environ.get("CHUNK_PREFIX", "chunks/")
CHUNK_SIZE     = int(os.environ.get("CHUNK_SIZE_BYTES", 100 * 1024 * 1024))
# Batch-related environment variables (must be set in Lambda config or Terraform)
BATCH_JOB_QUEUE      = os.environ["BATCH_JOB_QUEUE"]      # e.g. "genome-job-queue"
BATCH_JOB_DEFINITION = os.environ["BATCH_JOB_DEF_ARN"]    # full ARN or name
# (Optional) If you want to customize the job name prefix
JOB_NAME_PREFIX      = os.environ.get("JOB_NAME_PREFIX", "genome-chunk-job")
# ──────────────────────────────────────────────────────────────────────────────

s3 = boto3.client("s3")
batch = boto3.client("batch")


def sanitize_job_name(name: str) -> str:
    """
    AWS Batch job names must:
      - Start with alphanumeric
      - Contain only [A-Za-z0-9_-]
      - Be <= 128 characters

    This function:
      1) Removes any extension (text after last dot)
      2) Replaces invalid chars with '-'
      3) Truncates to 120 chars (reserve room for prefix if needed)
    """
    # 1) Remove extension (last ".xxx"), keep everything before it
    no_ext = name.rsplit(".", 1)[0]

    # 2) Replace any character not alphanumeric or _ or - with hyphen
    cleaned = re.sub(r"[^A-Za-z0-9_-]", "-", no_ext)

    # 3) Truncate to 120 chars so adding prefix won’t exceed 128
    if len(cleaned) > 120:
        cleaned = cleaned[:120]

    # 4) Ensure the first character is alphanumeric; if not, prefix with "job"
    if not re.match(r"^[A-Za-z0-9]", cleaned):
        cleaned = "job-" + cleaned

    return cleaned


def handler(event, context):
    """
    1) Download the FASTA from S3 (given by event["bucket"], event["key"]).
    2) Split into CHUNK_SIZE pieces, write each chunk to S3 under CHUNK_PREFIX.
    3) Submit a Batch Array Job with size = number_of_chunks, using a sanitized job name.
    """
    # Log the incoming event so we can debug in CloudWatch Logs
    print("RAW EVENT:", json.dumps(event))

    # 1. Parse incoming bucket/key (we expect event to be { "bucket": ..., "key": ... })
    try:
        src_bucket = event["bucket"]
        src_key    = event["key"]
    except Exception as e:
        # If it’s missing, return 400
        return {
            "statusCode": 400,
            "body": json.dumps({ "error": f"Invalid request payload: {e}", "received": event })
        }

    print(f"Chunker: processing s3://{src_bucket}/{src_key}")

    # 2. Stream the FASTA from S3 and chunk it
    try:
        obj = s3.get_object(Bucket=src_bucket, Key=src_key)
        stream = obj["Body"]
    except Exception as e:
        return {
            "statusCode": 404,
            "body": json.dumps({ "error": f"Could not read S3 object: {e}" })
        }

    chunk_index   = 0
    bytes_buffer  = b""
    uploaded_keys = []

    while True:
        to_read = CHUNK_SIZE - len(bytes_buffer)
        data = stream.read(to_read)
        if not data:
            # No more data; upload leftover buffer if any
            if bytes_buffer:
                new_key = upload_chunk(bytes_buffer, chunk_index, src_bucket, src_key)
                uploaded_keys.append(new_key)
            break

        bytes_buffer += data
        if len(bytes_buffer) >= CHUNK_SIZE:
            new_key = upload_chunk(bytes_buffer, chunk_index, src_bucket, src_key)
            uploaded_keys.append(new_key)
            chunk_index  += 1
            bytes_buffer  = b""

    total_chunks = len(uploaded_keys)
    print(f"Uploaded {total_chunks} chunks for {src_key}")

    if total_chunks == 0:
        return {
            "statusCode": 400,
            "body": json.dumps({ "error": "Input file was empty or smaller than chunk size" })
        }

    # 3. Build a sanitized job name and submit AWS Batch Array Job
    raw_basename = os.path.basename(src_key)                 # e.g. "GCF_000001405.40_GRCh38.p14_genomic.fna"
    safe_name    = sanitize_job_name(raw_basename)           # e.g. "GCF_000001405-40_GRCh38-p14_genomic"
    job_name     = f"{JOB_NAME_PREFIX}-{safe_name}"          # e.g. "genome-chunk-job-GCF_000001405-40_GRCh38-p14_genomic"
    print("Preparing to submit job:", job_name)

    try:
        response = batch.submit_job(
            jobName         = job_name,
            jobQueue        = BATCH_JOB_QUEUE,
            jobDefinition   = BATCH_JOB_DEFINITION,
            arrayProperties = { "size": total_chunks }
        )
        print("Batch submit response:", json.dumps(response))
    except Exception as e:
        print("Batch submit failed:", str(e))
        return {
            "statusCode": 500,
            "body": json.dumps({ "error": f"Batch submit failed: {e}" })
        }

    return {
        "statusCode": 200,
        "body": json.dumps({
            "message":          "Chunks created & Batch job submitted",
            "source_bucket":    src_bucket,
            "source_key":       src_key,
            "chunks_uploaded":  total_chunks,
            "batch_job_id":     response.get("jobId"),
            "batch_job_name":   job_name,
            "array_size":       total_chunks
        })
    }

def upload_chunk(data_bytes: bytes, index: int, bucket: str, original_key: str) -> str:
    """
    Upload one chunk to S3 under CHUNK_PREFIX.
    Returns the S3 key of the uploaded chunk.
    """
    base = os.path.basename(original_key)
    chunk_key = f"{CHUNK_PREFIX}{base}.chunk{index:04d}"

    s3.put_object(
        Bucket = bucket,
        Key    = chunk_key,
        Body   = data_bytes
    )
    print(f"Uploaded chunk {index} → s3://{bucket}/{chunk_key}")
    return chunk_key
