output "api_id" {
  value = aws_api_gateway_rest_api.api.id
}

output "stage_name" {
  value = aws_api_gateway_stage.api.stage_name
}

output "invoke_url" {
  description = "Public URL on real AWS (on the emulator, use the Host header instead)."
  value       = aws_api_gateway_stage.api.invoke_url
}

output "table_name" {
  value = aws_dynamodb_table.links.name
}

output "function_name" {
  value = aws_lambda_function.api.function_name
}
