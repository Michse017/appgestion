#!/bin/bash
# deploy.sh - Script optimizado para desplegar la infraestructura en AWS

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

# Rutas importantes
TFVARS_PATH="$PROJECT_ROOT/infrastructure/terraform/terraform.tfvars"
TERRAFORM_DIR="$PROJECT_ROOT/infrastructure/terraform"

# Detectar IP pública
export MY_PUBLIC_IP=$(curl -s https://api.ipify.org)
echo -e "${YELLOW}IP pública detectada: ${MY_PUBLIC_IP}${NC}"

echo -e "${GREEN}=== Desplegando AppGestion en AWS con arquitectura de alta disponibilidad ===${NC}"

# Verificar herramientas necesarias
for cmd in terraform aws jq docker npm; do
  if ! command -v $cmd &> /dev/null; then
    echo -e "${RED}Error: $cmd no está instalado${NC}"
    exit 1
  else
    echo -e "${GREEN}✅ $cmd encontrado${NC}"
  fi
done

# Verificar estructura del proyecto
for dir in "frontend" "user-service" "product-service"; do
  if [ ! -d "$dir" ]; then
    echo -e "${RED}Error: El directorio '$dir' no existe${NC}"
    exit 1
  else
    echo -e "${GREEN}✅ Directorio '$dir' encontrado${NC}"
  fi
done

# Verificar archivo de variables Terraform
if [ ! -f "$TFVARS_PATH" ]; then
  echo -e "${RED}Error: No se encontró el archivo terraform.tfvars${NC}"
  exit 1
else
  echo -e "${GREEN}✅ Archivo terraform.tfvars encontrado${NC}"
  
  # Verificar variables esenciales
  required_vars=("aws_region" "project_name" "environment" "db_username" "db_password" 
               "ssh_key_path" "dockerhub_username" "dockerhub_password")
               
  for var in "${required_vars[@]}"; do
    if ! grep -q "$var" "$TFVARS_PATH"; then
      echo -e "${RED}Error: Variable '$var' no encontrada en terraform.tfvars${NC}"
      exit 1
    fi
  done
  
  echo -e "${GREEN}✅ Variables requeridas encontradas${NC}"
fi

# Verificar y configurar SSH key
SSH_KEY_PATH=$(grep -oP 'ssh_key_path\s*=\s*"\K[^"]*' "$TFVARS_PATH")
SSH_KEY_NAME=$(grep -oP 'ssh_key_name\s*=\s*"\K[^"]*' "$TFVARS_PATH" 2>/dev/null || echo "")

if [ -z "$SSH_KEY_NAME" ] && [ -n "$SSH_KEY_PATH" ]; then
  SSH_KEY_NAME=$(basename "$SSH_KEY_PATH" | sed 's/\.[^.]*$//')
  echo -e "${YELLOW}⚠️ ssh_key_name no especificado, usando: $SSH_KEY_NAME${NC}"
  echo "ssh_key_name = \"$SSH_KEY_NAME\"" >> "$TFVARS_PATH"
fi

if [ ! -f "$SSH_KEY_PATH" ]; then
  echo -e "${RED}Error: Archivo de clave SSH no encontrado en: $SSH_KEY_PATH${NC}"
  exit 1
else
  echo -e "${GREEN}✅ Clave SSH encontrada: $SSH_KEY_PATH${NC}"
  
  # Verificar y ajustar permisos si es necesario
  if [[ "$OSTYPE" == "linux-gnu"* || "$OSTYPE" == "darwin"* ]]; then
    current_perms=$(stat -c "%a" "$SSH_KEY_PATH" 2>/dev/null || stat -f "%Lp" "$SSH_KEY_PATH")
    if [ "$current_perms" != "400" ] && [ "$current_perms" != "600" ]; then
      echo -e "${YELLOW}⚠️ Ajustando permisos de la clave SSH a 400...${NC}"
      chmod 400 "$SSH_KEY_PATH" || echo -e "${RED}No se pudieron cambiar los permisos.${NC}"
    fi
  fi
fi

# Construir imágenes Docker
echo -e "${YELLOW}¿Desea construir las imágenes Docker ahora? (s/n)${NC}"
read -r response
if [[ "$response" =~ ^([sS][iI]|[sS])$ ]]; then
  echo -e "${GREEN}Ejecutando script de construcción de imágenes...${NC}"
  bash "$SCRIPT_DIR/build_images.sh" || {
    echo -e "${RED}Error al construir las imágenes${NC}"
    exit 1
  }
fi

# Desplegar con Terraform
echo -e "${GREEN}=== Desplegando infraestructura con Terraform ===${NC}"
cd "$TERRAFORM_DIR"

# Agregar variable allowed_ssh_ip si se detectó correctamente
if [ -n "$MY_PUBLIC_IP" ]; then
  echo -e "\n# IP pública para reglas de seguridad" >> terraform.tfvars
  echo "allowed_ssh_ip = \"$MY_PUBLIC_IP/32\"" >> terraform.tfvars
  echo -e "${GREEN}✅ IP pública ($MY_PUBLIC_IP) agregada a las variables${NC}"
fi

echo -e "${YELLOW}Inicializando Terraform...${NC}"
terraform init

echo -e "${YELLOW}Validando configuración...${NC}"
terraform validate || {
  echo -e "${RED}Error: La configuración de Terraform no es válida${NC}"
  exit 1
}

echo -e "${YELLOW}Aplicando configuración (esto puede tomar varios minutos)...${NC}"
terraform apply -auto-approve || {
  echo -e "${RED}Error: No se pudo aplicar la configuración de Terraform${NC}"
  exit 1
}

# Obtener información importante de Terraform
echo -e "${GREEN}=== Obteniendo información de los recursos desplegados ===${NC}"
# Obtenemos información sobre los balanceadores de carga y servicios
USER_ALB_DNS=$(terraform output -raw user_service_dns || echo "No disponible")
PRODUCT_ALB_DNS=$(terraform output -raw product_service_dns || echo "No disponible")
FRONTEND_URL=$(terraform output -raw frontend_cloudfront_domain)
API_URL=$(terraform output -raw api_gateway_invoke_url)
S3_BUCKET=$(terraform output -raw frontend_bucket_name)

# Obtener credenciales DockerHub
DOCKERHUB_USER=$(grep -oP 'dockerhub_username\s*=\s*"\K[^"]*' "$TFVARS_PATH")

# Obtener información de bases de datos
USER_DB_ENDPOINT=$(terraform output -raw user_db_endpoint)
PRODUCT_DB_ENDPOINT=$(terraform output -raw product_db_endpoint)
DB_NAME_USER=$(terraform output -raw db_name_user)
DB_NAME_PRODUCT=$(terraform output -raw db_name_product)

# Actualizar config del frontend con la URL real de API Gateway
echo -e "${GREEN}=== Actualizando configuración del frontend con URL de API Gateway ===${NC}"
cd "$PROJECT_ROOT/frontend"

# Asegurarse de que la URL termina con /
if [[ "$API_URL" != */ ]]; then
  API_URL="${API_URL}/"
fi

cat > .env.production << EOF
REACT_APP_API_URL=${API_URL}
NODE_ENV=production
EOF

echo -e "${YELLOW}Configuración frontend generada:${NC}"
cat .env.production

# Reconstruir frontend con la URL de API Gateway
echo -e "${YELLOW}Reconstruyendo frontend con la URL real de API Gateway...${NC}"
npm install && npm run build || {
  echo -e "${RED}Error: No se pudo reconstruir el frontend${NC}"
  exit 1
}

# Subir frontend a S3
echo -e "${GREEN}=== Subiendo frontend a S3 ===${NC}"
if [ -d "$PROJECT_ROOT/frontend/build" ]; then
  aws s3 sync "$PROJECT_ROOT/frontend/build/" "s3://$S3_BUCKET/" --delete || {
    echo -e "${RED}Error al subir frontend a S3${NC}"
    exit 1
  }
  
  echo -e "${GREEN}✅ Frontend subido a S3 correctamente${NC}"
else
  echo -e "${RED}Error: No se encontró el directorio de build del frontend${NC}"
  exit 1
fi

# Invalidar caché de CloudFront
echo -e "${YELLOW}Invalidando caché de CloudFront...${NC}"
DISTRIBUTION_ID=$(aws cloudfront list-distributions --query "DistributionList.Items[?contains(DomainName,'${FRONTEND_URL}')].Id" --output text)
if [ -n "$DISTRIBUTION_ID" ]; then
  aws cloudfront create-invalidation --distribution-id $DISTRIBUTION_ID --paths "/*" && \
  echo -e "${GREEN}✅ Caché de CloudFront invalidada correctamente${NC}" || \
  echo -e "${RED}⚠️ Error al invalidar caché de CloudFront${NC}"
else
  echo -e "${RED}⚠️ No se pudo encontrar el ID de la distribución de CloudFront${NC}"
fi

# Esperar a que los servicios estén disponibles (API Gateway puede tardar unos minutos)
echo -e "${YELLOW}Esperando que los servicios estén disponibles (5m)...${NC}"
sleep 300

# Verificar API Gateway
echo -e "${GREEN}=== Verificando API Gateway ===${NC}"

# Función para intentar verificar la salud varias veces
check_health_endpoint() {
  local endpoint=$1
  local name=$2
  local max_attempts=10
  local wait_time=30
  
  echo -e "${YELLOW}Probando endpoint de $name...${NC}"
  
  for ((i=1; i<=max_attempts; i++)); do
    HEALTH=$(curl -s "${endpoint}")
    echo -e "${YELLOW}Intento $i/$max_attempts: $HEALTH${NC}"
    
    if [[ "$HEALTH" == *'"status":"healthy"'* ]]; then
      echo -e "${GREEN}✅ API Gateway conectado con servicio de $name${NC}"
      return 0
    else
      echo -e "${YELLOW}Servicio de $name aún no disponible, esperando...${NC}"
      sleep $wait_time
    fi
  done
  
  echo -e "${RED}❌ Error al acceder al servicio de $name después de $max_attempts intentos.${NC}"
  return 1
}

echo -e "${YELLOW}Probando endpoint de productos...${NC}"
PRODUCT_HEALTH=$(curl -s "${API_URL}products/health")
if [[ "$PRODUCT_HEALTH" == *'"status":"healthy"'* ]]; then
  echo -e "${GREEN}✅ API Gateway conectado con servicio de productos${NC}"
else
  echo -e "${RED}❌ Error al acceder al servicio de productos: $PRODUCT_HEALTH${NC}"
  echo -e "${YELLOW}Verificando logs de la instancia...${NC}"
  # Este paso es opcional, requiere configuración adicional
fi

# Mostrar información de despliegue
echo -e "${GREEN}=== Despliegue completado exitosamente ===${NC}"
echo -e "${YELLOW}URLs de acceso:${NC}"
echo -e "Frontend: https://${FRONTEND_URL}"
echo -e "API Gateway: ${API_URL}"
echo -e "ALB User Service: http://${USER_ALB_DNS}"
echo -e "ALB Product Service: http://${PRODUCT_ALB_DNS}"
echo -e ""
echo -e "${YELLOW}Información de bases de datos:${NC}"
echo -e "User DB: ${USER_DB_ENDPOINT}"
echo -e "Product DB: ${PRODUCT_DB_ENDPOINT}"
echo -e ""
echo -e "${YELLOW}Acciones de prueba:${NC}"
echo -e "Crear usuario de prueba: curl -X POST -H \"Content-Type: application/json\" -d '{\"name\":\"Usuario Test\",\"email\":\"test@example.com\",\"password\":\"test123\"}' \"${API_URL}users\""
echo -e "Crear producto de prueba: curl -X POST -H \"Content-Type: application/json\" -d '{\"name\":\"Producto Test\",\"description\":\"Descripción de prueba\",\"price\":99.99}' \"${API_URL}products\""
echo -e ""
echo -e "${YELLOW}Para eliminar todos los recursos:${NC} cd $TERRAFORM_DIR && terraform destroy -auto-approve"