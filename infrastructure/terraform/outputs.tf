# ======================================================
# INFORMACIÓN DE ACCESO
# ======================================================

output "backend_public_ip" {
  description = "IP pública del servidor backend"
  value       = aws_instance.backend.public_ip
}

output "ssh_connection" {
  description = "Comando para conectarse por SSH al servidor backend"
  value       = "ssh -i ${var.ssh_key_path} ubuntu@${aws_instance.backend.public_ip}"
}

# ======================================================
# INFORMACIÓN DE BASES DE DATOS
# ======================================================

output "user_db_endpoint" {
  description = "Endpoint de la base de datos de usuarios"
  value       = aws_db_instance.user_db.endpoint
  sensitive   = true
}

output "product_db_endpoint" {
  description = "Endpoint de la base de datos de productos"
  value       = aws_db_instance.product_db.endpoint
  sensitive   = true
}

# ======================================================
# INFORMACIÓN DE FRONTEND
# ======================================================

output "frontend_bucket_name" {
  description = "Nombre del bucket S3 para el frontend"
  value       = aws_s3_bucket.frontend.bucket
}

output "frontend_cloudfront_domain" {
  description = "Dominio CloudFront para el frontend"
  value       = aws_cloudfront_distribution.frontend.domain_name
}

output "cloudfront_distribution_id" {
  description = "ID de la distribución CloudFront"
  value       = aws_cloudfront_distribution.frontend.id
}

output "frontend_url" {
  description = "URL completa del frontend"
  value       = "https://${aws_cloudfront_distribution.frontend.domain_name}"
}

# ======================================================
# INFORMACIÓN DE API
# ======================================================

output "api_gateway_id" {
  description = "ID de API Gateway"
  value       = aws_api_gateway_rest_api.main.id
}

output "api_gateway_invoke_url" {
  description = "URL de invocación de API Gateway"
  value       = aws_api_gateway_deployment.main.invoke_url
}

output "api_user_endpoint" {
  description = "Endpoint del servicio de usuarios"
  value       = "${aws_api_gateway_deployment.main.invoke_url}users"
}

output "api_product_endpoint" {
  description = "Endpoint del servicio de productos"
  value       = "${aws_api_gateway_deployment.main.invoke_url}products"
}

# ======================================================
# INFORMACIÓN DE SECRETOS
# ======================================================

output "db_secret_name" {
  description = "Nombre del secreto de base de datos en AWS Secrets Manager"
  value       = aws_secretsmanager_secret.db_credentials.name
}

output "docker_secret_name" {
  description = "Nombre del secreto de Docker en AWS Secrets Manager"
  value       = aws_secretsmanager_secret.docker_credentials.name
}