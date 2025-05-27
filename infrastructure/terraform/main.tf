###############################################################################
# PROVIDER CONFIGURATION
###############################################################################
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

###############################################################################
# NETWORKING - VPC SIMPLIFICADA
###############################################################################
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

resource "aws_subnet" "private" {
  count             = length(var.availability_zones)
  vpc_id            = aws_vpc.main.id
  cidr_block        = var.private_subnet_cidrs[count.index]
  availability_zone = var.availability_zones[count.index]

  tags = {
    Name = "${var.project_name}-private-subnet-${count.index + 1}"
  }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = {
    Name = "${var.project_name}-public-route-table"
  }
}

resource "aws_route_table_association" "public" {
  count          = length(var.public_subnet_cidrs)
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

###############################################################################
# SECURITY GROUPS
###############################################################################
resource "aws_security_group" "alb" {
  name        = "${var.project_name}-alb-sg"
  description = "Security group for ALB"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "HTTP access from anywhere"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "Allow all outbound traffic"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.project_name}-alb-sg"
  }
}

resource "aws_security_group" "services" {
  name        = "${var.project_name}-services-sg"
  description = "Security group for services"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "SSH access"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.allowed_ssh_ip]
  }

  ingress {
    description     = "Service ports from ALB"
    from_port       = 3001
    to_port         = 3002
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }

  egress {
    description = "Allow all outbound traffic"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.project_name}-services-sg"
  }
}

resource "aws_security_group" "rds" {
  name        = "${var.project_name}-rds-sg"
  description = "Security group for RDS"
  vpc_id      = aws_vpc.main.id

  ingress {
    description     = "PostgreSQL from services"
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.services.id]
  }

  ingress {
    description = "PostgreSQL from developer"
    from_port   = 5432
    to_port     = 5432
    protocol    = "tcp"
    cidr_blocks = [var.allowed_ssh_ip]
  }

  egress {
    description = "Allow all outbound traffic"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.project_name}-rds-sg"
  }
}

###############################################################################
# BASE DE DATOS
###############################################################################
resource "aws_db_subnet_group" "main" {
  name       = "${var.project_name}-db-subnet"
  subnet_ids = aws_subnet.private[*].id

  tags = {
    Name = "${var.project_name}-db-subnet-group"
  }
}

resource "aws_db_instance" "user_db" {
  identifier             = "${var.project_name}-user-db"
  allocated_storage      = 10
  engine                 = "postgres"
  engine_version         = "13"
  instance_class         = var.db_instance_class
  db_name                = var.db_name_user
  username               = var.db_username
  password               = var.db_password
  parameter_group_name   = "default.postgres13"
  skip_final_snapshot    = true
  publicly_accessible    = true
  db_subnet_group_name   = aws_db_subnet_group.main.name
  vpc_security_group_ids = [aws_security_group.rds.id]
  apply_immediately            = true
  backup_retention_period      = 1
  deletion_protection          = false
  auto_minor_version_upgrade   = false
  performance_insights_enabled = false

  tags = {
    Name = "${var.project_name}-user-db"
  }
}

resource "aws_db_instance" "product_db" {
  identifier             = "${var.project_name}-product-db"
  allocated_storage      = 10
  engine                 = "postgres"
  engine_version         = "13"
  instance_class         = var.db_instance_class
  db_name                = var.db_name_product
  username               = var.db_username
  password               = var.db_password
  parameter_group_name   = "default.postgres13"
  skip_final_snapshot    = true
  publicly_accessible    = true
  db_subnet_group_name   = aws_db_subnet_group.main.name
  vpc_security_group_ids = [aws_security_group.rds.id]
  apply_immediately            = true
  backup_retention_period      = 1
  deletion_protection          = false
  auto_minor_version_upgrade   = false
  performance_insights_enabled = false

  tags = {
    Name = "${var.project_name}-product-db"
  }
}

###############################################################################
# INSTANCIAS EC2 SIMPLIFICADAS - CON PROVISIONERS
###############################################################################
data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

resource "aws_instance" "user_service" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = var.instance_type
  key_name               = var.ssh_key_name
  vpc_security_group_ids = [aws_security_group.services.id]
  subnet_id              = aws_subnet.public[0].id

  tags = {
    Name = "${var.project_name}-user-service"
  }

  depends_on = [aws_db_instance.user_db]

  provisioner "file" {
    source      = "${path.module}/../setup.sh"
    destination = "/home/ubuntu/setup.sh"
    connection {
      type        = "ssh"
      user        = "ubuntu"
      private_key = file(var.ssh_key_path)
      host        = self.public_ip
    }
  }

  provisioner "remote-exec" {
    inline = [
      "sudo bash /home/ubuntu/setup.sh user"
    ]
    connection {
      type        = "ssh"
      user        = "ubuntu"
      private_key = file(var.ssh_key_path)
      host        = self.public_ip
    }
  }
}

resource "aws_instance" "product_service" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = var.instance_type
  key_name               = var.ssh_key_name
  vpc_security_group_ids = [aws_security_group.services.id]
  subnet_id              = aws_subnet.public[0].id

  tags = {
    Name = "${var.project_name}-product-service"
  }

  depends_on = [aws_db_instance.product_db]

  provisioner "file" {
    source      = "${path.module}/../setup.sh"
    destination = "/home/ubuntu/setup.sh"
    connection {
      type        = "ssh"
      user        = "ubuntu"
      private_key = file(var.ssh_key_path)
      host        = self.public_ip
    }
  }

  provisioner "remote-exec" {
    inline = [
      "sudo bash /home/ubuntu/setup.sh product"
    ]
    connection {
      type        = "ssh"
      user        = "ubuntu"
      private_key = file(var.ssh_key_path)
      host        = self.public_ip
    }
  }
}

###############################################################################
# BALANCEADORES DE CARGA (ALB)
###############################################################################
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
  name                 = "${var.project_name}-user-tg"
  port                 = 3001
  protocol             = "HTTP"
  vpc_id               = aws_vpc.main.id
  deregistration_delay = 30

  health_check {
    path                = "/health"
    port                = "3001"
    interval            = 30
    timeout             = 10
    healthy_threshold   = 2
    unhealthy_threshold = 3
    matcher             = "200"
  }

  tags = {
    Name = "${var.project_name}-user-tg"
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
  name                 = "${var.project_name}-product-tg"
  port                 = 3002
  protocol             = "HTTP"
  vpc_id               = aws_vpc.main.id
  deregistration_delay = 30

  health_check {
    path                = "/health"
    port                = "3002"
    interval            = 30
    timeout             = 10
    healthy_threshold   = 2
    unhealthy_threshold = 3
    matcher             = "200"
  }

  tags = {
    Name = "${var.project_name}-product-tg"
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

###############################################################################
# FRONTEND - S3 + CLOUDFRONT
###############################################################################
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
        Effect    = "Allow"
        Principal = {
          AWS = aws_cloudfront_origin_access_identity.frontend.iam_arn
        }
        Action   = "s3:GetObject"
        Resource = "${aws_s3_bucket.frontend.arn}/*"
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

###############################################################################
# API GATEWAY (SIN VPC LINK)
###############################################################################
resource "aws_api_gateway_rest_api" "main" {
  name        = "${var.project_name}-api"
  description = "API para ${var.project_name}"

  endpoint_configuration {
    types = ["REGIONAL"]
  }
}

resource "aws_api_gateway_method" "root_any" {
  rest_api_id   = aws_api_gateway_rest_api.main.id
  resource_id   = aws_api_gateway_rest_api.main.root_resource_id
  http_method   = "ANY"
  authorization = "NONE"
}

resource "aws_api_gateway_integration" "root_any" {
  rest_api_id = aws_api_gateway_rest_api.main.id
  resource_id = aws_api_gateway_rest_api.main.root_resource_id
  http_method = aws_api_gateway_method.root_any.http_method

  type                    = "MOCK"
  integration_http_method = "ANY"
  uri                     = "http://mock.example"
}

###############################################################################
# SECCION USERS EN API GATEWAY
###############################################################################
resource "aws_api_gateway_resource" "users" {
  rest_api_id = aws_api_gateway_rest_api.main.id
  parent_id   = aws_api_gateway_rest_api.main.root_resource_id
  path_part   = "users"
}

resource "aws_api_gateway_method" "users_any" {
  rest_api_id   = aws_api_gateway_rest_api.main.id
  resource_id   = aws_api_gateway_resource.users.id
  http_method   = "ANY"
  authorization = "NONE"
}

resource "aws_api_gateway_integration" "users_any" {
  rest_api_id             = aws_api_gateway_rest_api.main.id
  resource_id             = aws_api_gateway_resource.users.id
  http_method             = aws_api_gateway_method.users_any.http_method
  type                    = "HTTP_PROXY"
  integration_http_method = "ANY"
  uri                     = "http://${aws_lb.user_service.dns_name}/users"
}

resource "aws_api_gateway_method" "users_options" {
  rest_api_id   = aws_api_gateway_rest_api.main.id
  resource_id   = aws_api_gateway_resource.users.id
  http_method   = "OPTIONS"
  authorization = "NONE"
}

resource "aws_api_gateway_method_response" "users_options_200" {
  rest_api_id = aws_api_gateway_rest_api.main.id
  resource_id = aws_api_gateway_resource.users.id
  http_method = aws_api_gateway_method.users_options.http_method
  status_code = "200"

  response_parameters = {
    "method.response.header.Access-Control-Allow-Headers" = true
    "method.response.header.Access-Control-Allow-Methods" = true
    "method.response.header.Access-Control-Allow-Origin"  = true
  }

  response_models = {
    "application/json" = "Empty"
  }
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

resource "aws_api_gateway_integration_response" "users_options" {
  rest_api_id = aws_api_gateway_rest_api.main.id
  resource_id = aws_api_gateway_resource.users.id
  http_method = aws_api_gateway_method.users_options.http_method
  status_code = aws_api_gateway_method_response.users_options_200.status_code

  response_parameters = {
    "method.response.header.Access-Control-Allow-Headers" = "'Content-Type,X-Amz-Date,Authorization,X-Api-Key,X-Amz-Security-Token'"
    "method.response.header.Access-Control-Allow-Methods" = "'GET,POST,PUT,DELETE,OPTIONS'"
    "method.response.header.Access-Control-Allow-Origin"  = "'*'"
  }
}

resource "aws_api_gateway_resource" "users_proxy" {
  rest_api_id = aws_api_gateway_rest_api.main.id
  parent_id   = aws_api_gateway_resource.users.id
  path_part   = "{proxy+}"
}

resource "aws_api_gateway_method" "users_proxy" {
  rest_api_id   = aws_api_gateway_rest_api.main.id
  resource_id   = aws_api_gateway_resource.users_proxy.id
  http_method   = "ANY"
  authorization = "NONE"

  request_parameters = {
    "method.request.path.proxy" = true
  }
}

resource "aws_api_gateway_integration" "users_proxy" {
  rest_api_id             = aws_api_gateway_rest_api.main.id
  resource_id             = aws_api_gateway_resource.users_proxy.id
  http_method             = aws_api_gateway_method.users_proxy.http_method
  type                    = "HTTP_PROXY"
  integration_http_method = "ANY"
  uri                     = "http://${aws_lb.user_service.dns_name}/users/{proxy}"
  request_parameters = {
    "integration.request.path.proxy" = "method.request.path.proxy"
  }
}

###############################################################################
# SECCION PRODUCTS EN API GATEWAY
###############################################################################
resource "aws_api_gateway_resource" "products" {
  rest_api_id = aws_api_gateway_rest_api.main.id
  parent_id   = aws_api_gateway_rest_api.main.root_resource_id
  path_part   = "products"
}

resource "aws_api_gateway_method" "products_any" {
  rest_api_id   = aws_api_gateway_rest_api.main.id
  resource_id   = aws_api_gateway_resource.products.id
  http_method   = "ANY"
  authorization = "NONE"
}

resource "aws_api_gateway_integration" "products_any" {
  rest_api_id             = aws_api_gateway_rest_api.main.id
  resource_id             = aws_api_gateway_resource.products.id
  http_method             = aws_api_gateway_method.products_any.http_method
  type                    = "HTTP_PROXY"
  integration_http_method = "ANY"
  uri                     = "http://${aws_lb.product_service.dns_name}/products"
}

resource "aws_api_gateway_method" "products_options" {
  rest_api_id   = aws_api_gateway_rest_api.main.id
  resource_id   = aws_api_gateway_resource.products.id
  http_method   = "OPTIONS"
  authorization = "NONE"
}

resource "aws_api_gateway_method_response" "products_options_200" {
  rest_api_id = aws_api_gateway_rest_api.main.id
  resource_id = aws_api_gateway_resource.products.id
  http_method = aws_api_gateway_method.products_options.http_method
  status_code = "200"

  response_parameters = {
    "method.response.header.Access-Control-Allow-Headers" = true
    "method.response.header.Access-Control-Allow-Methods" = true
    "method.response.header.Access-Control-Allow-Origin"  = true
  }

  response_models = {
    "application/json" = "Empty"
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

resource "aws_api_gateway_integration_response" "products_options" {
  rest_api_id = aws_api_gateway_rest_api.main.id
  resource_id = aws_api_gateway_resource.products.id
  http_method = aws_api_gateway_method.products_options.http_method
  status_code = aws_api_gateway_method_response.products_options_200.status_code

  response_parameters = {
    "method.response.header.Access-Control-Allow-Headers" = "'Content-Type,X-Amz-Date,Authorization,X-Api-Key,X-Amz-Security-Token'"
    "method.response.header.Access-Control-Allow-Methods" = "'GET,POST,PUT,DELETE,OPTIONS'"
    "method.response.header.Access-Control-Allow-Origin"  = "'*'"
  }
}

resource "aws_api_gateway_resource" "products_proxy" {
  rest_api_id = aws_api_gateway_rest_api.main.id
  parent_id   = aws_api_gateway_resource.products.id
  path_part   = "{proxy+}"
}

resource "aws_api_gateway_method" "products_proxy" {
  rest_api_id   = aws_api_gateway_rest_api.main.id
  resource_id   = aws_api_gateway_resource.products_proxy.id
  http_method   = "ANY"
  authorization = "NONE"

  request_parameters = {
    "method.request.path.proxy" = true
  }
}

resource "aws_api_gateway_integration" "products_proxy" {
  rest_api_id             = aws_api_gateway_rest_api.main.id
  resource_id             = aws_api_gateway_resource.products_proxy.id
  http_method             = aws_api_gateway_method.products_proxy.http_method
  type                    = "HTTP_PROXY"
  integration_http_method = "ANY"
  uri                     = "http://${aws_lb.product_service.dns_name}/products/{proxy}"
  request_parameters = {
    "integration.request.path.proxy" = "method.request.path.proxy"
  }
}

###############################################################################
# DEPLOYMENT
###############################################################################
resource "aws_api_gateway_deployment" "main" {
  depends_on = [
    aws_api_gateway_integration.root_any,
    aws_api_gateway_integration.users_any,
    aws_api_gateway_integration.products_any,
    aws_api_gateway_integration.users_proxy,
    aws_api_gateway_integration.products_proxy,
    aws_api_gateway_integration.users_options,
    aws_api_gateway_integration.products_options
  ]

  rest_api_id = aws_api_gateway_rest_api.main.id
  stage_name  = var.environment

  variables = {
    deployed_at = timestamp()
  }

  lifecycle {
    create_before_destroy = true
  }
}
