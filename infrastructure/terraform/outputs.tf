# INFORMACIÓN DE ACCESO
output "user_service_dns" {
  description = "DNS del balanceador de carga para servicio de usuarios"
  value       = aws_lb.user_service.dns_name
}

output "product_service_dns" {
  description = "DNS del balanceador de carga para servicio de productos"
  value       = aws_lb.product_service.dns_name
}

# INFORMACIÓN DE BASES DE DATOS
output "user_db_endpoint" {
  description = "Endpoint de la base de datos de usuarios"
  value       = aws_db_instance.user_db.endpoint
  sensitive   = false
}

output "product_db_endpoint" {
  description = "Endpoint de la base de datos de productos"
  value       = aws_db_instance.product_db.endpoint
  sensitive   = false
}

# INFORMACIÓN DE FRONTEND
output "frontend_bucket_name" {
  description = "Nombre del bucket S3 para el frontend"
  value       = aws_s3_bucket.frontend.bucket
}

output "frontend_cloudfront_domain" {
  description = "Dominio CloudFront para el frontend"
  value       = aws_cloudfront_distribution.frontend.domain_name
}

# INFORMACIÓN DE API
output "api_gateway_invoke_url" {
  description = "URL de invocación de API Gateway"
  value       = "${aws_api_gateway_deployment.main.invoke_url}"
}

output "api_gateway_users_url" {
  description = "URL completa para el endpoint de usuarios"
  value       = "${aws_api_gateway_deployment.main.invoke_url}users"
}

output "api_gateway_products_url" {
  description = "URL completa para el endpoint de productos"
  value       = "${aws_api_gateway_deployment.main.invoke_url}products"
}

# INFORMACIÓN DE SECRETOS
output "db_secret_name" {
  description = "Nombre del secreto de base de datos en AWS Secrets Manager"
  value       = aws_secretsmanager_secret.db_credentials.name
}

output "docker_secret_name" {
  description = "Nombre del secreto de Docker en AWS Secrets Manager"
  value       = aws_secretsmanager_secret.docker_credentials.name
}

output "db_name_user" {
  description = "Nombre de la base de datos de usuarios"
  value       = var.db_name_user
}

output "db_name_product" {
  description = "Nombre de la base de datos de productos"
  value       = var.db_name_product
}