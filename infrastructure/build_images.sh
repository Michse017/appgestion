#!/bin/bash
# build_images.sh - Script mejorado para construir imágenes Docker

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
echo "$DOCKERHUB_PASS" | docker login -u "$DOCKERHUB_USER" --password-stdin || {
  echo -e "${RED}Error: No se pudo iniciar sesión en DockerHub${NC}"
  exit 1
}

# Construir frontend para producción
echo -e "${YELLOW}Construyendo frontend para producción...${NC}"
cd frontend

# Configurar variables de entorno para el build - Mejorado
API_URL="https://api-placeholder.example.com"
TERRAFORM_OUTPUT_FILE="$PROJECT_ROOT/infrastructure/terraform/terraform.tfstate"

# Intentar obtener API URL de Terraform si existe
if [ -f "$TERRAFORM_OUTPUT_FILE" ]; then
  echo -e "${YELLOW}Intentando obtener API URL del estado de Terraform...${NC}"
  if command -v terraform &> /dev/null; then
    cd "$PROJECT_ROOT/infrastructure/terraform"
    if terraform output -json 2>/dev/null | jq -e '.api_gateway_invoke_url.value' > /dev/null; then
      TERRAFORM_API_URL=$(terraform output -raw api_gateway_invoke_url 2>/dev/null)
      if [ -n "$TERRAFORM_API_URL" ]; then
        API_URL=$(echo "$TERRAFORM_API_URL" | sed 's/\/$//')
        echo -e "${GREEN}API URL obtenida de Terraform: ${API_URL}${NC}"
      fi
    fi
    cd "$PROJECT_ROOT/frontend"
  fi
fi

# Crear archivos de entorno con la API URL
cat > .env.production << EOF
REACT_APP_API_URL=${API_URL}
NODE_ENV=production
EOF

echo -e "${YELLOW}Configurando frontend con API URL: ${API_URL}${NC}"

# Instalar dependencias y construir con manejo de errores
echo -e "${YELLOW}Instalando dependencias del frontend...${NC}"
npm install || {
  echo -e "${RED}Error: No se pudieron instalar las dependencias del frontend${NC}"
  exit 1
}

echo -e "${YELLOW}Construyendo frontend...${NC}"
npm run build || {
  echo -e "${RED}Error: No se pudo construir el frontend${NC}"
  exit 1
}

# Verificar que el build se completó
if [ ! -f "build/index.html" ]; then
  echo -e "${RED}Error: No se pudo generar el build del frontend${NC}"
  exit 1
fi

cd "$PROJECT_ROOT"

# Construir imágenes Docker con mejor manejo de errores
echo -e "${GREEN}=== Construyendo imágenes Docker ===${NC}"

# Función para construir imágenes con manejo de errores
build_image() {
  SERVICE_NAME=$1
  DIR_NAME=$2

  echo -e "${YELLOW}Construyendo imagen ${SERVICE_NAME}...${NC}"
  docker build -t "${DOCKERHUB_USER}/${SERVICE_NAME}:latest" "./${DIR_NAME}/" || {
    echo -e "${RED}Error: No se pudo construir la imagen ${SERVICE_NAME}${NC}"
    return 1
  }
  echo -e "${GREEN}✅ Imagen ${SERVICE_NAME} construida correctamente${NC}"
  return 0
}

# Construir todas las imágenes
build_image "appgestion-user-service" "user-service" && \
build_image "appgestion-product-service" "product-service" && \
build_image "appgestion-nginx" "nginx" && \
build_image "appgestion-frontend" "frontend" || exit 1

# Publicar imágenes
echo -e "${YELLOW}Publicando imágenes en DockerHub...${NC}"
for image in "appgestion-user-service" "appgestion-product-service" "appgestion-nginx" "appgestion-frontend"; do
  echo -e "${YELLOW}Publicando ${image}...${NC}"
  docker push "${DOCKERHUB_USER}/${image}:latest" || {
    echo -e "${RED}Error: No se pudo publicar la imagen ${image}${NC}"
    exit 1
  }
  echo -e "${GREEN}✅ Imagen ${image} publicada correctamente${NC}"
done

echo -e "${GREEN}=== Imágenes construidas y publicadas exitosamente ===${NC}"
echo -e "${YELLOW}Frontend construido y listo para despliegue en S3${NC}"
echo -e "${YELLOW}Imágenes disponibles en: https://hub.docker.com/u/${DOCKERHUB_USER}${NC}"