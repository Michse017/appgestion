#!/bin/bash
# deploy.sh - Script para despliegue completo de AppGestion

set -e  # Detener en caso de error

# Colores para mensajes
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${GREEN}=== Iniciando despliegue de AppGestion ===${NC}"

# 1. Construir y publicar imágenes Docker
echo -e "${GREEN}=== Construyendo y publicando imágenes Docker ===${NC}"

# Obtener credenciales desde archivo de variables
DOCKERHUB_USER=$(grep dockerhub_username infrastructure/terraform/terraform.tfvars | cut -d '"' -f2)
DOCKERHUB_PASS=$(grep dockerhub_password infrastructure/terraform/terraform.tfvars | cut -d '"' -f2)

# Login en DockerHub
echo "$DOCKERHUB_PASS" | docker login -u "$DOCKERHUB_USER" --password-stdin

# Construir y publicar imágenes
docker build -t $DOCKERHUB_USER/appgestion-user-service:latest ./user-service/
docker build -t $DOCKERHUB_USER/appgestion-product-service:latest ./product-service/
docker build -t $DOCKERHUB_USER/appgestion-frontend:latest ./frontend/

docker push $DOCKERHUB_USER/appgestion-user-service:latest
docker push $DOCKERHUB_USER/appgestion-product-service:latest
docker push $DOCKERHUB_USER/appgestion-frontend:latest

# 2. Desplegar infraestructura con Terraform
echo -e "${GREEN}=== Desplegando infraestructura con Terraform ===${NC}"
cd infrastructure/terraform
terraform init
terraform apply -auto-approve

# 3. Permitir que las instancias EC2 se inicien completamente
echo "Esperando 60 segundos para permitir que las instancias EC2 se inicialicen..."
sleep 60

# 4. Ejecutar Ansible para configurar las instancias
echo -e "${GREEN}=== Configurando instancias con Ansible ===${NC}"
cd ../ansible
ansible-playbook -i inventory/aws_ec2.yml playbook.yml

echo -e "${GREEN}=== Despliegue completado con éxito ===${NC}"
echo "Frontend: https://$(cd ../terraform && terraform output -raw frontend_domain)"
echo "API: $(cd ../terraform && terraform output -raw api_gateway_invoke_url)"