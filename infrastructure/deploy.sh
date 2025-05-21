#!/bin/bash
# deploy.sh - Script para desplegar la infraestructura en AWS

set -e  # Detener en caso de error

# Colores para mensajes
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
NC='\033[0m'

# Asegurar que estamos en el directorio raíz del proyecto
SCRIPT_DIR=$(dirname "$0")
cd "$SCRIPT_DIR/.." || exit 1
PROJECT_ROOT=$(pwd)

echo -e "${GREEN}=== Desplegando infraestructura AppGestion en AWS desde ${PROJECT_ROOT} ===${NC}"

# Verificar estructura del proyecto
echo -e "${YELLOW}Verificando estructura del proyecto...${NC}"
for dir in "infrastructure/terraform" "infrastructure/ansible"; do
  if [ ! -d "$dir" ]; then
    echo -e "${RED}Error: El directorio '$dir' no existe${NC}"
    exit 1
  fi
done

# Verificar archivo de variables Terraform
if [ ! -f "infrastructure/terraform/terraform.tfvars" ]; then
  echo -e "${RED}Error: No se encontró el archivo terraform.tfvars${NC}"
  echo -e "${YELLOW}Por favor, crea el archivo siguiendo el ejemplo terraform.tfvars.example${NC}"
  exit 1
fi

# Verificar que existen las imágenes Docker
echo -e "${YELLOW}Verificando imágenes Docker...${NC}"
DOCKERHUB_USER=$(grep dockerhub_username infrastructure/terraform/terraform.tfvars | cut -d '"' -f2)

if [ -z "$DOCKERHUB_USER" ]; then
  echo -e "${RED}Error: No se pudo obtener el usuario de DockerHub${NC}"
  exit 1
fi

# 1. Crear los directorios de Ansible si no existen
echo -e "${YELLOW}Preparando directorios de Ansible...${NC}"
mkdir -p infrastructure/ansible/inventory
mkdir -p infrastructure/ansible/group_vars
mkdir -p infrastructure/ansible/roles/appgestion/tasks
mkdir -p infrastructure/ansible/roles/appgestion/templates

# 2. Crear las plantillas de Terraform si no existen
echo -e "${YELLOW}Verificando plantillas de Terraform...${NC}"
mkdir -p infrastructure/terraform/templates

if [ ! -f "infrastructure/terraform/templates/inventory.tmpl" ]; then
  echo -e "${YELLOW}Creando plantilla inventory.tmpl...${NC}"
  cat > infrastructure/terraform/templates/inventory.tmpl << 'EOF'
[backend]
backend ansible_host=${backend_ip} ansible_user=ubuntu ansible_ssh_private_key_file=~/.ssh/${ssh_key_name}.pem
EOF
fi

if [ ! -f "infrastructure/terraform/templates/vars.tmpl" ]; then
  echo -e "${YELLOW}Creando plantilla vars.tmpl...${NC}"
  cat > infrastructure/terraform/templates/vars.tmpl << 'EOF'
---
project_name: "${project_name}"
environment: "${environment}"
region: "${region}"
db_secret_name: "${db_secret_name}"
docker_secret_name: "${docker_secret_name}"
s3_bucket: "${s3_bucket}"
cloudfront_url: "${cloudfront_url}"
api_endpoint: "${api_endpoint}"
EOF
fi

# 3. Desplegar infraestructura con Terraform
echo -e "${GREEN}=== Desplegando infraestructura con Terraform ===${NC}"
cd infrastructure/terraform
terraform init
terraform validate
if [ $? -ne 0 ]; then
  echo -e "${RED}Error: La validación de Terraform falló${NC}"
  exit 1
fi

terraform apply -auto-approve

# 4. Permitir que las instancias EC2 se inicien completamente
echo -e "${YELLOW}Esperando 60 segundos para permitir que las instancias EC2 se inicialicen...${NC}"
sleep 60

# 5. Ejecutar Ansible para configurar las instancias
echo -e "${GREEN}=== Configurando instancias con Ansible ===${NC}"
cd ../ansible

# Verificar qué tipo de inventario está disponible
if [ -f "inventory/hosts.ini" ]; then
  echo -e "${YELLOW}Usando inventario estático hosts.ini...${NC}"
  ansible-playbook -i inventory/hosts.ini playbook.yml
elif [ -f "inventory/aws_ec2.yml" ]; then
  echo -e "${YELLOW}Usando inventario dinámico aws_ec2.yml...${NC}"
  ansible-playbook -i inventory/aws_ec2.yml playbook.yml
else
  echo -e "${RED}Error: No se encontró ningún archivo de inventario${NC}"
  exit 1
fi

echo -e "${GREEN}=== Despliegue completado con éxito ===${NC}"

# Mostrar información de acceso usando los nombres correctos de outputs
cd ../terraform
if terraform output -raw frontend_cloudfront_domain &>/dev/null; then
  echo -e "Frontend: https://$(terraform output -raw frontend_cloudfront_domain)"
elif terraform output -raw frontend_url &>/dev/null; then
  echo -e "Frontend: $(terraform output -raw frontend_url)"
else
  echo -e "${YELLOW}No se pudo obtener la URL del frontend${NC}"
fi

if terraform output -raw api_gateway_invoke_url &>/dev/null; then
  echo -e "API: $(terraform output -raw api_gateway_invoke_url)"
else
  echo -e "${YELLOW}No se pudo obtener la URL de la API${NC}"
fi