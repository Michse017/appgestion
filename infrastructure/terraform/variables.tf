variable "aws_region" { default = "us-east-1" }
variable "key_name" {}
variable "db_user" {}
variable "db_password" {}
variable "ssh_private_key" {}
variable "ansible_user" { default = "ubuntu" }
variable "my_public_ip" {
  description = "Tu IP pública para acceso SSH"
}