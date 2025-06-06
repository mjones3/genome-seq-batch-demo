#!/usr/bin/env python3
import os
import json
import boto3
from collections import Counter

# ────────── Configuration via Environment Variables ──────────
# S3 bucket where chunks live and where results should be written
BUCKET        = os.environ["BUCKET"]            # e.g. "mjones3-genome-seq-batch-demo"
CHUNK_KEY     = os.environ["CHUNK_KEY_PREFIX"]         # e.g. "chunks/myseq.fasta.chunk"
AWS_BATCH_JOB_ARRAY_INDEX = os.environ["AWS_BATCH_JOB_ARRAY_INDEX"] #injected array index
OUTPUT_PREFIX = os.environ.get("OUTPUT_PREFIX", "results/")  
# (must end with "/"; e.g. "results/")
KMER_SIZE     = int(os.environ.get("KMER_SIZE", "5"))  
# Amount of memory in bytes to stream at once (avoid super‐large in‐memory reads)
STREAM_CHUNK_BYTES = 10 * 1024 * 1024  # read 10 MB at a time from S3

s3 = boto3.client("s3")


def handler(event, context):
    """
    1) Download the entire chunk (streamed in blocks).
    2) Filter out non‐ACGT characters/newlines, build one contiguous sequence string.
    3) Slide a window of size=KMER_SIZE over it to count k‐mers.
    4) Compute GC count & total bases.
    5) Upload a single JSON summary to S3 under OUTPUT_PREFIX.
    """
    PADDED_INDEX = pad_to_4_str(AWS_BATCH_JOB_ARRAY_INDEX)
    CHUNK_KEY_WITH_INDEX = CHUNK_KEY + PADDED_INDEX
    print(f"CHUNK_KEY_WITH_INDEX={CHUNK_KEY_WITH_INDEX}")

    # 1. Download/stream the chunk from S3
    try:
        obj = s3.get_object(Bucket=BUCKET, Key=CHUNK_KEY_WITH_INDEX )
        stream = obj["Body"]
    except Exception as e:
        raise RuntimeError(f"Failed to fetch S3 object {BUCKET}/{CHUNK_KEY_WITH_INDEX}: {e}")

    # 2. Read in blocks, build up a single ACGT‐only sequence string
    seq_fragments = []
    while True:
        data = stream.read(STREAM_CHUNK_BYTES)
        if not data:
            break
        # Convert to str and keep only A/C/G/T (uppercase or lowercase)
        text = data.decode("utf-8", errors="ignore")
        # Remove FASTA header lines (if any—though chunking might split them)
        # For simplicity, just strip out anything not A/C/G/T.
        filtered = "".join(ch for ch in text.upper() if ch in ("A", "C", "G", "T"))
        seq_fragments.append(filtered)

    full_seq = "".join(seq_fragments)
    seq_len = len(full_seq)
    if seq_len < KMER_SIZE:
        raise RuntimeError(f"Chunk length ({seq_len}) is shorter than k‐mer size ({KMER_SIZE}).")

    # 3. Count all k‐mers of length=KMER_SIZE
    kmer_counts = Counter()
    for i in range(seq_len - KMER_SIZE + 1):
        kmer = full_seq[i : i + KMER_SIZE]
        kmer_counts[kmer] += 1

    # 4. Compute GC count
    gc_count = full_seq.count("G") + full_seq.count("C")

    # 5. Build a summary dict
    summary = {
        "chunk_key":    CHUNK_KEY,
        "kmer_size":    KMER_SIZE,
        "total_bases":  seq_len,
        "gc_count":     gc_count,
        "gc_percent":   round((gc_count / seq_len) * 100, 3),
        "kmer_counts":  dict(kmer_counts),  # (could be large—consider streaming to file if > memory)
    }

    # 6. Determine the result key in S3
    base = os.path.basename(CHUNK_KEY)  # e.g. "myseq.fasta.chunk0001"
    # Strip any extension, then add “.json”:
    result_key = f"{OUTPUT_PREFIX}{base}{PADDED_INDEX}.json"

    # 7. Upload the JSON summary back to S3
    try:
        s3.put_object(
            Bucket=BUCKET,
            Key=result_key,
            Body=json.dumps(summary).encode("utf-8"),
            ContentType="application/json",
        )
        print(f"Uploaded summary to s3://{BUCKET}/{result_key}")
    except Exception as e:
        raise RuntimeError(f"Failed to upload summary to S3: {e}")

    return {
        "statusCode": 200,
        "body": json.dumps({
            "message":     "Chunk processed successfully",
            "chunk_key":   CHUNK_KEY,
            "result_key":  result_key,
            "total_bases": seq_len,
            "gc_count":    gc_count,
        }),
    }

def pad_to_4_str(index_str: str) -> str:
    """
    Given a string that represents an integer (1–9999 or more),
    return a 4-character string with leading zeros. The result is
    always a string, even if the input is less than 4 digits.

    Raises ValueError if the input contains any non-digit characters.

    Examples:
      "1"    → "0001"
      "45"   → "0045"
      "123"  → "0123"
      "9999" → "9999"
      "12345"→ "12345"  (already ≥ 4 characters, so left unchanged)
    """
    if not index_str.isdigit():
        raise ValueError(f"Invalid input '{index_str}': must be digits only")

    # zfill(4) pads on the left with zeros until length ≥ 4.
    return index_str.zfill(4)

# If you run this locally for testing, you can simulate an “event”:
if __name__ == "__main__":
    # Example local test (make sure ENV VARS are set in your shell):
    print(handler({}, {}))
