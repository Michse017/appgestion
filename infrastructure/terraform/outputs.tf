# INFORMACIÓN DE ACCESO
output "api_gateway_invoke_url" {
  description = "URL de invocación de API Gateway"
  value       = "${aws_api_gateway_deployment.main.invoke_url}"
}

output "frontend_cloudfront_domain" {
  description = "Dominio CloudFront para el frontend"
  value       = aws_cloudfront_distribution.frontend.domain_name
}

output "frontend_bucket_name" {
  description = "Nombre del bucket S3 para el frontend"
  value       = aws_s3_bucket.frontend.bucket
}

output "user_service_endpoint" {
  description = "Endpoint del balanceador para servicio de usuarios"
  value       = aws_lb.user_service.dns_name
}

output "product_service_endpoint" {
  description = "Endpoint del balanceador para servicio de productos"
  value       = aws_lb.product_service.dns_name
}

output "user_db_endpoint" {
  description = "Endpoint de la base de datos de usuarios"
  value       = aws_db_instance.user_db.endpoint
}

output "product_db_endpoint" {
  description = "Endpoint de la base de datos de productos"
  value       = aws_db_instance.product_db.endpoint
}