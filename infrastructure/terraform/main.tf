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

# Subnet publica para servicios accesibles
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
# SG para servicios - permitir trafico web y SSH para administracion
resource "aws_security_group" "services" {
  name        = "${var.project_name}-services-sg"
  description = "Permite trafico para los servicios"
  vpc_id      = aws_vpc.main.id
  
  # SSH - solo desde IP especifica
  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.allowed_ssh_ip]
    description = "SSH"
  }
  
  # HTTP para los servicios - abierto a internet
  ingress {
    from_port   = 3001
    to_port     = 3002
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "Puertos de servicios"
  }
  
  # HTTP estandar para ALB
  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "HTTP ALB"
  }
  
  # Permitir todo el trafico de salida
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
    description = "Todo el trafico de salida"
  }
}

# SG para bases de datos - permitir solo desde servicios
resource "aws_security_group" "rds" {
  name        = "${var.project_name}-rds-sg"
  description = "Permite conexiones a bases de datos"
  vpc_id      = aws_vpc.main.id
  
  # Acceso PostgreSQL desde servicios
  ingress {
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.services.id]
    description     = "PostgreSQL desde servicios"
  }
  
  # Para desarrollo, tambien permitir desde la IP del desarrollador
  ingress {
    from_port   = 5432
    to_port     = 5432
    protocol    = "tcp"
    cidr_blocks = [var.allowed_ssh_ip]
    description = "PostgreSQL desde desarrollador"
  }
  
  # Permitir todo el trafico de salida
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
    description = "Todo el trafico de salida"
  }
}

# ALMACENAMIENTO DE SECRETOS
resource "aws_secretsmanager_secret" "db_credentials" {
  name                    = "${var.project_name}-db-credentials-${formatdate("YYYYMMDD", timestamp())}"
  recovery_window_in_days = 0
  
  tags = {
    Name = "${var.project_name}-db-credentials"
  }
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

# INSTANCIAS EC2 CORREGIDAS
# AMI de Ubuntu mas reciente
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

resource "aws_iam_instance_profile" "ec2_profile" {
  name = "${var.project_name}-ec2-profile"
  role = aws_iam_role.ec2_role.name
}

# EC2 para servicio de usuarios - COMPLETAMENTE CORREGIDO
resource "aws_instance" "user_service" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = var.instance_type
  key_name               = var.ssh_key_name
  vpc_security_group_ids = [aws_security_group.services.id]
  subnet_id              = aws_subnet.public[0].id
  iam_instance_profile   = aws_iam_instance_profile.ec2_profile.name
  
  user_data = <<-EOF
#!/bin/bash
# Mejora para user_service
set -e
exec > >(tee /var/log/user-data.log) 2>&1

echo "INICIANDO CONFIGURACION DE USER-SERVICE..."
apt-get update && apt-get install -y docker.io awscli curl postgresql-client jq

# Crear variables de entorno con valores correctos
cat > /etc/environment <<EOL
POSTGRES_HOST=${aws_db_instance.user_db.address}
POSTGRES_USER=${var.db_username}
POSTGRES_PASSWORD=${var.db_password}
POSTGRES_DB=${var.db_name_user}
POSTGRES_PORT=5432
DB_MAX_RETRIES=120  # Aumentar para dar mas tiempo
DB_RETRY_INTERVAL=5
EOL

# Exportar variables para este script
set -a
source /etc/environment
set +a

# Verificar PostgreSQL con reintento extendido
echo "VERIFICANDO CONEXION A POSTGRESQL..."
max_attempts=60  # 10 minutos
attempt=1
while [ $attempt -le $max_attempts ]; do
  echo "Intento $attempt/$max_attempts: Conectando a PostgreSQL..."
  if PGPASSWORD=$POSTGRES_PASSWORD psql -h $POSTGRES_HOST -U $POSTGRES_USER -d $POSTGRES_DB -c "SELECT 1" > /dev/null 2>&1; then
    echo "✅ Conexion a PostgreSQL exitosa"
    # Crear tablas iniciales si es necesario
    PGPASSWORD=$POSTGRES_PASSWORD psql -h $POSTGRES_HOST -U $POSTGRES_USER -d $POSTGRES_DB -c "
      CREATE TABLE IF NOT EXISTS users (
        id SERIAL PRIMARY KEY,
        name VARCHAR(100) NOT NULL,
        email VARCHAR(100) UNIQUE NOT NULL,
        password_hash VARCHAR(256) NOT NULL,
        created_at TIMESTAMP DEFAULT NOW(),
        updated_at TIMESTAMP DEFAULT NOW()
      );"
    break
  fi
  echo "Conexion fallida. Reintentando en 10 segundos..."
  sleep 10
  attempt=$((attempt+1))
done

if [ $attempt -gt $max_attempts ]; then
  echo "❌ Error: No se pudo conectar a PostgreSQL despues de $max_attempts intentos"
  exit 1
fi

# Eliminar contenedores previos si existen
docker rm -f user-service || true

# Ejecutar contenedor Docker con variables correctas
echo "INICIANDO CONTENEDOR DOCKER..."
docker pull ${var.dockerhub_username}/appgestion-user-service:latest
docker run -d --name user-service \
  --restart always \
  -p 3001:3001 \
  -e POSTGRES_HOST=$POSTGRES_HOST \
  -e POSTGRES_USER=$POSTGRES_USER \
  -e POSTGRES_PASSWORD=$POSTGRES_PASSWORD \
  -e POSTGRES_DB=$POSTGRES_DB \
  -e POSTGRES_PORT=$POSTGRES_PORT \
  -e DB_MAX_RETRIES=$DB_MAX_RETRIES \
  -e DB_RETRY_INTERVAL=$DB_RETRY_INTERVAL \
  ${var.dockerhub_username}/appgestion-user-service:latest

# Verificar que el servicio esta disponible
echo "VERIFICANDO DISPONIBILIDAD DEL SERVICIO..."
attempt=1
max_attempts=30
while [ $attempt -le $max_attempts ]; do
  echo "Intento $attempt/$max_attempts: Verificando servicio..."
  if curl -s http://localhost:3001/health | grep -q "healthy"; then
    echo "✅ Servicio disponible"
    break
  fi
  
  # Mostrar logs si hay problemas
  if [ $attempt -eq 10 ]; then
    echo "⚠️ Mostrando logs del contenedor para diagnostico:"
    docker logs user-service
  fi
  
  echo "Servicio no disponible. Reintentando en 10 segundos..."
  sleep 10
  attempt=$((attempt+1))
done

if [ $attempt -gt $max_attempts ]; then
  echo "❌ Error: El servicio no esta disponible despues de $max_attempts intentos"
  docker logs user-service
  exit 1
fi

# Crear un script para diagnostico
cat > /home/ubuntu/diagnose.sh <<'EOS'
#!/bin/bash
echo "=== DIAGNOSTICO DEL SERVICIO ==="
echo "Informacion del sistema:"
uname -a
uptime
echo
echo "Docker containers:"
docker ps -a
echo
echo "Logs del contenedor:"
docker logs user-service
echo
echo "Verificacion de salud:"
curl -v http://localhost:3001/health
echo
echo "Prueba de conexion a BD:"
source /etc/environment
PGPASSWORD=$POSTGRES_PASSWORD psql -h $POSTGRES_HOST -U $POSTGRES_USER -d $POSTGRES_DB -c "SELECT count(*) FROM users;"
EOS

chmod +x /home/ubuntu/diagnose.sh
echo "✅ CONFIGURACION COMPLETADA"
EOF
  
  tags = {
    Name = "${var.project_name}-user-service"
  }
  
  depends_on = [aws_db_instance.user_db]
}

# EC2 para servicio de productos - COMPLETAMENTE CORREGIDO
resource "aws_instance" "product_service" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = var.instance_type
  key_name               = var.ssh_key_name
  vpc_security_group_ids = [aws_security_group.services.id]
  subnet_id              = aws_subnet.public[0].id
  iam_instance_profile   = aws_iam_instance_profile.ec2_profile.name
  
  user_data = <<-EOF
#!/bin/bash
# Configuracion mejorada para product-service
set -e
exec > >(tee /var/log/user-data.log) 2>&1

echo "INICIANDO CONFIGURACION DE PRODUCT-SERVICE..."
apt-get update && apt-get install -y docker.io awscli curl postgresql-client jq

# Crear variables de entorno con valores correctos
cat > /etc/environment <<EOL
POSTGRES_HOST=${aws_db_instance.product_db.address}
POSTGRES_USER=${var.db_username}
POSTGRES_PASSWORD=${var.db_password}
POSTGRES_DB=${var.db_name_product}
POSTGRES_PORT=5432
DB_MAX_RETRIES=120  # Aumentar para dar mas tiempo
DB_RETRY_INTERVAL=5
EOL

# Exportar variables para este script
set -a
source /etc/environment
set +a

# Verificar PostgreSQL con reintento extendido
echo "VERIFICANDO CONEXION A POSTGRESQL..."
max_attempts=60  # 10 minutos
attempt=1
while [ $attempt -le $max_attempts ]; do
  echo "Intento $attempt/$max_attempts: Conectando a PostgreSQL..."
  if PGPASSWORD=$POSTGRES_PASSWORD psql -h $POSTGRES_HOST -U $POSTGRES_USER -d $POSTGRES_DB -c "SELECT 1" > /dev/null 2>&1; then
    echo "✅ Conexion a PostgreSQL exitosa"
    # Crear tablas iniciales si es necesario
    PGPASSWORD=$POSTGRES_PASSWORD psql -h $POSTGRES_HOST -U $POSTGRES_USER -d $POSTGRES_DB -c "
      CREATE TABLE IF NOT EXISTS products (
        id SERIAL PRIMARY KEY,
        name VARCHAR(100) NOT NULL,
        description TEXT,
        price DECIMAL(10,2) NOT NULL,
        stock INTEGER DEFAULT 0,
        created_at TIMESTAMP DEFAULT NOW(),
        updated_at TIMESTAMP DEFAULT NOW()
      );"
    break
  fi
  echo "Conexion fallida. Reintentando en 10 segundos..."
  sleep 10
  attempt=$((attempt+1))
done

if [ $attempt -gt $max_attempts ]; then
  echo "❌ Error: No se pudo conectar a PostgreSQL despues de $max_attempts intentos"
  exit 1
fi

# Eliminar contenedores previos si existen
docker rm -f product-service || true

# Ejecutar contenedor Docker con variables correctas
echo "INICIANDO CONTENEDOR DOCKER..."
docker pull ${var.dockerhub_username}/appgestion-product-service:latest
docker run -d --name product-service \
  --restart always \
  -p 3002:3002 \
  -e POSTGRES_HOST=$POSTGRES_HOST \
  -e POSTGRES_USER=$POSTGRES_USER \
  -e POSTGRES_PASSWORD=$POSTGRES_PASSWORD \
  -e POSTGRES_DB=$POSTGRES_DB \
  -e POSTGRES_PORT=$POSTGRES_PORT \
  -e DB_MAX_RETRIES=$DB_MAX_RETRIES \
  -e DB_RETRY_INTERVAL=$DB_RETRY_INTERVAL \
  ${var.dockerhub_username}/appgestion-product-service:latest

# Verificar que el servicio esta disponible
echo "VERIFICANDO DISPONIBILIDAD DEL SERVICIO..."
attempt=1
max_attempts=30
while [ $attempt -le $max_attempts ]; do
  echo "Intento $attempt/$max_attempts: Verificando servicio..."
  if curl -s http://localhost:3002/health | grep -q "healthy"; then
    echo "✅ Servicio disponible"
    break
  fi
  
  # Mostrar logs si hay problemas
  if [ $attempt -eq 10 ]; then
    echo "⚠️ Mostrando logs del contenedor para diagnostico:"
    docker logs product-service
  fi
  
  echo "Servicio no disponible. Reintentando en 10 segundos..."
  sleep 10
  attempt=$((attempt+1))
done

if [ $attempt -gt $max_attempts ]; then
  echo "❌ Error: El servicio no esta disponible despues de $max_attempts intentos"
  docker logs product-service
  exit 1
fi

# Crear un script para diagnostico
cat > /home/ubuntu/diagnose.sh <<'EOS'
#!/bin/bash
echo "=== DIAGNOSTICO DEL SERVICIO ==="
echo "Informacion del sistema:"
uname -a
uptime
echo
echo "Docker containers:"
docker ps -a
echo
echo "Logs del contenedor:"
docker logs product-service
echo
echo "Verificacion de salud:"
curl -v http://localhost:3002/health
echo
echo "Prueba de conexion a BD:"
source /etc/environment
PGPASSWORD=$POSTGRES_PASSWORD psql -h $POSTGRES_HOST -U $POSTGRES_USER -d $POSTGRES_DB -c "SELECT count(*) FROM products;"
EOS

chmod +x /home/ubuntu/diagnose.sh
echo "✅ CONFIGURACION COMPLETADA"
EOF
  
  tags = {
    Name = "${var.project_name}-product-service"
  }
  
  depends_on = [aws_db_instance.product_db]
}

# LOAD BALANCERS SIMPLIFICADOS - USAMOS ALBs
# ALB para servicio de usuarios 
resource "aws_lb" "user_service" {
  name               = "${var.project_name}-user-alb"
  internal           = false
  load_balancer_type = "application"  # Volvemos a usar ALB
  security_groups    = [aws_security_group.services.id]
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
    path                = "/health"
    protocol            = "HTTP"
    port                = "3001"
    interval            = 30
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 2
    matcher             = "200"
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
  load_balancer_type = "application"  # Volvemos a usar ALB
  security_groups    = [aws_security_group.services.id]
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
    path                = "/health"
    protocol            = "HTTP"
    port                = "3002"
    interval            = 30
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 2
    matcher             = "200"
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
    Version = "2012-10-17",
    Statement = [
      {
        Effect    = "Allow",
        Principal = {
          AWS = aws_cloudfront_origin_access_identity.frontend.iam_arn
        },
        Action    = "s3:GetObject",
        Resource  = "${aws_s3_bucket.frontend.arn}/*"
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
    compress               = true
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

# API REST - SIMPLIFICADO PARA USAR HTTP PROXY
resource "aws_api_gateway_rest_api" "main" {
  name        = "${var.project_name}-api"
  description = "API para ${var.project_name}"
  
  endpoint_configuration {
    types = ["REGIONAL"]
  }
}

# CONFIGURACIoN DE CORS PARA API GATEWAY
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

# HTTP PROXY para endpoint de usuarios
resource "aws_api_gateway_method" "users_any" {
  rest_api_id   = aws_api_gateway_rest_api.main.id
  resource_id   = aws_api_gateway_resource.users.id
  http_method   = "ANY"
  authorization = "NONE"
}

resource "aws_api_gateway_integration" "users_any" {
  rest_api_id = aws_api_gateway_rest_api.main.id
  resource_id = aws_api_gateway_resource.users.id
  http_method = aws_api_gateway_method.users_any.http_method
  
  type                    = "HTTP_PROXY"
  uri                     = "http://${aws_lb.user_service.dns_name}/users"
  integration_http_method = "ANY"
  
  connection_type = "INTERNET"
  timeout_milliseconds = 29000  # 29 segundos (maximo permitido)
}

# CORS para usuarios
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
  
  type = "MOCK"
  
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
    "method.response.header.Access-Control-Allow-Headers" = true,
    "method.response.header.Access-Control-Allow-Methods" = true,
    "method.response.header.Access-Control-Allow-Origin" = true
  }
}

resource "aws_api_gateway_integration_response" "users_options" {
  rest_api_id = aws_api_gateway_rest_api.main.id
  resource_id = aws_api_gateway_resource.users.id
  http_method = aws_api_gateway_method.users_options.http_method
  status_code = aws_api_gateway_method_response.users_options_200.status_code
  
  response_parameters = {
    "method.response.header.Access-Control-Allow-Headers" = "'Content-Type,X-Amz-Date,Authorization,X-Api-Key,X-Requested-With,Accept'",
    "method.response.header.Access-Control-Allow-Methods" = "'GET,POST,PUT,DELETE,OPTIONS,PATCH'",
    "method.response.header.Access-Control-Allow-Origin" = "'*'"
  }
}

# HTTP PROXY para endpoint de productos
resource "aws_api_gateway_method" "products_any" {
  rest_api_id   = aws_api_gateway_rest_api.main.id
  resource_id   = aws_api_gateway_resource.products.id
  http_method   = "ANY"
  authorization = "NONE"
}

resource "aws_api_gateway_integration" "products_any" {
  rest_api_id = aws_api_gateway_rest_api.main.id
  resource_id = aws_api_gateway_resource.products.id
  http_method = aws_api_gateway_method.products_any.http_method
  
  type                    = "HTTP_PROXY"
  uri                     = "http://${aws_lb.product_service.dns_name}/products"
  integration_http_method = "ANY"
  
  connection_type = "INTERNET"
  timeout_milliseconds = 29000  # 29 segundos (maximo permitido)
}

# CORS para productos
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
  
  type = "MOCK"
  
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
    "method.response.header.Access-Control-Allow-Headers" = true,
    "method.response.header.Access-Control-Allow-Methods" = true,
    "method.response.header.Access-Control-Allow-Origin" = true
  }
}

resource "aws_api_gateway_integration_response" "products_options" {
  rest_api_id = aws_api_gateway_rest_api.main.id
  resource_id = aws_api_gateway_resource.products.id
  http_method = aws_api_gateway_method.products_options.http_method
  status_code = aws_api_gateway_method_response.products_options_200.status_code
  
  response_parameters = {
    "method.response.header.Access-Control-Allow-Headers" = "'Content-Type,X-Amz-Date,Authorization,X-Api-Key'",
    "method.response.header.Access-Control-Allow-Methods" = "'GET,POST,PUT,DELETE,OPTIONS'",
    "method.response.header.Access-Control-Allow-Origin" = "'*'"
  }
}

# PROXY PARA GESTIONAR RUTAS ANIDADAS
resource "aws_api_gateway_resource" "users_proxy" {
  rest_api_id = aws_api_gateway_rest_api.main.id
  parent_id   = aws_api_gateway_resource.users.id
  path_part   = "{proxy+}"
}

resource "aws_api_gateway_method" "users_proxy_any" {
  rest_api_id   = aws_api_gateway_rest_api.main.id
  resource_id   = aws_api_gateway_resource.users_proxy.id
  http_method   = "ANY"
  authorization = "NONE"
  
  request_parameters = {
    "method.request.path.proxy" = true
  }
}

resource "aws_api_gateway_integration" "users_proxy_any" {
  rest_api_id = aws_api_gateway_rest_api.main.id
  resource_id = aws_api_gateway_resource.users_proxy.id
  http_method = aws_api_gateway_method.users_proxy_any.http_method
  
  type                    = "HTTP_PROXY"
  uri                     = "http://${aws_lb.user_service.dns_name}/users/{proxy}"
  integration_http_method = "ANY"
  
  # No necesitamos VPC Link con ALBs publicos
  connection_type = "INTERNET"
  
  request_parameters = {
    "integration.request.path.proxy" = "method.request.path.proxy"
  }
}

resource "aws_api_gateway_resource" "products_proxy" {
  rest_api_id = aws_api_gateway_rest_api.main.id
  parent_id   = aws_api_gateway_resource.products.id
  path_part   = "{proxy+}"
}

resource "aws_api_gateway_method" "products_proxy_any" {
  rest_api_id   = aws_api_gateway_rest_api.main.id
  resource_id   = aws_api_gateway_resource.products_proxy.id
  http_method   = "ANY"
  authorization = "NONE"
  
  request_parameters = {
    "method.request.path.proxy" = true
  }
}

resource "aws_api_gateway_integration" "products_proxy_any" {
  rest_api_id = aws_api_gateway_rest_api.main.id
  resource_id = aws_api_gateway_resource.products_proxy.id
  http_method = aws_api_gateway_method.products_proxy_any.http_method
  
  type                    = "HTTP_PROXY"
  uri                     = "http://${aws_lb.product_service.dns_name}/products/{proxy}"
  integration_http_method = "ANY"
  
  # No necesitamos VPC Link con ALBs publicos
  connection_type = "INTERNET"
  
  request_parameters = {
    "integration.request.path.proxy" = "method.request.path.proxy"
  }
}

# Despliegue de API
resource "aws_api_gateway_deployment" "main" {
  depends_on = [
    aws_api_gateway_integration.users_any,
    aws_api_gateway_integration.products_any,
    aws_api_gateway_integration.users_options,
    aws_api_gateway_integration.products_options,
    aws_api_gateway_integration.users_proxy_any,
    aws_api_gateway_integration.products_proxy_any
  ]
  
  rest_api_id = aws_api_gateway_rest_api.main.id
  stage_name  = var.environment
  
  lifecycle {
    create_before_destroy = true
  }
}