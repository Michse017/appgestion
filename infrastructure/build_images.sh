#!/bin/bash
# build_images.sh - Script para construir y publicar imágenes Docker

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

echo -e "${GREEN}=== Preparando imágenes Docker para AppGestion desde ${PROJECT_ROOT} ===${NC}"

if ! command -v npm &> /dev/null; then
  echo -e "${RED}Error: npm no está instalado${NC}"
  exit 1
fi

# Verificar estructura del proyecto (corregida)
echo -e "${YELLOW}Verificando estructura del proyecto...${NC}"
for dir in "frontend" "user-service" "product-service"; do
  if [ ! -d "$dir" ]; then
    echo -e "${RED}Error: El directorio '$dir' no existe${NC}"
    exit 1
  fi
done

# Verificar archivo de variables Terraform para credenciales
if [ ! -f "infrastructure/terraform/terraform.tfvars" ]; then
  echo -e "${RED}Error: No se encontró el archivo terraform.tfvars${NC}"
  echo -e "${YELLOW}Por favor, crea el archivo siguiendo el ejemplo terraform.tfvars.example${NC}"
  exit 1
fi

# Construir y publicar imágenes Docker
echo -e "${GREEN}=== Construyendo y publicando imágenes Docker ===${NC}"

# Obtener credenciales desde archivo de variables
DOCKERHUB_USER=$(grep dockerhub_username infrastructure/terraform/terraform.tfvars | cut -d '"' -f2)
DOCKERHUB_PASS=$(grep dockerhub_password infrastructure/terraform/terraform.tfvars | cut -d '"' -f2)

if [ -z "$DOCKERHUB_USER" ] || [ -z "$DOCKERHUB_PASS" ]; then
  echo -e "${RED}Error: No se pudieron obtener las credenciales de DockerHub${NC}"
  exit 1
fi

# Login en DockerHub
echo -e "${YELLOW}Iniciando sesión en DockerHub...${NC}"
echo "$DOCKERHUB_PASS" | docker login -u "$DOCKERHUB_USER" --password-stdin

# Preparar frontend para producción
echo -e "${YELLOW}Construyendo frontend para producción...${NC}"
cd frontend
echo "REACT_APP_API_URL=" > .env.production  # URL vacía para usar rutas relativas con API Gateway
npm install
npm run build
cd ..

# Construir imágenes (rutas corregidas)
echo -e "${YELLOW}Construyendo imágenes Docker para servicios backend...${NC}"
docker build -t "$DOCKERHUB_USER/appgestion-user-service:latest" ./user-service/
docker build -t "$DOCKERHUB_USER/appgestion-product-service:latest" ./product-service/

# No necesitamos la imagen del frontend para producción, ya que se desplegará en S3
# pero aún así la construimos por si se necesita para desarrollo/pruebas
docker build -t "$DOCKERHUB_USER/appgestion-frontend:latest" ./frontend/

# Publicar imágenes
echo -e "${YELLOW}Publicando imágenes en DockerHub...${NC}"
docker push "$DOCKERHUB_USER/appgestion-user-service:latest"
docker push "$DOCKERHUB_USER/appgestion-product-service:latest"
docker push "$DOCKERHUB_USER/appgestion-frontend:latest"

echo -e "${GREEN}=== Imágenes Docker construidas y publicadas con éxito ===${NC}"
echo -e "${YELLOW}Frontend construido y listo para despliegue en S3${NC}"
echo -e "${YELLOW}Puedes verificar las imágenes en: https://hub.docker.com/u/${DOCKERHUB_USER}${NC}"