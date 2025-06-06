output "batch_security_group" {
  description = "Batch security group"
  value       = aws_security_group.batch_sg
}

output "private_subnets" {
  description = "Private subnet IDs"
  value       = aws_subnet.private[*].id
}

output "endpoint_security_group" {
  description = "Private subnet IDs"
  value       = aws_security_group.endpoint_sg
}

