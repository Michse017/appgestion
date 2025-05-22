#!/bin/bash
# filepath: e:\BRNDLD\appgestion\infrastructure\deploy.sh
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

# Verificar que existen las imágenes Docker en DockerHub
echo -e "${YELLOW}Verificando imágenes Docker...${NC}"
DOCKERHUB_USER=$(grep dockerhub_username infrastructure/terraform/terraform.tfvars | cut -d '"' -f2)

if [ -z "$DOCKERHUB_USER" ]; then
  echo -e "${RED}Error: No se pudo obtener el usuario de DockerHub${NC}"
  exit 1
fi

# Verificar que las imágenes existen en DockerHub
echo -e "${YELLOW}Verificando disponibilidad de imágenes en DockerHub...${NC}"

check_image() {
  IMAGE_NAME="$1"
  HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" "https://hub.docker.com/v2/repositories/${DOCKERHUB_USER}/${IMAGE_NAME}/tags/latest")
  if [ "$HTTP_CODE" -eq 200 ]; then
    return 0
  else
    return 1
  fi
}

for image in "appgestion-user-service" "appgestion-product-service"; do
  if ! check_image "$image"; then
    echo -e "${RED}Error: No se encontró la imagen ${DOCKERHUB_USER}/${image}:latest en DockerHub${NC}"
    echo -e "${YELLOW}¿Olvidaste ejecutar primero ./infrastructure/build_images.sh?${NC}"
    exit 1
  fi
done

# Verificar que el build del frontend existe
if [ ! -d "frontend/build" ]; then
  echo -e "${RED}Error: No se encontró el directorio frontend/build${NC}"
  echo -e "${YELLOW}¿Olvidaste ejecutar primero ./infrastructure/build_images.sh?${NC}"
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

# CORREGIDO: Usar correctamente ssh_key_path en lugar de ssh_key_name.pem
if [ ! -f "infrastructure/terraform/templates/inventory.tmpl" ]; then
  echo -e "${YELLOW}Creando plantilla inventory.tmpl...${NC}"
  cat > infrastructure/terraform/templates/inventory.tmpl << 'EOF'
[backend]
${backend_ip} ansible_user=ubuntu ansible_ssh_private_key_file=${ssh_key_path}
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

# CORREGIDO: Validar y aplicar con mensaje de error más detallado
echo -e "${YELLOW}Validando configuración Terraform...${NC}"
terraform validate
if [ $? -ne 0 ]; then
  echo -e "${RED}Error: La validación de Terraform falló. Por favor, verifica la configuración.${NC}"
  exit 1
fi

echo -e "${YELLOW}Aplicando configuración Terraform...${NC}"
terraform apply -auto-approve

# 4. Obtener nombre del bucket S3 y subir frontend
echo -e "${YELLOW}Obteniendo información del bucket S3...${NC}"
# CORREGIDO: Utilizar nombre más genérico para intentar varios outputs posibles
S3_BUCKET=$(terraform output -raw frontend_bucket_name 2>/dev/null || 
           terraform output -raw s3_bucket_name 2>/dev/null ||
           terraform output -raw s3_bucket 2>/dev/null || echo "")

if [ -n "$S3_BUCKET" ]; then
  echo -e "${YELLOW}Subiendo frontend al bucket S3: ${S3_BUCKET}${NC}"
  cd "$PROJECT_ROOT"
  aws s3 sync ./frontend/build/ s3://${S3_BUCKET}/ --delete
  echo -e "${GREEN}Frontend desplegado en S3 exitosamente${NC}"
else
  echo -e "${YELLOW}No se pudo obtener el nombre del bucket S3, el frontend no se ha desplegado${NC}"
fi

# 5. Permitir que las instancias EC2 se inicien completamente
echo -e "${YELLOW}Esperando 60 segundos para permitir que las instancias EC2 se inicialicen...${NC}"
sleep 60

# 6. Ejecutar Ansible para configurar las instancias
echo -e "${GREEN}=== Configurando instancias con Ansible ===${NC}"
cd "$PROJECT_ROOT/infrastructure/ansible"

# Verificar qué tipo de inventario está disponible
if [ -f "inventory/hosts.ini" ]; then
  echo -e "${YELLOW}Usando inventario estático hosts.ini...${NC}"
  # AÑADIDO: Mostrar el contenido para verificar
  echo -e "${YELLOW}Contenido del inventario:${NC}"
  cat inventory/hosts.ini
  ansible-playbook -i inventory/hosts.ini playbook.yml
elif [ -f "inventory/aws_ec2.yml" ]; then
  echo -e "${YELLOW}Usando inventario dinámico aws_ec2.yml...${NC}"
  ansible-playbook -i inventory/aws_ec2.yml playbook.yml
else
  echo -e "${RED}Error: No se encontró ningún archivo de inventario${NC}"
  exit 1
fi

# 7. Invalidar caché de CloudFront para refrescar el frontend
echo -e "${YELLOW}Invalidando caché de CloudFront...${NC}"
cd "$PROJECT_ROOT/infrastructure/terraform"
# CORREGIDO: Probar varios nombres de output posibles
CF_DIST_ID=$(terraform output -raw cloudfront_distribution_id 2>/dev/null || 
            terraform output -raw cloudfront_id 2>/dev/null || echo "")

if [ -n "$CF_DIST_ID" ]; then
  aws cloudfront create-invalidation --distribution-id ${CF_DIST_ID} --paths "/*"
  echo -e "${GREEN}Caché de CloudFront invalidada exitosamente${NC}"
else
  echo -e "${YELLOW}No se pudo obtener el ID de distribución CloudFront${NC}"
fi

echo -e "${GREEN}=== Despliegue completado con éxito ===${NC}"

# 8. Verificar servicios desplegados
echo -e "${YELLOW}Verificando servicios desplegados...${NC}"

# CORREGIDO: Probar múltiples nombres de outputs para mayor compatibilidad
FRONTEND_URL=""
for output in frontend_cloudfront_domain cloudfront_domain_name frontend_url; do
  if terraform output -raw $output &>/dev/null; then
    FRONTEND_URL=$(terraform output -raw $output)
    break
  fi
done

if [ -n "$FRONTEND_URL" ]; then
  echo -e "Frontend: https://${FRONTEND_URL}"
else
  echo -e "${YELLOW}No se pudo obtener la URL del frontend${NC}"
fi

# CORREGIDO: Probar múltiples nombres de outputs para API Gateway
API_URL=""
for output in api_gateway_invoke_url api_url invoke_url; do
  if terraform output -raw $output &>/dev/null; then
    API_URL=$(terraform output -raw $output)
    break
  fi
done

if [ -n "$API_URL" ]; then
  echo -e "API: ${API_URL}"
  
  # MEJORADO: Verificar endpoints con información más detallada
  echo -e "${YELLOW}Verificando disponibilidad de endpoints...${NC}"
  
  # Verificar servicio de usuarios
  echo -e "Comprobando servicio de usuarios..."
  USERS_RESPONSE=$(curl -s -w "\n%{http_code}" "${API_URL}/users" 2>/dev/null)
  HTTP_CODE=$(echo "$USERS_RESPONSE" | tail -n1)
  if [ "$HTTP_CODE" -eq 200 ]; then
    echo -e "${GREEN}✅ Servicio de usuarios funcionando correctamente (HTTP 200)${NC}"
  else
    echo -e "${YELLOW}⚠️ Servicio de usuarios responde con código HTTP ${HTTP_CODE}${NC}"
  fi
  
  # Verificar servicio de productos
  echo -e "Comprobando servicio de productos..."
  PRODUCTS_RESPONSE=$(curl -s -w "\n%{http_code}" "${API_URL}/products" 2>/dev/null)
  HTTP_CODE=$(echo "$PRODUCTS_RESPONSE" | tail -n1)
  if [ "$HTTP_CODE" -eq 200 ]; then
    echo -e "${GREEN}✅ Servicio de productos funcionando correctamente (HTTP 200)${NC}"
  else
    echo -e "${YELLOW}⚠️ Servicio de productos responde con código HTTP ${HTTP_CODE}${NC}"
  fi
else
  echo -e "${YELLOW}No se pudo obtener la URL de la API${NC}"
fi

echo -e "${GREEN}=== El sistema AppGestion está listo para usar ===${NC}"
