# Use a slim Python 3.9 base
FROM python:3.9-slim

# Install boto3 (AWS SDK) into the image
RUN pip install --no-cache-dir boto3

# Create and switch to /app
WORKDIR /app

# Copy the Python script into the container
COPY process_chunk.py .

# Expose environment variable defaults (can override in Batch job definition)
# These are just placeholders; AWS Batch will inject real values at runtime.
ENV BUCKET="" \
    CHUNK_KEY="" \
    OUTPUT_PREFIX="results/" \
    KMER_SIZE="5"

# Declare the default command to run the script
ENTRYPOINT ["python", "process_chunk.py"]
