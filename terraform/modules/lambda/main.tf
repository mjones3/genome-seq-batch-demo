# Role that both Lambdas will assume
resource "aws_iam_role" "lambda_role" {
  name = "genome_lambda_role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

# Basic logging
resource "aws_iam_role_policy_attachment" "lambda_logging" {
  role       = aws_iam_role.lambda_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# S3 access (GetObject, PutObject, ListBucket) to our bucket
resource "aws_iam_policy" "lambda_s3_policy" {
  name        = "genome-lambda-s3-access"
  description = "Allow Lambdas to read/write chunks & results"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = ["s3:GetObject", "s3:PutObject", "s3:ListBucket"]
      Resource = [
        var.genome_bucket_arn,
        "${var.genome_bucket_arn}/*"
      ]
    }]
  })
}

resource "aws_iam_role_policy_attachment" "lambda_s3_attach" {
  role       = aws_iam_role.lambda_role.name
  policy_arn = aws_iam_policy.lambda_s3_policy.arn
}


resource "aws_lambda_function" "chunker" {
  function_name    = "chunkerFunction"
  role             = aws_iam_role.lambda_role.arn
  runtime          = "python3.9"
  handler          = "chunker.handler.handler"
  filename         = "../functions/chunker/chunkerFunction.zip" # ← replace with your deployment package
  source_code_hash = filebase64sha256("../functions/chunker/chunkerFunction.zip")

  environment {
    variables = {
      BUCKET            = var.genome_bucket_name
      CHUNK_PREFIX      = "chunks/"
      ARRAY_SIZE        = "5"
      BATCH_JOB_QUEUE   = "genome-job-queue"
      BATCH_JOB_DEF_ARN = "genome_batch_job_definition"
    }
  }

  memory_size = 8192 # 8GB of memory
  timeout     = 300
  ephemeral_storage {
    size = 4096 # /tmp
  }

  tags = {
    project = "genome-demo"
  }
}


# Allow S3 events to invoke chunkerFunction
resource "aws_lambda_permission" "allow_s3_to_chunker" {
  statement_id  = "AllowS3Invoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.chunker.function_name
  principal     = "s3.amazonaws.com"
  source_arn    = var.genome_bucket_arn
}

resource "aws_lambda_function" "starter" {
  function_name    = "starterFunction"
  role             = aws_iam_role.lambda_role.arn
  runtime          = "python3.9"
  handler          = "starter.handler.handler"
  filename         = "../functions/starter/starterFunction.zip" # ← replace with your deployment package
  source_code_hash = filebase64sha256("../functions/starter/starterFunction.zip")

  environment {
    variables = {
      CHUNKER_FUNCTION_NAME = var.chunker_function_name
    }
  }

  tags = {
    project = "genome-demo"
  }
}

resource "aws_lambda_function" "aggregator" {
  function_name    = "aggregatorFunction"
  role             = aws_iam_role.lambda_role.arn
  runtime          = "python3.9"
  handler          = "aggregator.handler.handler"
  filename         = "../functions/aggregator/aggregatorFunction.zip" # ← replace with your deployment package
  source_code_hash = filebase64sha256("../functions/aggregator/aggregatorFunction.zip")

  environment {
    variables = {
      BUCKET         = var.genome_bucket_name
      RESULTS_PREFIX = "results/"
      FINAL_KEY      = "results/master.json"
    }
  }

  tags = {
    project = "genome-demo"
  }
}

resource "aws_iam_policy" "agg_s3_access" {
  name        = "AggregatorS3Access"
  description = "Allow aggregator Lambda to list and read chunk summaries, and write the final merged JSON."

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:ListBucket"
        ]
        Resource = [
          "arn:aws:s3:::mjones3-genome-seq-batch-demo"
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:PutObject"
        ]
        Resource = [
          "arn:aws:s3:::mjones3-genome-seq-batch-demo/results/*"
        ]
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "agg_s3_attach" {
  role       = aws_iam_role.lambda_role.name # or whichever role your aggregator uses
  policy_arn = aws_iam_policy.agg_s3_access.arn
}


resource "aws_iam_policy" "starter_lambda_invoke_chunker" {
  name        = "StarterInvokeChunkerPolicy"
  description = "Allow starter Lambda to asynchronously invoke chunker Lambda"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["lambda:InvokeFunction"]
        Resource = [aws_lambda_function.chunker.arn]
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "starter_invoke_attach" {
  role       = aws_iam_role.lambda_role.name
  policy_arn = aws_iam_policy.starter_lambda_invoke_chunker.arn
}

resource "aws_cloudwatch_event_rule" "batch_array_any_succeeded" {
  name_prefix = "batch-array-succeeded-"
  description = "Fires whenever any child of the Batch array job SUCCEEDED"
  event_pattern = jsonencode({
    "source"      = ["aws.batch"],
    "detail-type" = ["Batch Job State Change"],
    "detail" = {
      "status"  = ["SUCCEEDED"],
      "jobName" = ["genomeProcessArrayJob"]
    }
  })
}

resource "aws_cloudwatch_event_target" "invoke_aggregator" {
  rule      = aws_cloudwatch_event_rule.batch_array_any_succeeded.name
  target_id = "AggregatorLambda"
  arn       = aws_lambda_function.aggregator.arn
}

resource "aws_lambda_permission" "allow_events_to_agg" {
  statement_id  = "AllowBatchStateChangeInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.aggregator.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.batch_array_any_succeeded.arn
}

resource "aws_iam_policy" "lambda_batch_submit_policy" {
  name        = "LambdaBatchSubmitPolicy"
  description = "Allow chunker Lambda to submit AWS Batch array jobs and describe job definitions/queues."

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "batch:SubmitJob",
          "batch:DescribeJobDefinitions",
          "batch:DescribeJobQueues"
        ]
        Resource = "*"
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "lambda_batch_submit_attach" {
  role       = aws_iam_role.lambda_role.name
  policy_arn = aws_iam_policy.lambda_batch_submit_policy.arn
}
