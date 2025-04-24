provider "aws" {
  region = var.aws_region
}

data "aws_vpc" "default" {
  default = true
}

resource "aws_security_group" "ssh_access" {
  name        = "allow_ssh"
  description = "Allow SSH inbound traffic"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["${var.my_public_ip}/32"]
  }

  ingress {
    description = "App"
    from_port   = 3001
    to_port     = 3002
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"]
  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-focal-20.04-amd64-server-*"]
  }
}

resource "aws_instance" "user_service" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = "t3.micro"
  count                  = 1
  key_name               = var.key_name
  vpc_security_group_ids = [aws_security_group.ssh_access.id]
  tags = { Name = "user-service-${count.index}" }
}

resource "aws_instance" "product_service" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = "t3.micro"
  count                  = 1
  key_name               = var.key_name
  vpc_security_group_ids = [aws_security_group.ssh_access.id]
  tags = { Name = "product-service-${count.index}" }
}

resource "aws_db_instance" "user_db" {
  identifier              = "user-db"
  engine                  = "postgres"
  instance_class          = "db.t3.micro"
  allocated_storage       = 20
  db_name                 = "user_db"
  username                = var.db_user
  password                = var.db_password
  skip_final_snapshot     = true
  publicly_accessible     = true
}

resource "aws_db_instance" "product_db" {
  identifier              = "product-db"
  engine                  = "postgres"
  instance_class          = "db.t3.micro"
  allocated_storage       = 20
  db_name                 = "product_db"
  username                = var.db_user
  password                = var.db_password
  skip_final_snapshot     = true
  publicly_accessible     = true
}

output "user_service_ips" {
  value = aws_instance.user_service[*].public_ip
}
output "product_service_ips" {
  value = aws_instance.product_service[*].public_ip
}
output "user_db_endpoint" {
  value = aws_db_instance.user_db.endpoint
}
output "product_db_endpoint" {
  value = aws_db_instance.product_db.endpoint
}

resource "local_file" "ansible_inventory" {
  content = <<EOF
[user_service]
%{ for ip in aws_instance.user_service[*].public_ip ~}
${ip}
%{ endfor ~}

[product_service]
%{ for ip in aws_instance.product_service[*].public_ip ~}
${ip}
%{ endfor ~}
EOF
  filename = "${path.module}/../ansible/inventory"
}

resource "null_resource" "ansible_provision" {
  depends_on = [
    local_file.ansible_inventory,
    aws_instance.user_service,
    aws_instance.product_service,
    aws_db_instance.user_db,
    aws_db_instance.product_db
  ]
  provisioner "local-exec" {
    command = <<EOT
      ANSIBLE_HOST_KEY_CHECKING=False \
      ansible-playbook -i ../ansible/inventory \
      -u ${var.ansible_user} --private-key ${var.ssh_private_key} \
      ../ansible/playbook.yml \
      --extra-vars "user_db_endpoint=${aws_db_instance.user_db.endpoint} product_db_endpoint=${aws_db_instance.product_db.endpoint} db_user=${var.db_user} db_password=${var.db_password}"
    EOT
  }
}