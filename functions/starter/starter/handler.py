import os
import json
import boto3

LAMBDA_CLIENT       = boto3.client("lambda")
CHUNKER_FUNCTION    = os.environ["CHUNKER_FUNCTION_NAME"]  # e.g. "chunkerFunction"

def handler(event, context):
    """
    1) Parse incoming API Gateway POST JSON for { bucket, key }.
    2) Invoke chunkerFunction asynchronously (InvocationType="Event"), passing same payload.
    3) Immediately return 200 with a “started” message.
    """
    try:
        print(event)
        body = event.get("body", "")
        if event.get("isBase64Encoded", False):
            body = boto3.compat.decode_bytes(body)
        payload = json.loads(body)
        src_bucket = payload["bucket"]
        src_key    = payload["key"]
    except Exception as e:
        return {
            "statusCode": 400,
            "body": json.dumps({ "error": f"Invalid JSON payload: {e}" })
        }

    # Asynchronously invoke chunkerFunction
    try:

        print(payload) 
        LAMBDA_CLIENT.invoke(
            FunctionName   = CHUNKER_FUNCTION,
            InvocationType = "Event",   
            Payload        = json.dumps(payload).encode("utf-8")
        )
    except Exception as e:
        return {
            "statusCode": 500,
            "body": json.dumps({ "error": f"Failed to start chunker: {e}" })
        }

    # Immediately return 200 OK
    return {
        "statusCode": 200,
        "body": json.dumps({
            "message":    "Chunker job started",
            "bucket":     src_bucket,
            "key":        src_key
        })
    }
