# ======================================================
# VARIABLES BÁSICAS
# ======================================================

variable "aws_region" {
  description = "Región de AWS donde se desplegará la infraestructura"
  type        = string
  default     = "us-east-1"
}

variable "project_name" {
  description = "Nombre del proyecto, usado para etiquetar recursos"
  type        = string
  default     = "appgestion"
}

variable "environment" {
  description = "Entorno de despliegue (dev, staging, prod)"
  type        = string
  default     = "prod"
}

# ======================================================
# NETWORKING
# ======================================================

variable "vpc_cidr" {
  description = "CIDR block para la VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "public_subnet_cidrs" {
  description = "CIDR blocks para subnets públicas"
  type        = list(string)
  default     = ["10.0.1.0/24", "10.0.2.0/24"]
}

variable "private_subnet_cidrs" {
  description = "CIDR blocks para subnets privadas"
  type        = list(string)
  default     = ["10.0.3.0/24", "10.0.4.0/24"]
}

variable "availability_zones" {
  description = "Zonas de disponibilidad para las subnets"
  type        = list(string)
  default     = ["us-east-1a", "us-east-1b"]
}

# ======================================================
# INSTANCIAS EC2
# ======================================================

variable "instance_type" {
  description = "Tipo de instancia EC2"
  type        = string
  default     = "t3.micro"
}

variable "ec2_ami" {
  description = "AMI para las instancias EC2"
  type        = string
  default     = "ami-0c02fb55956c7d316" # Ubuntu 22.04 LTS
}

variable "ssh_key_name" {
  description = "Nombre del key pair para acceso SSH"
  type        = string
}

variable "ssh_key_path" {
  description = "Ruta completa al archivo de clave SSH privada"
  type        = string
}

# ======================================================
# BASES DE DATOS
# ======================================================

variable "db_instance_class" {
  description = "Clase de instancia para RDS"
  type        = string
  default     = "db.t3.micro"
}

variable "db_username" {
  description = "Usuario administrador de la base de datos"
  type        = string
  default     = "dbadmin"
}

variable "db_password" {
  description = "Contraseña del usuario administrador"
  type        = string
  sensitive   = true
}

variable "db_name_user" {
  description = "Nombre de la base de datos para servicio de usuarios"
  type        = string
  default     = "user_db"
}

variable "db_name_product" {
  description = "Nombre de la base de datos para servicio de productos"
  type        = string
  default     = "product_db"
}

# ======================================================
# FRONTEND Y CDN
# ======================================================

variable "domain_name" {
  description = "Nombre de dominio principal para la aplicación"
  type        = string
}

variable "frontend_bucket_name" {
  description = "Nombre del bucket S3 para el frontend"
  type        = string
  default     = null
}

# ======================================================
# DOCKER Y DESPLIEGUE
# ======================================================

variable "dockerhub_username" {
  description = "Usuario de DockerHub para obtener imágenes"
  type        = string
}

variable "dockerhub_password" {
  description = "Contraseña de DockerHub"
  type        = string
  sensitive   = true
}