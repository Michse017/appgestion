#!/bin/bash
# build_images.sh - Script para construir y publicar imágenes Docker

set -e

# Colores para mensajes
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
NC='\033[0m'

# Asegurar que estamos en el directorio raíz del proyecto
SCRIPT_DIR=$(dirname "$0")
cd "$SCRIPT_DIR/.." || exit 1
PROJECT_ROOT=$(pwd)

echo -e "${GREEN}=== Construyendo imágenes Docker para AppGestion ===${NC}"

# Verificar herramientas necesarias
for cmd in docker npm; do
  if ! command -v $cmd &> /dev/null; then
    echo -e "${RED}Error: $cmd no está instalado${NC}"
    exit 1
  fi
done

# Verificar estructura del proyecto
echo -e "${YELLOW}Verificando estructura del proyecto...${NC}"
for dir in "frontend" "user-service" "product-service" "nginx"; do
  if [ ! -d "$dir" ]; then
    echo -e "${RED}Error: El directorio '$dir' no existe${NC}"
    exit 1
  fi
done

# Verificar archivo de variables Terraform
if [ ! -f "infrastructure/terraform/terraform.tfvars" ]; then
  echo -e "${RED}Error: No se encontró el archivo terraform.tfvars${NC}"
  exit 1
fi

# Obtener credenciales Docker
DOCKERHUB_USER=$(grep dockerhub_username infrastructure/terraform/terraform.tfvars | cut -d '"' -f2)
DOCKERHUB_PASS=$(grep dockerhub_password infrastructure/terraform/terraform.tfvars | cut -d '"' -f2)

if [ -z "$DOCKERHUB_USER" ] || [ -z "$DOCKERHUB_PASS" ]; then
  echo -e "${RED}Error: No se pudieron obtener las credenciales de DockerHub${NC}"
  exit 1
fi

# Login en DockerHub
echo -e "${YELLOW}Iniciando sesión en DockerHub...${NC}"
echo "$DOCKERHUB_PASS" | docker login -u "$DOCKERHUB_USER" --password-stdin

# Construir frontend para producción
echo -e "${YELLOW}Construyendo frontend para producción...${NC}"
cd frontend

# Configurar variables de entorno para el build
API_URL="https://api-gateway-placeholder"
if [ -f "$PROJECT_ROOT/infrastructure/terraform/terraform.tfstate" ]; then
  TERRAFORM_API_URL=$(cd "$PROJECT_ROOT/infrastructure/terraform" && terraform output -raw api_gateway_invoke_url 2>/dev/null || echo "")
  if [ -n "$TERRAFORM_API_URL" ]; then
    API_URL="${TERRAFORM_API_URL%/}"
  fi
fi

cat > .env.production << EOF
REACT_APP_API_URL=${API_URL}
NODE_ENV=production
EOF

echo -e "${YELLOW}Configurando frontend con API URL: ${API_URL}${NC}"

# Instalar dependencias y construir
npm install --only=production
npm run build

# Verificar que el build se completó
if [ ! -f "build/index.html" ]; then
  echo -e "${RED}Error: No se pudo generar el build del frontend${NC}"
  exit 1
fi

cd ..

# Construir imágenes Docker
echo -e "${YELLOW}Construyendo imágenes Docker...${NC}"

# Imagen del servicio de usuarios
echo -e "${YELLOW}Construyendo imagen del servicio de usuarios...${NC}"
docker build -t "$DOCKERHUB_USER/appgestion-user-service:latest" ./user-service/

# Imagen del servicio de productos
echo -e "${YELLOW}Construyendo imagen del servicio de productos...${NC}"
docker build -t "$DOCKERHUB_USER/appgestion-product-service:latest" ./product-service/

# Imagen de nginx
echo -e "${YELLOW}Construyendo imagen de nginx...${NC}"
docker build -t "$DOCKERHUB_USER/appgestion-nginx:latest" ./nginx/

# Imagen del frontend (opcional para desarrollo)
echo -e "${YELLOW}Construyendo imagen del frontend...${NC}"
docker build -t "$DOCKERHUB_USER/appgestion-frontend:latest" ./frontend/

# Publicar imágenes
echo -e "${YELLOW}Publicando imágenes en DockerHub...${NC}"
docker push "$DOCKERHUB_USER/appgestion-user-service:latest"
docker push "$DOCKERHUB_USER/appgestion-product-service:latest"
docker push "$DOCKERHUB_USER/appgestion-nginx:latest"
docker push "$DOCKERHUB_USER/appgestion-frontend:latest"

echo -e "${GREEN}=== Imágenes construidas y publicadas exitosamente ===${NC}"
echo -e "${YELLOW}Frontend construido y listo para despliegue en S3${NC}"
echo -e "${YELLOW}Imágenes disponibles en: https://hub.docker.com/u/${DOCKERHUB_USER}${NC}"