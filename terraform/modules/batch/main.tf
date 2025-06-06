resource "aws_batch_compute_environment" "genome" {
  compute_environment_name = "genome"

  compute_resources {
    max_vcpus = 8 # ← the **maximum** vCPU capacity Batch may spin up
    min_vcpus = 0 # ← the **minimum** vCPU capacity to keep warm (often set to 0)

    security_group_ids = [
      var.batch_security_group,
      var.endpoint_security_group
    ]

    subnets = var.private_subnets

    type = "FARGATE"
  }

  service_role = aws_iam_role.batch_service_role.arn
  type         = "MANAGED"
  # depends_on   = [aws_iam_role_policy_attachment.aws_batch_service_role]
}

resource "aws_batch_job_definition" "genome" {
  name                  = "genome_batch_job_definition"
  type                  = "container"
  platform_capabilities = ["FARGATE"]

  container_properties = jsonencode({
    resourceRequirements = [
      {
        type  = "VCPU"
        value = "2"
      },
      {
        type  = "MEMORY"
        value = "4096"
      }
    ]
    image            = "${var.ecr_repository_url}:process-chunk-latest"
    executionRoleArn = aws_iam_role.ecs_task_execution_role.arn
    jobRoleArn       = aws_iam_role.ecs_task_execution_role.arn
    command          = ["python", "process_chunk.py"]
    environment = [
      { name = "BUCKET", value = "mjones3-genome-seq-batch-demo" },
      { name = "CHUNK_KEY_PREFIX", value = "chunks/GCF_000001405.40_GRCh38.p14_genomic.fna.chunk" },
      { name = "OUTPUT_PREFIX", value = "results/" },
      { name = "KMER_SIZE", value = "5" }
    ]
    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = "/aws/batch/job"
        "awslogs-region"        = "us-east-1"
        "awslogs-stream-prefix" = "ecs"
      }
    }
  })

  tags = {
    "project" = "genome-demo"
  }
}

# resource "aws_cloudwatch_log_group" "batch_job_group" {
#   name              = "/aws/batch/job"
#   retention_in_days = 14
#   tags = {
#     Name = "BatchJobLogGroup"
#   }
# }

resource "aws_batch_job_queue" "genome_queue" {
  name     = "genome-job-queue"
  priority = 1
  state    = "ENABLED"
  compute_environment_order {
    order               = 1
    compute_environment = aws_batch_compute_environment.genome.arn
  }
}

# Role for the containers to read/write S3
resource "aws_iam_role" "batch_job_role" {
  name = "batch_job_role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "batch_job_s3_attach" {
  role = aws_iam_role.batch_job_role.name

  policy_arn = aws_iam_policy.ecs_task_s3_access.arn
}

resource "aws_iam_role" "ecs_task_execution_role" {
  name = "ecs_task_execution_role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ecs_task_execution_attach" {
  role       = aws_iam_role.ecs_task_execution_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "aws_iam_role" "batch_service_role" {
  name = "batch_service_role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "batch.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "batch_service_attach" {
  role       = aws_iam_role.batch_service_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSBatchServiceRole"
}


resource "aws_iam_policy" "ecs_task_s3_access" {
  name        = "ecs_task_s3_access"
  description = "Allow ECS tasks to read/write to the genome S3 bucket"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:ListBucket"
        ]
        Resource = [
          "arn:aws:s3:::mjones3-genome-seq-batch-demo",
          "arn:aws:s3:::mjones3-genome-seq-batch-demo/*"
        ]
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "ecs_task_s3_access_attach" {
  role       = aws_iam_role.ecs_task_execution_role.name
  policy_arn = aws_iam_policy.ecs_task_s3_access.arn
}
