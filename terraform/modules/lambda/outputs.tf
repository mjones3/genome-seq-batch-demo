output "starter_function_target_arn" {
  description = "Starter function"
  value       = aws_lambda_function.starter.arn
}


output "aggregatorFunction_function_name" {
  value = aws_lambda_function.aggregator.function_name
}


