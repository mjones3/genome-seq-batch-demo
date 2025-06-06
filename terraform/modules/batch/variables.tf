variable "batch_security_group" {
  description = "Batch security group"
  type        = string
}

variable "private_subnets" {
  description = "List of private subnet IDs for AWS Batch"
  type        = list(string)
}

variable "ecr_repository_url" {
  description = "ECR repo"
  type        = string
}

variable "aggregatorFunction_function_name" {
  description = "Name of aggregator function"
  type        = string
}

variable "endpoint_security_group" {
  description = "Endpoint security group"
  type        = string
}

