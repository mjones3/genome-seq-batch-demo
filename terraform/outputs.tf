output "ecr_repository_url" {
  description = "URI for the ECR repository to push container images for the genome Batch job"
  value       = aws_ecr_repository.genome_job_repo.repository_url
}
