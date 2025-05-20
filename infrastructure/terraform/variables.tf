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
  description = "Lista de zonas de disponibilidad"
  type        = list(string)
  default     = ["us-east-1a", "us-east-1b"]
}

# ======================================================
# COMPUTE - EC2
# ======================================================

variable "ssh_key_name" {
  description = "Nombre de la clave SSH para acceder a instancias EC2"
  type        = string
}

variable "instance_type" {
  description = "Tipo de instancia EC2 para los servidores"
  type        = string
  default     = "t3.small"
}

variable "ec2_ami" {
  description = "AMI ID para instancias EC2"
  type        = string
  default     = "ami-0c55b159cbfafe1f0" # Ubuntu 20.04 LTS
}

# ======================================================
# BASES DE DATOS
# ======================================================

variable "db_instance_class" {
  description = "Tipo de instancia para bases de datos RDS"
  type        = string
  default     = "db.t3.micro"
}

variable "db_username" {
  description = "Nombre de usuario principal para bases de datos"
  type        = string
  sensitive   = true
}

variable "db_password" {
  description = "Contraseña para bases de datos"
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
  default     = null # Se genera automáticamente si es null
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