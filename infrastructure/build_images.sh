#!/bin/bash
# build_images.sh - Script optimizado para construir imágenes Docker

set -e

# Colores para mensajes
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
NC='\033[0m'

# Directorio raíz del proyecto
SCRIPT_DIR=$(dirname "$0")
cd "$SCRIPT_DIR/.." || exit 1
PROJECT_ROOT=$(pwd)

# Detectar IP pública para registro
export MY_PUBLIC_IP=$(curl -s https://api.ipify.org)
echo -e "${YELLOW}IP pública detectada: ${MY_PUBLIC_IP}${NC}"

echo -e "${GREEN}=== Construyendo imágenes Docker para AppGestion ===${NC}"

# Verificar herramientas necesarias
for cmd in docker npm; do
  if ! command -v $cmd &> /dev/null; then
    echo -e "${RED}Error: $cmd no está instalado${NC}"
    exit 1
  fi
done

# Verificar estructura del proyecto
for dir in "frontend" "user-service" "product-service"; do
  if [ ! -d "$dir" ]; then
    echo -e "${RED}Error: El directorio '$dir' no existe${NC}"
    exit 1
  fi
done

# Obtener credenciales de Docker Hub
if [ ! -f "infrastructure/terraform/terraform.tfvars" ]; then
  echo -e "${RED}Error: No se encontró el archivo terraform.tfvars${NC}"
  exit 1
fi

DOCKERHUB_USER=$(grep dockerhub_username infrastructure/terraform/terraform.tfvars | cut -d '"' -f2)
DOCKERHUB_PASS=$(grep dockerhub_password infrastructure/terraform/terraform.tfvars | cut -d '"' -f2)

if [ -z "$DOCKERHUB_USER" ] || [ -z "$DOCKERHUB_PASS" ]; then
  echo -e "${RED}Error: No se pudieron obtener las credenciales de Docker Hub${NC}"
  exit 1
fi

# Login en Docker Hub
echo -e "${YELLOW}Iniciando sesión en Docker Hub...${NC}"
echo "$DOCKERHUB_PASS" | docker login -u "$DOCKERHUB_USER" --password-stdin || {
  echo -e "${RED}Error: No se pudo iniciar sesión en Docker Hub${NC}"
  exit 1
}

# Construir frontend
echo -e "${GREEN}=== Construyendo frontend ===${NC}"
cd "$PROJECT_ROOT/frontend"

# Configurar variables de entorno para producción
echo -e "${YELLOW}Se actualizará la URL de la API durante el despliegue...${NC}"
cat > .env << EOF
REACT_APP_API_URL=http://localhost:8080
NODE_ENV=development
EOF

# Instalar dependencias y construir
echo -e "${YELLOW}Instalando dependencias del frontend...${NC}"
npm install || {
  echo -e "${RED}Error: No se pudieron instalar las dependencias${NC}"
  exit 1
}

echo -e "${YELLOW}Construyendo frontend...${NC}"
npm run build || {
  echo -e "${RED}Error: No se pudo construir el frontend${NC}"
  exit 1
}

# Verificar construcción
if [ ! -f "build/index.html" ]; then
  echo -e "${RED}Error: No se encontró el archivo build/index.html${NC}"
  exit 1
fi

echo -e "${GREEN}✅ Frontend construido correctamente${NC}"

# Construir imágenes de los servicios
cd "$PROJECT_ROOT"

for service in "user-service" "product-service"; do
  echo -e "${GREEN}=== Construyendo imagen para ${service} ===${NC}"
  
  docker build -t "${DOCKERHUB_USER}/appgestion-${service}:latest" "./${service}/" || {
    echo -e "${RED}Error: No se pudo construir la imagen para ${service}${NC}"
    exit 1
  }
  
  echo -e "${YELLOW}Publicando imagen ${service}...${NC}"
  docker push "${DOCKERHUB_USER}/appgestion-${service}:latest" || {
    echo -e "${RED}Error: No se pudo publicar la imagen para ${service}${NC}"
    exit 1
  }
  
  echo -e "${GREEN}✅ Imagen para ${service} construida y publicada correctamente${NC}"
done

echo -e "${GREEN}=== Todas las imágenes han sido construidas y publicadas correctamente ===${NC}"
echo -e "${YELLOW}Frontend preparado para despliegue en S3${NC}"
echo -e "${YELLOW}Imágenes disponibles en: https://hub.docker.com/u/${DOCKERHUB_USER}${NC}"