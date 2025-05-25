# VARIABLES BÁSICAS
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

# NETWORKING
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
  description = "Zonas de disponibilidad para los subnets"
  type        = list(string)
  default     = ["us-east-1a", "us-east-1b"]
}

# INSTANCIA Y BD
variable "instance_type" {
  description = "Tipo de instancia EC2"
  type        = string
  default     = "t3.micro"
}

variable "ec2_ami" {
  description = "AMI a usar para instancias EC2"
  type        = string
  default     = "ami-0c55b159cbfafe1f0" # Ubuntu 20.04 LTS
}

variable "db_instance_class" {
  description = "Clase de instancia para RDS"
  type        = string
  default     = "db.t3.micro"
}

# ACCESO Y SEGURIDAD
variable "ssh_key_path" {
  description = "Ruta al archivo de la clave SSH privada"
  type        = string
}

variable "ssh_key_name" {
  description = "Nombre de la clave SSH en AWS"
  type        = string
}

variable "allowed_ssh_ip" {
  description = "IP permitida para acceso SSH"
  type        = string
  default     = "0.0.0.0/0"
}

# CREDENCIALES
variable "db_username" {
  description = "Nombre de usuario para PostgreSQL"
  type        = string
}

variable "db_password" {
  description = "Contraseña para PostgreSQL"
  type        = string
  sensitive   = true
}

variable "db_name_user" {
  description = "Nombre de la base de datos para el servicio de usuarios"
  type        = string
  default     = "user_db"
}

variable "db_name_product" {
  description = "Nombre de la base de datos para el servicio de productos"
  type        = string
  default     = "product_db"
}

# DOCKER Y FRONTEND
variable "domain_name" {
  description = "Nombre de dominio principal"
  type        = string
}

variable "dockerhub_username" {
  description = "Usuario de DockerHub"
  type        = string
}

variable "dockerhub_password" {
  description = "Contraseña/token de DockerHub"
  type        = string
  sensitive   = true
}