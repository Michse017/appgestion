# PROVIDER CONFIGURATION
terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 4.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

# NETWORKING - VPC SIMPLIFICADA
resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true
  
  tags = {
    Name = "${var.project_name}-vpc"
  }
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id
  
  tags = {
    Name = "${var.project_name}-igw"
  }
}

# Subnet pública para servicios accesibles
resource "aws_subnet" "public" {
  count                   = length(var.availability_zones)
  vpc_id                  = aws_vpc.main.id
  cidr_block              = var.public_subnet_cidrs[count.index]
  availability_zone       = var.availability_zones[count.index]
  map_public_ip_on_launch = true
  
  tags = {
    Name = "${var.project_name}-public-subnet-${count.index + 1}"
  }
}

# Subnet privada para bases de datos
resource "aws_subnet" "private" {
  count             = length(var.availability_zones)
  vpc_id            = aws_vpc.main.id
  cidr_block        = var.private_subnet_cidrs[count.index]
  availability_zone = var.availability_zones[count.index]
  
  tags = {
    Name = "${var.project_name}-private-subnet-${count.index + 1}"
  }
}

# Routing
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id
  
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }
  
  tags = {
    Name = "${var.project_name}-public-route"
  }
}

resource "aws_route_table_association" "public" {
  count          = length(var.public_subnet_cidrs)
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# SECURITY GROUPS SIMPLIFICADOS
# SG para balanceadores de carga - permitir acceso web desde internet
resource "aws_security_group" "alb" {
  name        = "${var.project_name}-alb-sg"
  description = "Permite tráfico HTTP/HTTPS para ALBs"
  vpc_id      = aws_vpc.main.id
  
  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "HTTP desde cualquier origen"
  }
  
  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "HTTPS desde cualquier origen"
  }
  
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  
  tags = {
    Name = "${var.project_name}-alb-sg"
  }
}

# SG para servicios - permitir tráfico desde ALB y SSH para administración
resource "aws_security_group" "services" {
  name        = "${var.project_name}-services-sg"
  description = "Permite tráfico desde ALB a servicios"
  vpc_id      = aws_vpc.main.id
  
  # SSH - solo desde IP específica
  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.allowed_ssh_ip]
    description = "SSH acceso administrativo"
  }
  
  # Puerto para servicio de usuarios
  ingress {
    from_port       = 3001
    to_port         = 3001
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
    description     = "Tráfico al servicio de usuarios desde ALB"
  }
  
  # Puerto para servicio de productos
  ingress {
    from_port       = 3002
    to_port         = 3002
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
    description     = "Tráfico al servicio de productos desde ALB"
  }
  
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  
  tags = {
    Name = "${var.project_name}-services-sg"
  }
}

# SG para bases de datos - permitir sólo desde servicios
resource "aws_security_group" "rds" {
  name        = "${var.project_name}-rds-sg"
  description = "Permite conexiones a bases de datos"
  vpc_id      = aws_vpc.main.id
  
  # Acceso desde servicios
  ingress {
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.services.id]
    description     = "PostgreSQL desde servicios"
  }
  
  # Acceso desde desarrollador
  ingress {
    from_port   = 5432
    to_port     = 5432
    protocol    = "tcp"
    cidr_blocks = [var.allowed_ssh_ip]
    description = "PostgreSQL desde desarrollador"
  }
  
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  
  tags = {
    Name = "${var.project_name}-rds-sg"
  }
}

# ALMACENAMIENTO DE SECRETOS
resource "aws_secretsmanager_secret" "db_credentials" {
  name                    = "${var.project_name}-db-credentials"
  recovery_window_in_days = 0
  
  tags = {
    Name = "${var.project_name}-db-credentials"
  }
}

resource "aws_secretsmanager_secret_version" "db_credentials" {
  secret_id = aws_secretsmanager_secret.db_credentials.id
  secret_string = jsonencode({
    username        = var.db_username
    password        = var.db_password
    db_name_user    = var.db_name_user
    db_name_product = var.db_name_product
    host_user       = aws_db_instance.user_db.address
    host_product    = aws_db_instance.product_db.address
    port            = 5432
  })
  
  depends_on = [
    aws_db_instance.user_db,
    aws_db_instance.product_db
  ]
}

# BASES DE DATOS
resource "aws_db_subnet_group" "main" {
  name       = "${var.project_name}-db-subnet"
  subnet_ids = aws_subnet.private[*].id
  
  tags = {
    Name = "${var.project_name}-db-subnet-group"
  }
}

# Base de datos para usuarios
resource "aws_db_instance" "user_db" {
  identifier           = "${var.project_name}-user-db"
  allocated_storage    = 10
  engine               = "postgres"
  engine_version       = "13"
  instance_class       = var.db_instance_class
  db_name              = var.db_name_user
  username             = var.db_username
  password             = var.db_password
  parameter_group_name = "default.postgres13"
  skip_final_snapshot  = true
  publicly_accessible  = true  # Para facilitar desarrollo
  db_subnet_group_name = aws_db_subnet_group.main.name
  vpc_security_group_ids = [aws_security_group.rds.id]
  
  tags = {
    Name = "${var.project_name}-user-db"
  }
}

# Base de datos para productos
resource "aws_db_instance" "product_db" {
  identifier           = "${var.project_name}-product-db"
  allocated_storage    = 10
  engine               = "postgres"
  engine_version       = "13"
  instance_class       = var.db_instance_class
  db_name              = var.db_name_product
  username             = var.db_username
  password             = var.db_password
  parameter_group_name = "default.postgres13"
  skip_final_snapshot  = true
  publicly_accessible  = true  # Para facilitar desarrollo
  db_subnet_group_name = aws_db_subnet_group.main.name
  vpc_security_group_ids = [aws_security_group.rds.id]
  
  tags = {
    Name = "${var.project_name}-product-db"
  }
}

# INSTANCIAS EC2 SIMPLIFICADAS
# AMI de Ubuntu más reciente
data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical (Ubuntu)

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# IAM para acceso a secretos
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
  description = "Permite acceso a secretos"
  
  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Action = [
          "secretsmanager:GetSecretValue",
          "secretsmanager:ListSecrets"
        ],
        Effect = "Allow",
        Resource = "*"
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

# EC2 para servicio de usuarios
resource "aws_instance" "user_service" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = var.instance_type
  key_name               = var.ssh_key_name
  vpc_security_group_ids = [aws_security_group.services.id]
  subnet_id              = aws_subnet.public[0].id
  iam_instance_profile   = aws_iam_instance_profile.ec2_profile.name
  
  user_data = <<-EOF
    #!/bin/bash
    apt-get update && apt-get install -y docker.io awscli
    systemctl enable docker && systemctl start docker
    
    # Configure environment variables for the container
    cat > /etc/environment <<EOL
    POSTGRES_HOST=${aws_db_instance.user_db.address}
    POSTGRES_USER=${var.db_username}
    POSTGRES_PASSWORD=${var.db_password}
    POSTGRES_DB=${var.db_name_user}
    POSTGRES_PORT=5432
    DB_MAX_RETRIES=60
    DB_RETRY_INTERVAL=5
    EOL
    
    # Run container with corrected parameters
    docker pull ${var.dockerhub_username}/appgestion-user-service:latest
    docker run -d --name user-service \
      --restart always \
      -p 3001:3001 \
      --env-file /etc/environment \
      ${var.dockerhub_username}/appgestion-user-service:latest
    
    echo "Esperando a que el servicio esté disponible..."
    attempt=1
    max_attempts=30
    while [ $attempt -le $max_attempts ]; do
      echo "Intento $attempt/$max_attempts"
      if curl -s http://localhost:3001/health | grep -q "healthy"; then
        echo "Servicio disponible!"
        break
      fi
      echo "Servicio no disponible aún, esperando..."
      sleep 10
      attempt=$((attempt+1))
    done
  EOF
  
  tags = {
    Name = "${var.project_name}-user-service"
  }
  
  depends_on = [aws_db_instance.user_db]
}

# EC2 para servicio de productos
resource "aws_instance" "product_service" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = var.instance_type
  key_name               = var.ssh_key_name
  vpc_security_group_ids = [aws_security_group.services.id]
  subnet_id              = aws_subnet.public[0].id
  iam_instance_profile   = aws_iam_instance_profile.ec2_profile.name
  
  user_data = <<-EOF
    #!/bin/bash
    apt-get update && apt-get install -y docker.io awscli
    systemctl enable docker && systemctl start docker
    
    # Configure environment variables for the container
    cat > /etc/environment <<EOL
    POSTGRES_HOST=${aws_db_instance.product_db.address}
    POSTGRES_USER=${var.db_username}
    POSTGRES_PASSWORD=${var.db_password}
    POSTGRES_DB=${var.db_name_product}
    POSTGRES_PORT=5432
    DB_MAX_RETRIES=60
    DB_RETRY_INTERVAL=5
    EOL
    
    # Run container with corrected parameters
    docker pull ${var.dockerhub_username}/appgestion-product-service:latest
    docker run -d --name product-service \
      --restart always \
      -p 3002:3002 \
      --env-file /etc/environment \
      ${var.dockerhub_username}/appgestion-product-service:latest

    echo "Esperando a que el servicio esté disponible..."
    attempt=1
    max_attempts=30
    while [ $attempt -le $max_attempts ]; do
      echo "Intento $attempt/$max_attempts"
      if curl -s http://localhost:3002/health | grep -q "healthy"; then
        echo "Servicio disponible!"
        break
      fi
      echo "Servicio no disponible aún, esperando..."
      sleep 10
      attempt=$((attempt+1))
    done
  EOF
  
  tags = {
    Name = "${var.project_name}-product-service"
  }
  
  depends_on = [aws_db_instance.product_db]
}

# LOAD BALANCERS PARA SERVICIOS
# ALB para servicio de usuarios
resource "aws_lb" "user_service" {
  name               = "${var.project_name}-user-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = aws_subnet.public[*].id
  
  tags = {
    Name = "${var.project_name}-user-alb"
  }
}

resource "aws_lb_target_group" "user_service" {
  name     = "${var.project_name}-user-tg"
  port     = 3001
  protocol = "HTTP"
  vpc_id   = aws_vpc.main.id
  
  health_check {
    path     = "/health"
    interval = 30
    timeout  = 5
    matcher  = "200"
  }
}

resource "aws_lb_target_group_attachment" "user_service" {
  target_group_arn = aws_lb_target_group.user_service.arn
  target_id        = aws_instance.user_service.id
  port             = 3001
}

resource "aws_lb_listener" "user_service" {
  load_balancer_arn = aws_lb.user_service.arn
  port              = 80
  protocol          = "HTTP"
  
  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.user_service.arn
  }
}

# ALB para servicio de productos
resource "aws_lb" "product_service" {
  name               = "${var.project_name}-product-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = aws_subnet.public[*].id
  
  tags = {
    Name = "${var.project_name}-product-alb"
  }
}

resource "aws_lb_target_group" "product_service" {
  name     = "${var.project_name}-product-tg"
  port     = 3002
  protocol = "HTTP"
  vpc_id   = aws_vpc.main.id
  
  health_check {
    path     = "/health"
    interval = 30
    timeout  = 5
    matcher  = "200"
  }
}

resource "aws_lb_target_group_attachment" "product_service" {
  target_group_arn = aws_lb_target_group.product_service.arn
  target_id        = aws_instance.product_service.id
  port             = 3002
}

resource "aws_lb_listener" "product_service" {
  load_balancer_arn = aws_lb.product_service.arn
  port              = 80
  protocol          = "HTTP"
  
  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.product_service.arn
  }
}

# FRONTEND - S3 Y CLOUDFRONT
resource "random_string" "bucket_suffix" {
  length  = 8
  special = false
  upper   = false
}

resource "aws_s3_bucket" "frontend" {
  bucket = "${var.project_name}-frontend-${random_string.bucket_suffix.result}"
  
  tags = {
    Name = "${var.project_name}-frontend"
  }
}

resource "aws_s3_bucket_ownership_controls" "frontend" {
  bucket = aws_s3_bucket.frontend.id
  
  rule {
    object_ownership = "BucketOwnerPreferred"
  }
}

resource "aws_s3_bucket_public_access_block" "frontend" {
  bucket                  = aws_s3_bucket.frontend.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_website_configuration" "frontend" {
  bucket = aws_s3_bucket.frontend.id

  index_document {
    suffix = "index.html"
  }

  error_document {
    key = "index.html"
  }
}

resource "aws_cloudfront_origin_access_identity" "frontend" {
  comment = "OAI for ${var.project_name} frontend"
}

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

resource "aws_cloudfront_distribution" "frontend" {
  origin {
    domain_name = aws_s3_bucket.frontend.bucket_regional_domain_name
    origin_id   = "S3-${aws_s3_bucket.frontend.id}"
    
    s3_origin_config {
      origin_access_identity = aws_cloudfront_origin_access_identity.frontend.cloudfront_access_identity_path
    }
  }
  
  enabled             = true
  is_ipv6_enabled     = true
  default_root_object = "index.html"
  
  default_cache_behavior {
    allowed_methods  = ["GET", "HEAD", "OPTIONS"]
    cached_methods   = ["GET", "HEAD"]
    target_origin_id = "S3-${aws_s3_bucket.frontend.id}"
    
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
  }
  
  # Para aplicaciones SPA
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
  
  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }
  
  viewer_certificate {
    cloudfront_default_certificate = true
  }
  
  tags = {
    Name = "${var.project_name}-cloudfront"
  }
}

# API GATEWAY CON VPC LINK MEJORADO
# VPC Link para conectar API Gateway con recursos de la VPC
resource "aws_api_gateway_vpc_link" "main" {
  name        = "${var.project_name}-vpc-link"
  description = "VPC Link para conectar API Gateway con balanceadores internos"
  target_arns = [aws_lb.user_service.arn, aws_lb.product_service.arn]
}

resource "aws_api_gateway_rest_api" "main" {
  name        = "${var.project_name}-api"
  description = "API para ${var.project_name}"
  
  endpoint_configuration {
    types = ["REGIONAL"]
  }
}

# Recursos para los servicios
resource "aws_api_gateway_resource" "users" {
  rest_api_id = aws_api_gateway_rest_api.main.id
  parent_id   = aws_api_gateway_rest_api.main.root_resource_id
  path_part   = "users"
}

resource "aws_api_gateway_resource" "products" {
  rest_api_id = aws_api_gateway_rest_api.main.id
  parent_id   = aws_api_gateway_rest_api.main.root_resource_id
  path_part   = "products"
}

# Métodos ANY para permitir todos los verbos HTTP
resource "aws_api_gateway_method" "users_proxy" {
  rest_api_id   = aws_api_gateway_rest_api.main.id
  resource_id   = aws_api_gateway_resource.users.id
  http_method   = "ANY"
  authorization = "NONE"
}

resource "aws_api_gateway_method" "products_proxy" {
  rest_api_id   = aws_api_gateway_rest_api.main.id
  resource_id   = aws_api_gateway_resource.products.id
  http_method   = "ANY"
  authorization = "NONE"
}

# Integración mejorada para el servicio de usuarios - Utilizando VPC Link
resource "aws_api_gateway_integration" "users_proxy" {
  rest_api_id = aws_api_gateway_rest_api.main.id
  resource_id = aws_api_gateway_resource.users.id
  http_method = aws_api_gateway_method.users_proxy.http_method
  
  type                    = "HTTP_PROXY"
  uri                     = "http://${aws_lb.user_service.dns_name}/users"
  integration_http_method = "ANY"
  
  connection_type      = "VPC_LINK"  # CLAVE: Usar VPC Link en lugar de INTERNET
  connection_id        = aws_api_gateway_vpc_link.main.id
  
  # Tiempo de espera ampliado
  timeout_milliseconds = 29000
}

# Integración mejorada para el servicio de productos - Utilizando VPC Link
resource "aws_api_gateway_integration" "products_proxy" {
  rest_api_id = aws_api_gateway_rest_api.main.id
  resource_id = aws_api_gateway_resource.products.id
  http_method = aws_api_gateway_method.products_proxy.http_method
  
  type                    = "HTTP_PROXY"
  uri                     = "http://${aws_lb.product_service.dns_name}/products"
  integration_http_method = "ANY"
  
  connection_type      = "VPC_LINK"  # CLAVE: Usar VPC Link en lugar de INTERNET
  connection_id        = aws_api_gateway_vpc_link.main.id
  
  # Tiempo de espera ampliado
  timeout_milliseconds = 29000
}

# Endpoint ANY para ruta raíz
resource "aws_api_gateway_method" "users_any_root" {
  rest_api_id   = aws_api_gateway_rest_api.main.id
  resource_id   = aws_api_gateway_resource.users.id
  http_method   = "OPTIONS"
  authorization = "NONE"
}

# Integración para OPTIONS (CORS)
resource "aws_api_gateway_integration" "users_options_integration" {
  rest_api_id = aws_api_gateway_rest_api.main.id
  resource_id = aws_api_gateway_resource.users.id
  http_method = aws_api_gateway_method.users_any_root.http_method
  
  type = "MOCK"
  
  request_templates = {
    "application/json" = "{\"statusCode\": 200}"
  }
}

resource "aws_api_gateway_method_response" "users_options_200" {
  rest_api_id = aws_api_gateway_rest_api.main.id
  resource_id = aws_api_gateway_resource.users.id
  http_method = aws_api_gateway_method.users_any_root.http_method
  status_code = "200"
  
  response_parameters = {
    "method.response.header.Access-Control-Allow-Headers" = true,
    "method.response.header.Access-Control-Allow-Methods" = true,
    "method.response.header.Access-Control-Allow-Origin" = true
  }
}

resource "aws_api_gateway_integration_response" "users_options_integration_response" {
  rest_api_id = aws_api_gateway_rest_api.main.id
  resource_id = aws_api_gateway_resource.users.id
  http_method = aws_api_gateway_method.users_any_root.http_method
  status_code = aws_api_gateway_method_response.users_options_200.status_code
  
  response_parameters = {
    "method.response.header.Access-Control-Allow-Headers" = "'Content-Type,X-Amz-Date,Authorization,X-Api-Key'",
    "method.response.header.Access-Control-Allow-Methods" = "'GET,POST,PUT,DELETE,OPTIONS'",
    "method.response.header.Access-Control-Allow-Origin" = "'*'"
  }
}

# Lo mismo para productos
resource "aws_api_gateway_method" "products_any_root" {
  rest_api_id   = aws_api_gateway_rest_api.main.id
  resource_id   = aws_api_gateway_resource.products.id
  http_method   = "OPTIONS"
  authorization = "NONE"
}

resource "aws_api_gateway_integration" "products_options_integration" {
  rest_api_id = aws_api_gateway_rest_api.main.id
  resource_id = aws_api_gateway_resource.products.id
  http_method = aws_api_gateway_method.products_any_root.http_method
  
  type = "MOCK"
  
  request_templates = {
    "application/json" = "{\"statusCode\": 200}"
  }
}

resource "aws_api_gateway_method_response" "products_options_200" {
  rest_api_id = aws_api_gateway_rest_api.main.id
  resource_id = aws_api_gateway_resource.products.id
  http_method = aws_api_gateway_method.products_any_root.http_method
  status_code = "200"
  
  response_parameters = {
    "method.response.header.Access-Control-Allow-Headers" = true,
    "method.response.header.Access-Control-Allow-Methods" = true,
    "method.response.header.Access-Control-Allow-Origin" = true
  }
}

resource "aws_api_gateway_integration_response" "products_options_integration_response" {
  rest_api_id = aws_api_gateway_rest_api.main.id
  resource_id = aws_api_gateway_resource.products.id
  http_method = aws_api_gateway_method.products_any_root.http_method
  status_code = aws_api_gateway_method_response.products_options_200.status_code
  
  response_parameters = {
    "method.response.header.Access-Control-Allow-Headers" = "'Content-Type,X-Amz-Date,Authorization,X-Api-Key'",
    "method.response.header.Access-Control-Allow-Methods" = "'GET,POST,PUT,DELETE,OPTIONS'",
    "method.response.header.Access-Control-Allow-Origin" = "'*'"
  }
}

# Despliegue de API
resource "aws_api_gateway_deployment" "main" {
  depends_on = [
    aws_api_gateway_integration.users_proxy,
    aws_api_gateway_integration.products_proxy,
    aws_api_gateway_integration.users_options_integration,
    aws_api_gateway_integration.products_options_integration
  ]
  
  rest_api_id = aws_api_gateway_rest_api.main.id
  stage_name  = var.environment
  
  lifecycle {
    create_before_destroy = true
  }
}

# OUTPUTS
output "api_gateway_invoke_url" {
  description = "URL de invocación de API Gateway"
  value       = "${aws_api_gateway_deployment.main.invoke_url}/"
}

output "frontend_cloudfront_domain" {
  description = "Dominio CloudFront para el frontend"
  value       = aws_cloudfront_distribution.frontend.domain_name
}

output "frontend_bucket_name" {
  description = "Nombre del bucket S3 para el frontend"
  value       = aws_s3_bucket.frontend.bucket
}

output "user_service_dns" {
  description = "DNS del balanceador de carga para servicio de usuarios"
  value       = aws_lb.user_service.dns_name
}

output "product_service_dns" {
  description = "DNS del balanceador de carga para servicio de productos"
  value       = aws_lb.product_service.dns_name
}