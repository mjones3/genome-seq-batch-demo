output "api_invoke_url" {
  description = "Invoke URL for the deployed API Gateway (ANY /{proxy+})"
  value       = "${aws_api_gateway_stage.prod.invoke_url}/${var.lambda_function_name}"
}
