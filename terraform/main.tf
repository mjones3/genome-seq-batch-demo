terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.61.0"
    }
  }

  required_version = ">= 1.2.0"
}

provider "aws" {
  region = "us-east-1"
}

resource "aws_s3_bucket" "genome_bucket" {
  bucket = "mjones3-genome-seq-batch-demo"

  tags = {
    project     = "genome"
    environment = "dev"
  }
}


resource "aws_ecr_repository" "genome_job_repo" {
  name                 = "genome-seq-batch-demo"
  image_tag_mutability = "MUTABLE"
  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "AES256"
  }

  tags = {
    Name    = "genome-seq-batch-demo-repo"
    project = "genome"
  }
}


module "lambda" {
  source                = "./modules/lambda"
  genome_bucket_arn     = aws_s3_bucket.genome_bucket.arn
  genome_bucket_name    = "mjones3-genome-seq-batch-demo"
  chunker_function_name = "chunkerFunction"
  starter_function_name = "starterFunction"
}

module "network" {
  source = "./modules/network"
}

module "api" {
  source                     = "./modules/api"
  lambda_function_target_arn = module.lambda.starter_function_target_arn
  lambda_function_name       = "starterFunction"
}

module "batch" {
  source                           = "./modules/batch"
  batch_security_group             = module.network.batch_security_group.id
  private_subnets                  = module.network.private_subnets
  ecr_repository_url               = aws_ecr_repository.genome_job_repo.repository_url
  aggregatorFunction_function_name = module.lambda.aggregatorFunction_function_name
  endpoint_security_group          = module.network.endpoint_security_group.id
}
