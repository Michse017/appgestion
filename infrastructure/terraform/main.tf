# PROVIDER CONFIGURATION
terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 4.0"
    }
  }
}

# Buscar la AMI de Ubuntu más reciente
data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical (fabricante de Ubuntu)

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

provider "aws" {
  region = var.aws_region
}

# NETWORKING - VPC
resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true
  
  tags = {
    Name        = "${var.project_name}-vpc"
    Environment = var.environment
  }
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id
  
  tags = {
    Name        = "${var.project_name}-igw"
    Environment = var.environment
  }
}

# Subredes públicas y privadas
resource "aws_subnet" "public" {
  count                   = length(var.availability_zones)
  vpc_id                  = aws_vpc.main.id
  cidr_block              = var.public_subnet_cidrs[count.index]
  availability_zone       = var.availability_zones[count.index]
  map_public_ip_on_launch = true
  
  tags = {
    Name        = "${var.project_name}-public-subnet-${count.index + 1}"
    Environment = var.environment
  }
}

resource "aws_subnet" "private" {
  count             = length(var.availability_zones)
  vpc_id            = aws_vpc.main.id
  cidr_block        = var.private_subnet_cidrs[count.index]
  availability_zone = var.availability_zones[count.index]
  
  tags = {
    Name        = "${var.project_name}-private-subnet-${count.index + 1}"
    Environment = var.environment
  }
}

# Tabla de rutas
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

resource "aws_route_table_association" "public" {
  count          = length(var.public_subnet_cidrs)
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# SECURITY GROUPS
# Grupo de seguridad para ALB
resource "aws_security_group" "alb" {
  name        = "${var.project_name}-alb-sg"
  description = "Permite tráfico HTTP/HTTPS para los balanceadores de carga"
  vpc_id      = aws_vpc.main.id
  
  # HTTP
  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "HTTP access"
  }
  
  # HTTPS
  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "HTTPS access"
  }
  
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  
  tags = {
    Name        = "${var.project_name}-alb-sg"
    Environment = var.environment
  }
}

# Grupo para servicios de usuarios
resource "aws_security_group" "user_service" {
  name        = "${var.project_name}-user-service-sg"
  description = "Permite tráfico necesario para el servicio de usuarios"
  vpc_id      = aws_vpc.main.id
  
  # SSH - solo desde IP específica
  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.allowed_ssh_ip]
    description = "SSH acceso administrativo"
  }
  
  # Puerto específico para servicio de usuarios - Solo desde ALB
  ingress {
    from_port       = 3001
    to_port         = 3001
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
    description     = "User Service API desde ALB"
  }
  
  # Tráfico saliente
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  
  tags = {
    Name        = "${var.project_name}-user-service-sg"
    Environment = var.environment
  }
}

# Grupo para servicios de productos
resource "aws_security_group" "product_service" {
  name        = "${var.project_name}-product-service-sg"
  description = "Permite tráfico necesario para el servicio de productos"
  vpc_id      = aws_vpc.main.id
  
  # SSH - solo desde IP específica
  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.allowed_ssh_ip]
    description = "SSH acceso administrativo"
  }
  
  # Puerto específico para servicio de productos - Solo desde ALB
  ingress {
    from_port       = 3002
    to_port         = 3002
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
    description     = "Product Service API desde ALB"
  }
  
  # Tráfico saliente
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  
  tags = {
    Name        = "${var.project_name}-product-service-sg"
    Environment = var.environment
  }
}

# Security Group para RDS
resource "aws_security_group" "rds" {
  name        = "${var.project_name}-rds-sg"
  description = "Permite conexiones a bases de datos"
  vpc_id      = aws_vpc.main.id
  
  # Acceso desde IP administrador (desarrollo)
  ingress {
    from_port   = 5432
    to_port     = 5432
    protocol    = "tcp"
    cidr_blocks = [var.allowed_ssh_ip]
    description = "PostgreSQL desde IP administrador (temporal)"
  }

  # Acceso desde servicio de usuarios
  ingress {
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.user_service.id]
    description     = "PostgreSQL desde instancias user-service"
  }
  
  # Acceso desde servicio de productos
  ingress {
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.product_service.id]
    description     = "PostgreSQL desde instancias product-service"
  }
  
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

# SECRETS MANAGER
resource "aws_secretsmanager_secret" "db_credentials" {
  name                    = "${var.project_name}-db-credentials-${formatdate("YYYYMMDD-HHmmss", timestamp())}"
  recovery_window_in_days = 0  # Sin período de recuperación para facilitar pruebas
  
  tags = {
    Name        = "${var.project_name}-db-credentials"
    Environment = var.environment
  }
}

# Mejorado para incluir todos los datos necesarios
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

  # Asegurar que las bases de datos estén creadas antes de guardar sus direcciones
  depends_on = [
    aws_db_instance.user_db,
    aws_db_instance.product_db
  ]
}

# Secret para Docker Hub
resource "aws_secretsmanager_secret" "docker_credentials" {
  name                    = "${var.project_name}-docker-credentials-${formatdate("YYYYMMDD-HHmmss", timestamp())}"
  recovery_window_in_days = 0
  
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

# IAM ROLES
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

# Agregando permisos para EC2 adicionales (log, etc.)
resource "aws_iam_role_policy_attachment" "ssm_policy_attachment" {
  role       = aws_iam_role.ec2_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "ec2_profile" {
  name = "${var.project_name}-ec2-profile"
  role = aws_iam_role.ec2_role.name
}

# DATABASES
resource "aws_db_subnet_group" "main" {
  name       = "${var.project_name}-db-subnet"
  subnet_ids = aws_subnet.private[*].id
  
  tags = {
    Name        = "${var.project_name}-db-subnet-group"
    Environment = var.environment
  }
}

# Base de datos del servicio de usuarios
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
  publicly_accessible  = true  # Para desarrollo, facilita conexión directa
  db_subnet_group_name = aws_db_subnet_group.main.name
  vpc_security_group_ids = [aws_security_group.rds.id]
  
  backup_retention_period = var.environment == "production" ? 7 : 1
  
  tags = {
    Name        = "${var.project_name}-user-db"
    Environment = var.environment
  }
}

# Base de datos del servicio de productos
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
  publicly_accessible  = true  # Para desarrollo, facilita conexión directa
  db_subnet_group_name = aws_db_subnet_group.main.name
  vpc_security_group_ids = [aws_security_group.rds.id]
  
  backup_retention_period = var.environment == "production" ? 7 : 1
  
  tags = {
    Name        = "${var.project_name}-product-db"
    Environment = var.environment
  }
}

# INSTANCIAS EC2 Y AUTO SCALING
# Launch Template para User Service - Script mejorado para conexión a BD
resource "aws_launch_template" "user_service" {
  name_prefix   = "${var.project_name}-user-service-"
  image_id      = data.aws_ami.ubuntu.id
  instance_type = var.instance_type
  key_name      = var.ssh_key_name

  vpc_security_group_ids = [aws_security_group.user_service.id]
  
  iam_instance_profile {
    name = aws_iam_instance_profile.ec2_profile.name
  }
  
  user_data = base64encode(<<-EOF
    #!/bin/bash
    # Actualizar sistema y instalar dependencias
    apt-get update && apt-get upgrade -y
    apt-get install -y docker.io docker-compose awscli python3-pip curl jq
    
    # Configurar Docker
    systemctl enable docker
    systemctl start docker
    usermod -aG docker ubuntu
    
    # Configurar AWS CLI
    mkdir -p /home/ubuntu/.aws
    echo "[default]" > /home/ubuntu/.aws/config
    echo "region = ${var.aws_region}" >> /home/ubuntu/.aws/config
    chown -R ubuntu:ubuntu /home/ubuntu/.aws

    # Crear directorio para la aplicación
    mkdir -p /home/ubuntu/appgestion
    chown -R ubuntu:ubuntu /home/ubuntu/appgestion
    
    # Para evitar problemas de Docker ContainerConfig
    echo '{"experimental": true}' > /etc/docker/daemon.json
    systemctl restart docker
    
    # Obtener secretos y configurar el servicio
    SECRET_VALUE=$(aws secretsmanager get-secret-value --secret-id ${aws_secretsmanager_secret.db_credentials.name} --region ${var.aws_region} --query SecretString --output text)
    DB_HOST=$(echo $SECRET_VALUE | jq -r '.host_user')
    DB_NAME=$(echo $SECRET_VALUE | jq -r '.db_name_user')
    DB_USER=$(echo $SECRET_VALUE | jq -r '.username')
    DB_PASS=$(echo $SECRET_VALUE | jq -r '.password')
    
    # Obtener credenciales de Docker Hub
    DOCKER_SECRET=$(aws secretsmanager get-secret-value --secret-id ${aws_secretsmanager_secret.docker_credentials.name} --region ${var.aws_region} --query SecretString --output text)
    DOCKER_USER=$(echo $DOCKER_SECRET | jq -r '.username')
    DOCKER_PASS=$(echo $DOCKER_SECRET | jq -r '.password')
    
    # Login en Docker Hub
    echo "$DOCKER_PASS" | docker login -u "$DOCKER_USER" --password-stdin
    
    # Crear docker-compose.yml
    cat > /home/ubuntu/appgestion/docker-compose.yml << EOFDC
    version: '3.8'
    services:
      user-service:
        image: ${var.dockerhub_username}/appgestion-user-service:latest
        container_name: user-service
        environment:
          - POSTGRES_HOST=$DB_HOST
          - POSTGRES_DB=$DB_NAME
          - POSTGRES_USER=$DB_USER
          - POSTGRES_PASSWORD=$DB_PASS
          - POSTGRES_PORT=5432
          - CORS_ALLOWED_ORIGINS=*
          - API_GATEWAY_URL=https://${aws_api_gateway_deployment.main.rest_api_id}.execute-api.${var.aws_region}.amazonaws.com/${var.environment}
          - PORT=3001
          - SERVICE_URL=http://localhost:3001
          - ENVIRONMENT=${var.environment}
        ports:
          - "3001:3001"
        restart: always
    EOFDC
    
    # Iniciar servicio
    cd /home/ubuntu/appgestion
    docker-compose pull
    docker-compose up -d
    
    # Verificar logs para diagnóstico
    echo "==== Iniciando servicio de usuarios ====" > /var/log/appgestion-startup.log
    docker ps -a >> /var/log/appgestion-startup.log
    docker logs user-service >> /var/log/appgestion-startup.log 2>&1 &
  EOF
  )
  
  block_device_mappings {
    device_name = "/dev/sda1"
    
    ebs {
      volume_size = 20
      volume_type = "gp3"
      delete_on_termination = true
    }
  }
  
  tag_specifications {
    resource_type = "instance"
    
    tags = {
      Name        = "${var.project_name}-user-service"
      Environment = var.environment
      Service     = "user-service"
    }
  }
}

# Launch Template para Product Service - Script mejorado para conexión a BD
resource "aws_launch_template" "product_service" {
  name_prefix   = "${var.project_name}-product-service-"
  image_id      = data.aws_ami.ubuntu.id
  instance_type = var.instance_type
  key_name      = var.ssh_key_name
  
  vpc_security_group_ids = [aws_security_group.product_service.id]
  
  iam_instance_profile {
    name = aws_iam_instance_profile.ec2_profile.name
  }
  
  user_data = base64encode(<<-EOF
    #!/bin/bash
    # Actualizar sistema y instalar dependencias
    apt-get update && apt-get upgrade -y
    apt-get install -y docker.io docker-compose awscli python3-pip curl jq
    
    # Configurar Docker
    systemctl enable docker
    systemctl start docker
    usermod -aG docker ubuntu
    
    # Configurar AWS CLI
    mkdir -p /home/ubuntu/.aws
    echo "[default]" > /home/ubuntu/.aws/config
    echo "region = ${var.aws_region}" >> /home/ubuntu/.aws/config
    chown -R ubuntu:ubuntu /home/ubuntu/.aws

    # Crear directorio para la aplicación
    mkdir -p /home/ubuntu/appgestion
    chown -R ubuntu:ubuntu /home/ubuntu/appgestion
    
    # Para evitar problemas de Docker ContainerConfig
    echo '{"experimental": true}' > /etc/docker/daemon.json
    systemctl restart docker
    
    # Obtener secretos y configurar el servicio
    SECRET_VALUE=$(aws secretsmanager get-secret-value --secret-id ${aws_secretsmanager_secret.db_credentials.name} --region ${var.aws_region} --query SecretString --output text)
    DB_HOST=$(echo $SECRET_VALUE | jq -r '.host_product')
    DB_NAME=$(echo $SECRET_VALUE | jq -r '.db_name_product')
    DB_USER=$(echo $SECRET_VALUE | jq -r '.username')
    DB_PASS=$(echo $SECRET_VALUE | jq -r '.password')
    
    # Obtener credenciales de Docker Hub
    DOCKER_SECRET=$(aws secretsmanager get-secret-value --secret-id ${aws_secretsmanager_secret.docker_credentials.name} --region ${var.aws_region} --query SecretString --output text)
    DOCKER_USER=$(echo $DOCKER_SECRET | jq -r '.username')
    DOCKER_PASS=$(echo $DOCKER_SECRET | jq -r '.password')
    
    # Login en Docker Hub
    echo "$DOCKER_PASS" | docker login -u "$DOCKER_USER" --password-stdin
    
    # Crear docker-compose.yml
    cat > /home/ubuntu/appgestion/docker-compose.yml << EOFDC
    version: '3.8'
    services:
      product-service:
        image: ${var.dockerhub_username}/appgestion-product-service:latest
        container_name: product-service
        environment:
          - POSTGRES_HOST=$DB_HOST
          - POSTGRES_DB=$DB_NAME
          - POSTGRES_USER=$DB_USER
          - POSTGRES_PASSWORD=$DB_PASS
          - POSTGRES_PORT=5432
          - CORS_ALLOWED_ORIGINS=*
          - API_GATEWAY_URL=https://${aws_api_gateway_deployment.main.rest_api_id}.execute-api.${var.aws_region}.amazonaws.com/${var.environment}
          - PORT=3002
          - SERVICE_URL=http://localhost:3002
          - ENVIRONMENT=${var.environment}
        ports:
          - "3002:3002"
        restart: always
    EOFDC
    
    # Iniciar servicio
    cd /home/ubuntu/appgestion
    docker-compose pull
    docker-compose up -d
    
    # Verificar logs para diagnóstico
    echo "==== Iniciando servicio de productos ====" > /var/log/appgestion-startup.log
    docker ps -a >> /var/log/appgestion-startup.log
    docker logs product-service >> /var/log/appgestion-startup.log 2>&1 &
  EOF
  )
  
  block_device_mappings {
    device_name = "/dev/sda1"
    
    ebs {
      volume_size = 20
      volume_type = "gp3"
      delete_on_termination = true
    }
  }
  
  tag_specifications {
    resource_type = "instance"
    
    tags = {
      Name        = "${var.project_name}-product-service"
      Environment = var.environment
      Service     = "product-service"
    }
  }
}

# Auto-scaling Group para User Service
resource "aws_autoscaling_group" "user_service" {
  name                = "${var.project_name}-user-service-asg"
  min_size            = 1
  max_size            = 3
  desired_capacity    = 1
  vpc_zone_identifier = aws_subnet.public[*].id
  health_check_type   = "ELB"
  health_check_grace_period = 180
  
  launch_template {
    id      = aws_launch_template.user_service.id
    version = "$Latest"
  }
  
  tag {
    key                 = "Name"
    value               = "${var.project_name}-user-service"
    propagate_at_launch = true
  }
  
  tag {
    key                 = "Environment"
    value               = var.environment
    propagate_at_launch = true
  }
}

# Auto-scaling Group para Product Service
resource "aws_autoscaling_group" "product_service" {
  name                = "${var.project_name}-product-service-asg"
  min_size            = 1
  max_size            = 3
  desired_capacity    = 1
  vpc_zone_identifier = aws_subnet.public[*].id
  health_check_type   = "ELB"
  health_check_grace_period = 180
  
  launch_template {
    id      = aws_launch_template.product_service.id
    version = "$Latest"
  }
  
  tag {
    key                 = "Name"
    value               = "${var.project_name}-product-service"
    propagate_at_launch = true
  }
  
  tag {
    key                 = "Environment"
    value               = var.environment
    propagate_at_launch = true
  }
}

# LOAD BALANCERS
# ALB para User Service
resource "aws_lb" "user_service" {
  name               = "${var.project_name}-user-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = aws_subnet.public[*].id
  
  enable_deletion_protection = false
  
  tags = {
    Name        = "${var.project_name}-user-alb"
    Environment = var.environment
  }
}

# Target Group para User Service
resource "aws_lb_target_group" "user_service" {
  name     = "${var.project_name}-user-tg"
  port     = 3001
  protocol = "HTTP"
  vpc_id   = aws_vpc.main.id
  
  health_check {
    path                = "/users/health"
    interval            = 30
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 2
    matcher             = "200"
  }
}

# ALB Listener para User Service
resource "aws_lb_listener" "user_service" {
  load_balancer_arn = aws_lb.user_service.arn
  port              = 80
  protocol          = "HTTP"
  
  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.user_service.arn
  }
}

# Vincular Auto Scaling Group con Target Group para User Service
resource "aws_autoscaling_attachment" "user_service" {
  autoscaling_group_name = aws_autoscaling_group.user_service.name
  lb_target_group_arn    = aws_lb_target_group.user_service.arn
}

# ALB para Product Service
resource "aws_lb" "product_service" {
  name               = "${var.project_name}-product-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = aws_subnet.public[*].id
  
  enable_deletion_protection = false
  
  tags = {
    Name        = "${var.project_name}-product-alb"
    Environment = var.environment
  }
}

# Target Group para Product Service
resource "aws_lb_target_group" "product_service" {
  name     = "${var.project_name}-product-tg"
  port     = 3002
  protocol = "HTTP"
  vpc_id   = aws_vpc.main.id
  
  health_check {
    path                = "/products/health"
    interval            = 30
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 2
    matcher             = "200"
  }
}

# ALB Listener para Product Service
resource "aws_lb_listener" "product_service" {
  load_balancer_arn = aws_lb.product_service.arn
  port              = 80
  protocol          = "HTTP"
  
  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.product_service.arn
  }
}

# Vincular Auto Scaling Group con Target Group para Product Service
resource "aws_autoscaling_attachment" "product_service" {
  autoscaling_group_name = aws_autoscaling_group.product_service.name
  lb_target_group_arn    = aws_lb_target_group.product_service.arn
}

# S3 Y CLOUDFRONT PARA FRONTEND
# Bucket S3
resource "aws_s3_bucket" "frontend" {
  bucket = "${var.project_name}-frontend-${random_string.bucket_suffix.result}"
  
  tags = {
    Name        = "${var.project_name}-frontend"
    Environment = var.environment
  }
}

# Sufijo aleatorio para bucket
resource "random_string" "bucket_suffix" {
  length  = 8
  special = false
  upper   = false
}

# Ownership del Bucket para evitar ACLs obsoletos
resource "aws_s3_bucket_ownership_controls" "frontend" {
  bucket = aws_s3_bucket.frontend.id
  
  rule {
    object_ownership = "BucketOwnerPreferred"
  }
}

# Configuración de acceso al bucket
resource "aws_s3_bucket_public_access_block" "frontend" {
  bucket                  = aws_s3_bucket.frontend.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Configuración para website hosting
resource "aws_s3_bucket_website_configuration" "frontend" {
  bucket = aws_s3_bucket.frontend.id

  index_document {
    suffix = "index.html"
  }

  error_document {
    key = "index.html"
  }
}

# OAI para CloudFront
resource "aws_cloudfront_origin_access_identity" "frontend" {
  comment = "OAI for ${var.project_name} frontend"
}

# Política del bucket para CloudFront
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
  
  depends_on = [aws_s3_bucket_public_access_block.frontend]
}

# Distribución CloudFront
resource "aws_cloudfront_distribution" "frontend" {
  origin {
    domain_name = aws_s3_bucket.frontend.bucket_regional_domain_name
    origin_id   = "S3Origin"
    
    s3_origin_config {
      origin_access_identity = aws_cloudfront_origin_access_identity.frontend.cloudfront_access_identity_path
    }
  }
  
  enabled             = true
  is_ipv6_enabled     = true
  default_root_object = "index.html"
  price_class         = "PriceClass_100"
  
  default_cache_behavior {
    allowed_methods  = ["GET", "HEAD", "OPTIONS"]
    cached_methods   = ["GET", "HEAD"]
    target_origin_id = "S3Origin"
    
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
    Name        = "${var.project_name}-cloudfront"
    Environment = var.environment
  }
}

# API GATEWAY
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

resource "aws_api_gateway_resource" "users_proxy" {
  rest_api_id = aws_api_gateway_rest_api.main.id
  parent_id   = aws_api_gateway_resource.users.id
  path_part   = "{proxy+}"
}

resource "aws_api_gateway_resource" "products" {
  rest_api_id = aws_api_gateway_rest_api.main.id
  parent_id   = aws_api_gateway_rest_api.main.root_resource_id
  path_part   = "products"
}

resource "aws_api_gateway_resource" "products_proxy" {
  rest_api_id = aws_api_gateway_rest_api.main.id
  parent_id   = aws_api_gateway_resource.products.id
  path_part   = "{proxy+}"
}

# Métodos e integraciones para user service - apuntando al ALB
resource "aws_api_gateway_method" "users_root" {
  rest_api_id   = aws_api_gateway_rest_api.main.id
  resource_id   = aws_api_gateway_resource.users.id
  http_method   = "ANY"
  authorization = "NONE"
}

resource "aws_api_gateway_integration" "users_root" {
  rest_api_id = aws_api_gateway_rest_api.main.id
  resource_id = aws_api_gateway_resource.users.id
  http_method = aws_api_gateway_method.users_root.http_method
  
  type                    = "HTTP_PROXY"
  uri                     = "http://${aws_lb.user_service.dns_name}/users"
  integration_http_method = "ANY"
  
  connection_type = "INTERNET"
  timeout_milliseconds = 29000
}

resource "aws_api_gateway_method" "users_subpath" {
  rest_api_id   = aws_api_gateway_rest_api.main.id
  resource_id   = aws_api_gateway_resource.users_proxy.id
  http_method   = "ANY"
  authorization = "NONE"
  
  request_parameters = {
    "method.request.path.proxy" = true
  }
}

resource "aws_api_gateway_integration" "users_subpath" {
  rest_api_id = aws_api_gateway_rest_api.main.id
  resource_id = aws_api_gateway_resource.users_proxy.id
  http_method = aws_api_gateway_method.users_subpath.http_method
  
  type                    = "HTTP_PROXY"
  uri                     = "http://${aws_lb.user_service.dns_name}/users/{proxy}"
  integration_http_method = "ANY"
  
  connection_type = "INTERNET"
  timeout_milliseconds = 29000
  
  request_parameters = {
    "integration.request.path.proxy" = "method.request.path.proxy"
  }
}

# Métodos e integraciones para product service - apuntando al ALB
resource "aws_api_gateway_method" "products_root" {
  rest_api_id   = aws_api_gateway_rest_api.main.id
  resource_id   = aws_api_gateway_resource.products.id
  http_method   = "ANY"
  authorization = "NONE"
}

resource "aws_api_gateway_integration" "products_root" {
  rest_api_id = aws_api_gateway_rest_api.main.id
  resource_id = aws_api_gateway_resource.products.id
  http_method = aws_api_gateway_method.products_root.http_method
  
  type                    = "HTTP_PROXY"
  uri                     = "http://${aws_lb.product_service.dns_name}/products"
  integration_http_method = "ANY"
  
  connection_type = "INTERNET"
  timeout_milliseconds = 29000
}

resource "aws_api_gateway_method" "products_subpath" {
  rest_api_id   = aws_api_gateway_rest_api.main.id
  resource_id   = aws_api_gateway_resource.products_proxy.id
  http_method   = "ANY"
  authorization = "NONE"
  
  request_parameters = {
    "method.request.path.proxy" = true
  }
}

resource "aws_api_gateway_integration" "products_subpath" {
  rest_api_id = aws_api_gateway_rest_api.main.id
  resource_id = aws_api_gateway_resource.products_proxy.id
  http_method = aws_api_gateway_method.products_subpath.http_method
  
  type                    = "HTTP_PROXY"
  uri                     = "http://${aws_lb.product_service.dns_name}/products/{proxy}"
  integration_http_method = "ANY"
  
  connection_type = "INTERNET"
  timeout_milliseconds = 29000
  
  request_parameters = {
    "integration.request.path.proxy" = "method.request.path.proxy"
  }
}

# Configuración CORS mejorada
# Métodos OPTIONS para CORS
resource "aws_api_gateway_method" "users_options" {
  rest_api_id   = aws_api_gateway_rest_api.main.id
  resource_id   = aws_api_gateway_resource.users.id
  http_method   = "OPTIONS"
  authorization = "NONE"
}

resource "aws_api_gateway_method" "users_proxy_options" {
  rest_api_id   = aws_api_gateway_rest_api.main.id
  resource_id   = aws_api_gateway_resource.users_proxy.id
  http_method   = "OPTIONS"
  authorization = "NONE"
}

resource "aws_api_gateway_method" "products_options" {
  rest_api_id   = aws_api_gateway_rest_api.main.id
  resource_id   = aws_api_gateway_resource.products.id
  http_method   = "OPTIONS"
  authorization = "NONE"
}

resource "aws_api_gateway_method" "products_proxy_options" {
  rest_api_id   = aws_api_gateway_rest_api.main.id
  resource_id   = aws_api_gateway_resource.products_proxy.id
  http_method   = "OPTIONS"
  authorization = "NONE"
}

# Integraciones OPTIONS para CORS
resource "aws_api_gateway_integration" "users_options" {
  rest_api_id = aws_api_gateway_rest_api.main.id
  resource_id = aws_api_gateway_resource.users.id
  http_method = aws_api_gateway_method.users_options.http_method
  type        = "MOCK"
  request_templates = {
    "application/json" = "{\"statusCode\": 200}"
  }
}

resource "aws_api_gateway_integration" "users_proxy_options" {
  rest_api_id = aws_api_gateway_rest_api.main.id
  resource_id = aws_api_gateway_resource.users_proxy.id
  http_method = aws_api_gateway_method.users_proxy_options.http_method
  type        = "MOCK"
  request_templates = {
    "application/json" = "{\"statusCode\": 200}"
  }
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

resource "aws_api_gateway_integration" "products_proxy_options" {
  rest_api_id = aws_api_gateway_rest_api.main.id
  resource_id = aws_api_gateway_resource.products_proxy.id
  http_method = aws_api_gateway_method.products_proxy_options.http_method
  type        = "MOCK"
  request_templates = {
    "application/json" = "{\"statusCode\": 200}"
  }
}

# Method Responses para OPTIONS
resource "aws_api_gateway_method_response" "users_options" {
  rest_api_id = aws_api_gateway_rest_api.main.id
  resource_id = aws_api_gateway_resource.users.id
  http_method = aws_api_gateway_method.users_options.http_method
  status_code = "200"
  response_models = {
    "application/json" = "Empty"
  }
  response_parameters = {
    "method.response.header.Access-Control-Allow-Headers" = true,
    "method.response.header.Access-Control-Allow-Methods" = true,
    "method.response.header.Access-Control-Allow-Origin"  = true,
    "method.response.header.Access-Control-Max-Age"       = true
  }
}

resource "aws_api_gateway_method_response" "users_proxy_options" {
  rest_api_id = aws_api_gateway_rest_api.main.id
  resource_id = aws_api_gateway_resource.users_proxy.id
  http_method = aws_api_gateway_method.users_proxy_options.http_method
  status_code = "200"
  response_models = {
    "application/json" = "Empty"
  }
  response_parameters = {
    "method.response.header.Access-Control-Allow-Headers" = true,
    "method.response.header.Access-Control-Allow-Methods" = true,
    "method.response.header.Access-Control-Allow-Origin"  = true,
    "method.response.header.Access-Control-Max-Age"       = true
  }
}

resource "aws_api_gateway_method_response" "products_options" {
  rest_api_id = aws_api_gateway_rest_api.main.id
  resource_id = aws_api_gateway_resource.products.id
  http_method = aws_api_gateway_method.products_options.http_method
  status_code = "200"
  response_models = {
    "application/json" = "Empty"
  }
  response_parameters = {
    "method.response.header.Access-Control-Allow-Headers" = true,
    "method.response.header.Access-Control-Allow-Methods" = true,
    "method.response.header.Access-Control-Allow-Origin"  = true,
    "method.response.header.Access-Control-Max-Age"       = true
  }
}

resource "aws_api_gateway_method_response" "products_proxy_options" {
  rest_api_id = aws_api_gateway_rest_api.main.id
  resource_id = aws_api_gateway_resource.products_proxy.id
  http_method = aws_api_gateway_method.products_proxy_options.http_method
  status_code = "200"
  response_models = {
    "application/json" = "Empty"
  }
  response_parameters = {
    "method.response.header.Access-Control-Allow-Headers" = true,
    "method.response.header.Access-Control-Allow-Methods" = true,
    "method.response.header.Access-Control-Allow-Origin"  = true,
    "method.response.header.Access-Control-Max-Age"       = true
  }
}

# Integration Responses para OPTIONS - Soporte mejorado para CORS
resource "aws_api_gateway_integration_response" "users_options" {
  rest_api_id = aws_api_gateway_rest_api.main.id
  resource_id = aws_api_gateway_resource.users.id
  http_method = aws_api_gateway_method.users_options.http_method
  status_code = aws_api_gateway_method_response.users_options.status_code
  
  response_parameters = {
    "method.response.header.Access-Control-Allow-Headers" = "'Content-Type,X-Amz-Date,Authorization,X-Api-Key,X-Amz-Security-Token,X-Requested-With'",
    "method.response.header.Access-Control-Allow-Methods" = "'GET,POST,PUT,DELETE,OPTIONS,PATCH'",
    "method.response.header.Access-Control-Allow-Origin"  = "'*'",
    "method.response.header.Access-Control-Max-Age"       = "'7200'"
  }
  depends_on = [aws_api_gateway_method_response.users_options]
}

resource "aws_api_gateway_integration_response" "users_proxy_options" {
  rest_api_id = aws_api_gateway_rest_api.main.id
  resource_id = aws_api_gateway_resource.users_proxy.id
  http_method = aws_api_gateway_method.users_proxy_options.http_method
  status_code = aws_api_gateway_method_response.users_proxy_options.status_code
  
  response_parameters = {
    "method.response.header.Access-Control-Allow-Headers" = "'Content-Type,X-Amz-Date,Authorization,X-Api-Key,X-Amz-Security-Token,X-Requested-With'",
    "method.response.header.Access-Control-Allow-Methods" = "'GET,POST,PUT,DELETE,OPTIONS,PATCH'",
    "method.response.header.Access-Control-Allow-Origin"  = "'*'",
    "method.response.header.Access-Control-Max-Age"       = "'7200'"
  }
  depends_on = [aws_api_gateway_method_response.users_proxy_options]
}

resource "aws_api_gateway_integration_response" "products_options" {
  rest_api_id = aws_api_gateway_rest_api.main.id
  resource_id = aws_api_gateway_resource.products.id
  http_method = aws_api_gateway_method.products_options.http_method
  status_code = aws_api_gateway_method_response.products_options.status_code
  
  response_parameters = {
    "method.response.header.Access-Control-Allow-Headers" = "'Content-Type,X-Amz-Date,Authorization,X-Api-Key,X-Amz-Security-Token,X-Requested-With'",
    "method.response.header.Access-Control-Allow-Methods" = "'GET,POST,PUT,DELETE,OPTIONS,PATCH'",
    "method.response.header.Access-Control-Allow-Origin"  = "'*'",
    "method.response.header.Access-Control-Max-Age"       = "'7200'"
  }
  depends_on = [aws_api_gateway_method_response.products_options]
}

resource "aws_api_gateway_integration_response" "products_proxy_options" {
  rest_api_id = aws_api_gateway_rest_api.main.id
  resource_id = aws_api_gateway_resource.products_proxy.id
  http_method = aws_api_gateway_method.products_proxy_options.http_method
  status_code = aws_api_gateway_method_response.products_proxy_options.status_code
  
  response_parameters = {
    "method.response.header.Access-Control-Allow-Headers" = "'Content-Type,X-Amz-Date,Authorization,X-Api-Key,X-Amz-Security-Token,X-Requested-With'",
    "method.response.header.Access-Control-Allow-Methods" = "'GET,POST,PUT,DELETE,OPTIONS,PATCH'",
    "method.response.header.Access-Control-Allow-Origin"  = "'*'",
    "method.response.header.Access-Control-Max-Age"       = "'7200'"
  }
  depends_on = [aws_api_gateway_method_response.products_proxy_options]
}

# Despliegue de la API
resource "aws_api_gateway_deployment" "main" {
  depends_on = [
    aws_api_gateway_integration.users_root,
    aws_api_gateway_integration.users_subpath,
    aws_api_gateway_integration.products_root,
    aws_api_gateway_integration.products_subpath,
    aws_api_gateway_integration.users_options,
    aws_api_gateway_integration.users_proxy_options,
    aws_api_gateway_integration.products_options,
    aws_api_gateway_integration.products_proxy_options
  ]
  
  rest_api_id = aws_api_gateway_rest_api.main.id
  stage_name  = var.environment
  
  lifecycle {
    create_before_destroy = true
  }
  
  variables = {
    "deployed_at" = "${timestamp()}"
  }
}

# Gateway Response para manejo de errores y CORS
resource "aws_api_gateway_gateway_response" "default_4xx" {
  rest_api_id   = aws_api_gateway_rest_api.main.id
  response_type = "DEFAULT_4XX"
  
  response_templates = {
    "application/json" = "{\"message\":\"Error 4xx: Recurso no encontrado o no disponible\",\"error\":\"$context.error.message\"}"
  }
  
  response_parameters = {
    "gatewayresponse.header.Access-Control-Allow-Origin" = "'*'"
    "gatewayresponse.header.Access-Control-Allow-Headers" = "'Content-Type,X-Amz-Date,Authorization,X-Api-Key,X-Amz-Security-Token'"
    "gatewayresponse.header.Access-Control-Allow-Methods" = "'GET,POST,PUT,DELETE,OPTIONS'"
  }
}

resource "aws_api_gateway_gateway_response" "default_5xx" {
  rest_api_id   = aws_api_gateway_rest_api.main.id
  response_type = "DEFAULT_5XX"
  
  response_templates = {
    "application/json" = "{\"message\":\"Error 5xx: Error interno del servidor\",\"error\":\"$context.error.message\"}"
  }
  
  response_parameters = {
    "gatewayresponse.header.Access-Control-Allow-Origin" = "'*'"
    "gatewayresponse.header.Access-Control-Allow-Headers" = "'Content-Type,X-Amz-Date,Authorization,X-Api-Key,X-Amz-Security-Token'"
    "gatewayresponse.header.Access-Control-Allow-Methods" = "'GET,POST,PUT,DELETE,OPTIONS'"
  }
}