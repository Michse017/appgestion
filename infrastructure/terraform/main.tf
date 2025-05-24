# ======================================================
# PROVIDER CONFIGURATION
# ======================================================

terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 4.0"
    }
  }
  
  # Si deseas usar Terraform Cloud o un backend remoto, descomenta estas líneas
  # backend "s3" {
  #   bucket = "appgestion-terraform-state"
  #   key    = "terraform.tfstate"
  #   region = "us-east-1"
  # }
}

provider "aws" {
  region = var.aws_region
}

# Para ejecutar comandos locales (Docker, Ansible)
provider "null" {}
provider "local" {}

# ======================================================
# NETWORKING - VPC Y SUBNETS
# ======================================================

# Creación de la VPC principal
resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true
  
  tags = {
    Name        = "${var.project_name}-vpc"
    Environment = var.environment
  }
}

# Internet Gateway para permitir conexiones externas
resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id
  
  tags = {
    Name        = "${var.project_name}-igw"
    Environment = var.environment
  }
}

# Subnets públicas (para EC2, API Gateway)
resource "aws_subnet" "public" {
  count                   = length(var.public_subnet_cidrs)
  vpc_id                  = aws_vpc.main.id
  cidr_block              = var.public_subnet_cidrs[count.index]
  availability_zone       = var.availability_zones[count.index]
  map_public_ip_on_launch = true
  
  tags = {
    Name        = "${var.project_name}-public-subnet-${count.index + 1}"
    Environment = var.environment
  }
}

# Subnets privadas (para RDS)
resource "aws_subnet" "private" {
  count             = length(var.private_subnet_cidrs)
  vpc_id            = aws_vpc.main.id
  cidr_block        = var.private_subnet_cidrs[count.index]
  availability_zone = var.availability_zones[count.index]
  
  tags = {
    Name        = "${var.project_name}-private-subnet-${count.index + 1}"
    Environment = var.environment
  }
}

# NAT Gateway para permitir conexiones salientes desde subnets privadas
resource "aws_eip" "nat" {
  vpc = true
  
  tags = {
    Name        = "${var.project_name}-nat-eip"
    Environment = var.environment
  }
}

resource "aws_nat_gateway" "main" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public[0].id
  
  tags = {
    Name        = "${var.project_name}-nat"
    Environment = var.environment
  }
}

# Tabla de rutas pública
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id
  
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }
  
  tags = {
    Name        = "${var.project_name}-public-route"
    Environment = var.environment
  }
}

# Tabla de rutas privada
resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id
  
  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.main.id
  }
  
  tags = {
    Name        = "${var.project_name}-private-route"
    Environment = var.environment
  }
}

# Asociación de tablas de rutas a subnets
resource "aws_route_table_association" "public" {
  count          = length(var.public_subnet_cidrs)
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table_association" "private" {
  count          = length(var.private_subnet_cidrs)
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private.id
}

# ======================================================
# GRUPOS DE SEGURIDAD
# ======================================================

# Grupo de seguridad para instancias EC2 públicas
resource "aws_security_group" "ec2" {
  name        = "${var.project_name}-ec2-sg"
  description = "Permite trafico necesario para EC2"
  vpc_id      = aws_vpc.main.id
  
  # SSH desde cualquier lugar (puede restringirse a IPs específicas)
  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "SSH"
  }
  
  # HTTP y HTTPS para la aplicación
  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "HTTP"
  }
  
  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "HTTPS"
  }
  
  # Puertos para servicios de backend
  ingress {
    from_port   = 3001
    to_port     = 3002
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "Backend Services"
  }
  
  # Permitir todo el tráfico saliente
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  
  tags = {
    Name        = "${var.project_name}-ec2-sg"
    Environment = var.environment
  }
}

# Grupo de seguridad para RDS
resource "aws_security_group" "rds" {
  name        = "${var.project_name}-rds-sg"
  description = "Permite conexiones a base de datos RDS"
  vpc_id      = aws_vpc.main.id
  
  # Permitir tráfico PostgreSQL solo desde instancias EC2
  ingress {
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.ec2.id]
    description     = "PostgreSQL desde EC2"
  }
  
  # Permitir tráfico saliente
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  
  tags = {
    Name        = "${var.project_name}-rds-sg"
    Environment = var.environment
  }
}

# ======================================================
# AWS SECRETS MANAGER - CREDENCIALES
# ======================================================

# Secret para credenciales de bases de datos
resource "aws_secretsmanager_secret" "db_credentials" {
  name = "${var.project_name}-db-credentials"
  
  tags = {
    Name        = "${var.project_name}-db-credentials"
    Environment = var.environment
  }
}

resource "aws_secretsmanager_secret_version" "db_credentials" {
  secret_id = aws_secretsmanager_secret.db_credentials.id
  secret_string = jsonencode({
    username      = var.db_username
    password      = var.db_password
    db_name_user  = var.db_name_user
    db_name_product = var.db_name_product
    host_user     = aws_db_instance.user_db.address
    host_product  = aws_db_instance.product_db.address
    port          = 5432
  })
}

# Secret para credenciales de DockerHub
resource "aws_secretsmanager_secret" "docker_credentials" {
  name = "${var.project_name}-docker-credentials"
  
  tags = {
    Name        = "${var.project_name}-docker-credentials"
    Environment = var.environment
  }
}

resource "aws_secretsmanager_secret_version" "docker_credentials" {
  secret_id = aws_secretsmanager_secret.docker_credentials.id
  secret_string = jsonencode({
    username = var.dockerhub_username
    password = var.dockerhub_password
  })
}

# ======================================================
# IAM ROLES Y POLÍTICAS
# ======================================================

# Rol para EC2 que permite acceso a Secrets Manager
resource "aws_iam_role" "ec2_role" {
  name = "${var.project_name}-ec2-role"
  
  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Action = "sts:AssumeRole",
        Effect = "Allow",
        Principal = {
          Service = "ec2.amazonaws.com"
        }
      }
    ]
  })
}

resource "aws_iam_policy" "secrets_access" {
  name        = "${var.project_name}-secrets-access"
  description = "Permite acceso a secretos específicos"
  
  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Action = [
          "secretsmanager:GetSecretValue",
        ],
        Effect = "Allow",
        Resource = [
          aws_secretsmanager_secret.db_credentials.arn,
          aws_secretsmanager_secret.docker_credentials.arn
        ]
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "secrets_policy_attachment" {
  role       = aws_iam_role.ec2_role.name
  policy_arn = aws_iam_policy.secrets_access.arn
}

resource "aws_iam_instance_profile" "ec2_profile" {
  name = "${var.project_name}-ec2-profile"
  role = aws_iam_role.ec2_role.name
}

# ======================================================
# BASES DE DATOS RDS
# ======================================================

# Grupo de subnets para RDS
resource "aws_db_subnet_group" "main" {
  name       = "${var.project_name}-db-subnet"
  subnet_ids = aws_subnet.private[*].id
  
  tags = {
    Name        = "${var.project_name}-db-subnet-group"
    Environment = var.environment
  }
}

# Base de datos para el servicio de usuarios
resource "aws_db_instance" "user_db" {
  identifier           = "${var.project_name}-user-db"
  allocated_storage    = 20
  storage_type         = "gp2"
  engine               = "postgres"
  engine_version       = "13"
  instance_class       = var.db_instance_class
  db_name              = var.db_name_user
  username             = var.db_username
  password             = var.db_password
  parameter_group_name = "default.postgres13"
  skip_final_snapshot  = true
  db_subnet_group_name = aws_db_subnet_group.main.name
  vpc_security_group_ids = [aws_security_group.rds.id]
  
  tags = {
    Name        = "${var.project_name}-user-db"
    Environment = var.environment
  }

  # Habilitamos monitoreo básico
  monitoring_interval = 60
  monitoring_role_arn = aws_iam_role.rds_monitoring_role.arn
  
  # Habilitamos backups automáticos
  backup_retention_period = 7
  backup_window = "03:00-05:00"
  maintenance_window = "Mon:00:00-Mon:03:00"
}

# Base de datos para el servicio de productos
resource "aws_db_instance" "product_db" {
  identifier           = "${var.project_name}-product-db"
  allocated_storage    = 20
  storage_type         = "gp2"
  engine               = "postgres"
  engine_version       = "13"
  instance_class       = var.db_instance_class
  db_name              = var.db_name_product
  username             = var.db_username
  password             = var.db_password
  parameter_group_name = "default.postgres13"
  skip_final_snapshot  = true
  db_subnet_group_name = aws_db_subnet_group.main.name
  vpc_security_group_ids = [aws_security_group.rds.id]
  
  tags = {
    Name        = "${var.project_name}-product-db"
    Environment = var.environment
  }
  
  # Habilitamos monitoreo básico
  monitoring_interval = 60
  monitoring_role_arn = aws_iam_role.rds_monitoring_role.arn
  
  # Habilitamos backups automáticos
  backup_retention_period = 7
  backup_window = "03:00-05:00"
  maintenance_window = "Mon:00:00-Mon:03:00"
}

# Rol para monitoreo de RDS
resource "aws_iam_role" "rds_monitoring_role" {
  name = "${var.project_name}-rds-monitoring-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "monitoring.rds.amazonaws.com"
        }
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "rds_monitoring_attachment" {
  role       = aws_iam_role.rds_monitoring_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonRDSEnhancedMonitoringRole"
}

# ======================================================
# INSTANCIAS EC2
# ======================================================

# IP Elástica para instancia EC2
resource "aws_eip" "backend" {
  vpc = true
  
  tags = {
    Name        = "${var.project_name}-backend-eip"
    Environment = var.environment
  }
}

# EC2 para servicios de backend
resource "aws_instance" "backend" {
  ami                    = var.ec2_ami
  instance_type          = var.instance_type
  key_name               = var.ssh_key_name
  subnet_id              = aws_subnet.public[0].id
  vpc_security_group_ids = [aws_security_group.ec2.id]
  iam_instance_profile   = aws_iam_instance_profile.ec2_profile.name
  
  # Script de arranque mejorado
  user_data = <<-EOF
              #!/bin/bash
              apt-get update
              apt-get install -y python3-pip python3-boto3 docker.io docker-compose awscli
              systemctl enable docker
              systemctl start docker
              usermod -aG docker ubuntu
              
              # Crear directorio para aplicación
              mkdir -p /home/ubuntu/appgestion
              chown -R ubuntu:ubuntu /home/ubuntu/appgestion
              
              # Instalar dependencias para monitoreo
              apt-get install -y jq htop net-tools
              EOF
  
  tags = {
    Name        = "${var.project_name}-backend"
    Environment = var.environment
  }
  
  # Añadir volumen para datos persistentes
  root_block_device {
    volume_size = 20
    volume_type = "gp2"
    delete_on_termination = false
    tags = {
      Name = "${var.project_name}-backend-volume"
    }
  }
}

# Asociar IP Elástica a la instancia EC2
resource "aws_eip_association" "backend" {
  instance_id   = aws_instance.backend.id
  allocation_id = aws_eip.backend.id
}

# ======================================================
# S3 Y CLOUDFRONT PARA FRONTEND
# ======================================================

# Nombre del bucket S3 para el frontend
locals {
  s3_bucket_name = var.frontend_bucket_name != null ? var.frontend_bucket_name : "${var.project_name}-frontend-${random_string.suffix.result}"
  frontend_origin_id = "S3Origin"
}

# Genera un sufijo aleatorio para el nombre del bucket
resource "random_string" "suffix" {
  length  = 8
  special = false
  upper   = false
}

# Bucket S3 para alojar el frontend
resource "aws_s3_bucket" "frontend" {
  bucket = local.s3_bucket_name
  
  tags = {
    Name        = "${var.project_name}-frontend"
    Environment = var.environment
  }
}

# Configuración de ACL para S3
resource "aws_s3_bucket_ownership_controls" "frontend" {
  bucket = aws_s3_bucket.frontend.id
  rule {
    object_ownership = "BucketOwnerPreferred"
  }
}

# Bloquear acceso público al bucket S3
resource "aws_s3_bucket_public_access_block" "frontend" {
  bucket                  = aws_s3_bucket.frontend.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# CloudFront OAI para S3
resource "aws_cloudfront_origin_access_identity" "frontend" {
  comment = "OAI for ${var.project_name} frontend"
}

# Dar acceso a CloudFront para leer archivos de S3
resource "aws_s3_bucket_policy" "frontend" {
  bucket = aws_s3_bucket.frontend.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action    = "s3:GetObject"
        Effect    = "Allow"
        Resource  = "${aws_s3_bucket.frontend.arn}/*"
        Principal = {
          AWS = aws_cloudfront_origin_access_identity.frontend.iam_arn
        }
      }
    ]
  })
}

# CloudFront distribution para el frontend
resource "aws_cloudfront_distribution" "frontend" {
  origin {
    domain_name = aws_s3_bucket.frontend.bucket_regional_domain_name
    origin_id   = local.frontend_origin_id
    
    s3_origin_config {
      origin_access_identity = aws_cloudfront_origin_access_identity.frontend.cloudfront_access_identity_path
    }
  }
  
  enabled             = true
  is_ipv6_enabled     = true
  default_root_object = "index.html"
  price_class         = "PriceClass_100"  # Usar solo las ubicaciones más económicas
  
  # Configuración de caché
  default_cache_behavior {
    allowed_methods  = ["GET", "HEAD", "OPTIONS"]
    cached_methods   = ["GET", "HEAD"]
    target_origin_id = local.frontend_origin_id
    
    forwarded_values {
      query_string = false
      
      cookies {
        forward = "none"
      }
    }
    
    viewer_protocol_policy = "redirect-to-https"
    min_ttl                = 0
    default_ttl            = 3600
    max_ttl                = 86400
    compress               = true
  }
  
  # Configuración de caché para archivos estáticos
  ordered_cache_behavior {
    path_pattern     = "/static/*"
    allowed_methods  = ["GET", "HEAD", "OPTIONS"]
    cached_methods   = ["GET", "HEAD"]
    target_origin_id = local.frontend_origin_id
    
    forwarded_values {
      query_string = false
      
      cookies {
        forward = "none"
      }
    }
    
    viewer_protocol_policy = "redirect-to-https"
    min_ttl                = 0
    default_ttl            = 86400
    max_ttl                = 31536000  # 1 año para archivos estáticos
    compress               = true
  }
  
  # Restricciones geográficas
  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }
  
  # Certificado SSL (puede ser personalizado)
  viewer_certificate {
    cloudfront_default_certificate = true
  }
  
  # Para SPA (Single Page Applications)
  custom_error_response {
    error_code         = 403
    response_code      = 200
    response_page_path = "/index.html"
  }
  
  custom_error_response {
    error_code         = 404
    response_code      = 200
    response_page_path = "/index.html"
  }
  
  tags = {
    Name        = "${var.project_name}-cloudfront"
    Environment = var.environment
  }
}

# ======================================================
# API GATEWAY
# ======================================================

resource "aws_api_gateway_rest_api" "main" {
  name        = "${var.project_name}-api"
  description = "API para ${var.project_name}"
  
  endpoint_configuration {
    types = ["REGIONAL"]
  }
}

# ======================================================
# API GATEWAY - SERVICIO DE USUARIOS
# ======================================================

# Recurso para servicio de usuarios
resource "aws_api_gateway_resource" "users" {
  rest_api_id = aws_api_gateway_rest_api.main.id
  parent_id   = aws_api_gateway_rest_api.main.root_resource_id
  path_part   = "users"
}

# Método ANY para permitir todas las operaciones HTTP
resource "aws_api_gateway_method" "users_proxy" {
  rest_api_id   = aws_api_gateway_rest_api.main.id
  resource_id   = aws_api_gateway_resource.users.id
  http_method   = "ANY"
  authorization = "NONE"
}

resource "aws_api_gateway_integration" "users_proxy" {
  rest_api_id = aws_api_gateway_rest_api.main.id
  resource_id = aws_api_gateway_resource.users.id
  http_method = aws_api_gateway_method.users_proxy.http_method
  
  type                    = "HTTP_PROXY"
  # Usamos la IP elástica para estabilidad
  uri                     = "http://${aws_eip.backend.public_ip}:3001/users"
  integration_http_method = "ANY"
}

# Respuesta del método para incluir encabezados CORS
resource "aws_api_gateway_method_response" "users_proxy_response" {
  rest_api_id = aws_api_gateway_rest_api.main.id
  resource_id = aws_api_gateway_resource.users.id
  http_method = aws_api_gateway_method.users_proxy.http_method
  status_code = "200"
  
  response_parameters = {
    "method.response.header.Access-Control-Allow-Origin"      = true,
    "method.response.header.Access-Control-Allow-Methods"     = true,
    "method.response.header.Access-Control-Allow-Headers"     = true,
    "method.response.header.Access-Control-Allow-Credentials" = true
  }
}

# Respuesta de integración para configurar valores de encabezados CORS
resource "aws_api_gateway_integration_response" "users_proxy_integration_response" {
  rest_api_id = aws_api_gateway_rest_api.main.id
  resource_id = aws_api_gateway_resource.users.id
  http_method = aws_api_gateway_method.users_proxy.http_method
  status_code = aws_api_gateway_method_response.users_proxy_response.status_code
  
  # Corregido: Usar CloudFront como origen permitido en lugar de '*'
  response_parameters = {
    "method.response.header.Access-Control-Allow-Origin"      = "'https://${aws_cloudfront_distribution.frontend.domain_name}'",
    "method.response.header.Access-Control-Allow-Headers"     = "'Content-Type,X-Amz-Date,Authorization,X-Api-Key,X-Requested-With'",
    "method.response.header.Access-Control-Allow-Methods"     = "'GET,POST,PUT,DELETE,OPTIONS'",
    "method.response.header.Access-Control-Allow-Credentials" = "'true'"
  }
  
  depends_on = [
    aws_api_gateway_integration.users_proxy
  ]
}

# Método OPTIONS para CORS preflight
resource "aws_api_gateway_method" "users_options" {
  rest_api_id   = aws_api_gateway_rest_api.main.id
  resource_id   = aws_api_gateway_resource.users.id
  http_method   = "OPTIONS"
  authorization = "NONE"
}

resource "aws_api_gateway_integration" "users_options" {
  rest_api_id = aws_api_gateway_rest_api.main.id
  resource_id = aws_api_gateway_resource.users.id
  http_method = aws_api_gateway_method.users_options.http_method
  type        = "MOCK"
  
  request_templates = {
    "application/json" = "{\"statusCode\": 200}"
  }
}

resource "aws_api_gateway_method_response" "users_options_200" {
  rest_api_id = aws_api_gateway_rest_api.main.id
  resource_id = aws_api_gateway_resource.users.id
  http_method = aws_api_gateway_method.users_options.http_method
  status_code = "200"
  
  response_parameters = {
    "method.response.header.Access-Control-Allow-Headers"     = true,
    "method.response.header.Access-Control-Allow-Methods"     = true,
    "method.response.header.Access-Control-Allow-Origin"      = true,
    "method.response.header.Access-Control-Allow-Credentials" = true
  }
  
  response_models = {
    "application/json" = "Empty"
  }
}

resource "aws_api_gateway_integration_response" "users_options_integration_response" {
  rest_api_id = aws_api_gateway_rest_api.main.id
  resource_id = aws_api_gateway_resource.users.id
  http_method = aws_api_gateway_method.users_options.http_method
  status_code = aws_api_gateway_method_response.users_options_200.status_code
  
  # Corregido: Usar CloudFront como origen permitido en lugar de '*'
  response_parameters = {
    "method.response.header.Access-Control-Allow-Headers"     = "'Content-Type,X-Amz-Date,Authorization,X-Api-Key,X-Requested-With'",
    "method.response.header.Access-Control-Allow-Methods"     = "'GET,POST,PUT,DELETE,OPTIONS'",
    "method.response.header.Access-Control-Allow-Origin"      = "'https://${aws_cloudfront_distribution.frontend.domain_name}'",
    "method.response.header.Access-Control-Allow-Credentials" = "'true'"
  }
}

# ======================================================
# API GATEWAY - SERVICIO DE PRODUCTOS
# ======================================================

# Recurso para servicio de productos
resource "aws_api_gateway_resource" "products" {
  rest_api_id = aws_api_gateway_rest_api.main.id
  parent_id   = aws_api_gateway_rest_api.main.root_resource_id
  path_part   = "products"
}

# Método ANY para permitir todas las operaciones HTTP
resource "aws_api_gateway_method" "products_proxy" {
  rest_api_id   = aws_api_gateway_rest_api.main.id
  resource_id   = aws_api_gateway_resource.products.id
  http_method   = "ANY"
  authorization = "NONE"
}

resource "aws_api_gateway_integration" "products_proxy" {
  rest_api_id = aws_api_gateway_rest_api.main.id
  resource_id = aws_api_gateway_resource.products.id
  http_method = aws_api_gateway_method.products_proxy.http_method
  
  type                    = "HTTP_PROXY"
  # Usamos la IP elástica para estabilidad
  uri                     = "http://${aws_eip.backend.public_ip}:3002/products"
  integration_http_method = "ANY"
}

# Respuesta del método para incluir encabezados CORS
resource "aws_api_gateway_method_response" "products_proxy_response" {
  rest_api_id = aws_api_gateway_rest_api.main.id
  resource_id = aws_api_gateway_resource.products.id
  http_method = aws_api_gateway_method.products_proxy.http_method
  status_code = "200"
  
  response_parameters = {
    "method.response.header.Access-Control-Allow-Origin"      = true,
    "method.response.header.Access-Control-Allow-Methods"     = true,
    "method.response.header.Access-Control-Allow-Headers"     = true,
    "method.response.header.Access-Control-Allow-Credentials" = true
  }
}

# Respuesta de integración para configurar valores de encabezados CORS
resource "aws_api_gateway_integration_response" "products_proxy_integration_response" {
  rest_api_id = aws_api_gateway_rest_api.main.id
  resource_id = aws_api_gateway_resource.products.id
  http_method = aws_api_gateway_method.products_proxy.http_method
  status_code = aws_api_gateway_method_response.products_proxy_response.status_code
  
  # Corregido: Usar CloudFront como origen permitido en lugar de '*'
  response_parameters = {
    "method.response.header.Access-Control-Allow-Origin"      = "'https://${aws_cloudfront_distribution.frontend.domain_name}'",
    "method.response.header.Access-Control-Allow-Headers"     = "'Content-Type,X-Amz-Date,Authorization,X-Api-Key,X-Requested-With'",
    "method.response.header.Access-Control-Allow-Methods"     = "'GET,POST,PUT,DELETE,OPTIONS'",
    "method.response.header.Access-Control-Allow-Credentials" = "'true'"
  }
  
  depends_on = [
    aws_api_gateway_integration.products_proxy
  ]
}

# Método OPTIONS para CORS preflight
resource "aws_api_gateway_method" "products_options" {
  rest_api_id   = aws_api_gateway_rest_api.main.id
  resource_id   = aws_api_gateway_resource.products.id
  http_method   = "OPTIONS"
  authorization = "NONE"
}

resource "aws_api_gateway_integration" "products_options" {
  rest_api_id = aws_api_gateway_rest_api.main.id
  resource_id = aws_api_gateway_resource.products.id
  http_method = aws_api_gateway_method.products_options.http_method
  type        = "MOCK"
  
  request_templates = {
    "application/json" = "{\"statusCode\": 200}"
  }
}

resource "aws_api_gateway_method_response" "products_options_200" {
  rest_api_id = aws_api_gateway_rest_api.main.id
  resource_id = aws_api_gateway_resource.products.id
  http_method = aws_api_gateway_method.products_options.http_method
  status_code = "200"
  
  response_parameters = {
    "method.response.header.Access-Control-Allow-Headers"     = true,
    "method.response.header.Access-Control-Allow-Methods"     = true,
    "method.response.header.Access-Control-Allow-Origin"      = true,
    "method.response.header.Access-Control-Allow-Credentials" = true
  }
  
  response_models = {
    "application/json" = "Empty"
  }
}

resource "aws_api_gateway_integration_response" "products_options_integration_response" {
  rest_api_id = aws_api_gateway_rest_api.main.id
  resource_id = aws_api_gateway_resource.products.id
  http_method = aws_api_gateway_method.products_options.http_method
  status_code = aws_api_gateway_method_response.products_options_200.status_code
  
  # Corregido: Usar CloudFront como origen permitido en lugar de '*'
  response_parameters = {
    "method.response.header.Access-Control-Allow-Headers"     = "'Content-Type,X-Amz-Date,Authorization,X-Api-Key,X-Requested-With'",
    "method.response.header.Access-Control-Allow-Methods"     = "'GET,POST,PUT,DELETE,OPTIONS'",
    "method.response.header.Access-Control-Allow-Origin"      = "'https://${aws_cloudfront_distribution.frontend.domain_name}'",
    "method.response.header.Access-Control-Allow-Credentials" = "'true'"
  }
}

# Despliegue de la API
resource "aws_api_gateway_deployment" "main" {
  depends_on = [
    aws_api_gateway_integration.users_proxy,
    aws_api_gateway_integration.products_proxy,
    aws_api_gateway_integration.users_options,
    aws_api_gateway_integration.products_options,
    aws_api_gateway_integration_response.users_options_integration_response,
    aws_api_gateway_integration_response.products_options_integration_response
  ]
  
  rest_api_id = aws_api_gateway_rest_api.main.id
  stage_name  = var.environment
  
  # Asegurar que cada cambio en la API cause un nuevo despliegue
  stage_description = "Deployment created at ${timestamp()}"
  
  lifecycle {
    create_before_destroy = true
  }
}

# Habilitar CORS para el stage completo
resource "aws_api_gateway_method_settings" "all" {
  rest_api_id = aws_api_gateway_rest_api.main.id
  stage_name  = aws_api_gateway_deployment.main.stage_name
  method_path = "*/*"

  settings {
    metrics_enabled = false
    logging_level   = "OFF"
  }
}

# ======================================================
# PROVISIONING CON ANSIBLE
# ======================================================

# Archivo local para inventario Ansible
resource "local_file" "ansible_inventory" {
  content = templatefile("${path.module}/templates/inventory.tmpl", {
    backend_ip = aws_eip.backend.public_ip,
    ssh_key_path = var.ssh_key_path
  })
  filename = "${path.module}/../ansible/inventory/hosts.ini"
}

# Archivo local para variables Ansible
resource "local_file" "ansible_vars" {
  content = templatefile("${path.module}/templates/vars.tmpl", {
    project_name    = var.project_name
    environment     = var.environment
    region          = var.aws_region
    db_secret_name  = aws_secretsmanager_secret.db_credentials.name
    docker_secret_name = aws_secretsmanager_secret.docker_credentials.name
    s3_bucket       = aws_s3_bucket.frontend.bucket
    cloudfront_url  = aws_cloudfront_distribution.frontend.domain_name
    api_endpoint    = aws_api_gateway_deployment.main.invoke_url
  })
  filename = "${path.module}/../ansible/group_vars/all.yml"
}

# Output para SSH key path
resource "local_file" "ssh_key_path_output" {
  content  = var.ssh_key_path
  filename = "${path.module}/ssh_key_path.txt"
}