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

# Detectar IP pública para configuración de seguridad
export MY_PUBLIC_IP=$(curl -s https://api.ipify.org)
echo -e "${YELLOW}IP pública detectada: ${MY_PUBLIC_IP}${NC}"

echo -e "${GREEN}=== Desplegando AppGestion en AWS ===${NC}"

# Verificar herramientas necesarias
for cmd in terraform aws jq; do
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
if [ ! -f "infrastructure/terraform/terraform.tfvars" ]; then
  echo -e "${RED}Error: No se encontró el archivo terraform.tfvars${NC}"
  exit 1
else
  echo -e "${GREEN}✅ Archivo terraform.tfvars encontrado${NC}"
  
  # Verificar variables esenciales
  required_vars=("aws_region" "project_name" "environment" "db_username" "db_password" 
               "ssh_key_path" "dockerhub_username" "dockerhub_password")
               
  for var in "${required_vars[@]}"; do
    if ! grep -q "$var" "infrastructure/terraform/terraform.tfvars"; then
      echo -e "${RED}Error: Variable '$var' no encontrada en terraform.tfvars${NC}"
      exit 1
    fi
  done
  
  echo -e "${GREEN}✅ Variables requeridas encontradas${NC}"
fi

# Obtener y verificar SSH key
SSH_KEY_PATH=$(grep -oP 'ssh_key_path\s*=\s*"\K[^"]*' infrastructure/terraform/terraform.tfvars)
SSH_KEY_NAME=$(grep -oP 'ssh_key_name\s*=\s*"\K[^"]*' infrastructure/terraform/terraform.tfvars 2>/dev/null || echo "")

if [ -z "$SSH_KEY_NAME" ] && [ -n "$SSH_KEY_PATH" ]; then
  SSH_KEY_NAME=$(basename "$SSH_KEY_PATH" | sed 's/\.[^.]*$//')
  echo -e "${YELLOW}⚠️ ssh_key_name no especificado, usando: $SSH_KEY_NAME${NC}"
  echo "ssh_key_name = \"$SSH_KEY_NAME\"" >> infrastructure/terraform/terraform.tfvars
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
      chmod 400 "$SSH_KEY_PATH" || echo -e "${RED}No se pudieron cambiar los permisos. Continuar de todos modos.${NC}"
    fi
  fi
fi

# Construir imágenes llamando al script específico
echo -e "${YELLOW}¿Desea construir las imágenes Docker ahora? (s/n)${NC}"
read -r response
if [[ "$response" =~ ^([sS][iI]|[sS])$ ]]; then
  # En lugar de duplicar código, llamamos al script de construcción
  echo -e "${GREEN}Ejecutando script de construcción de imágenes...${NC}"
  bash "$SCRIPT_DIR/build_images.sh" || {
    echo -e "${RED}Error al construir las imágenes${NC}"
    exit 1
  }
fi

# Desplegar con Terraform
echo -e "${GREEN}=== Desplegando infraestructura con Terraform ===${NC}"
cd infrastructure/terraform

# Agregar variable allowed_ssh_ip si se detectó correctamente
if [ -n "$MY_PUBLIC_IP" ]; then
  echo -e "\n# IP pública para reglas de seguridad" >> terraform.tfvars
  echo "allowed_ssh_ip = \"$MY_PUBLIC_IP/32\"" >> terraform.tfvars
  echo -e "${GREEN}✅ IP pública ($MY_PUBLIC_IP) agregada a las variables de Terraform${NC}"
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

# Obtener información importante
FRONTEND_URL=$(terraform output -raw frontend_cloudfront_domain)
API_URL=$(terraform output -raw api_gateway_invoke_url)
BACKEND_IP=$(terraform output -raw backend_public_ip)
S3_BUCKET=$(terraform output -raw frontend_bucket_name)
DOCKERHUB_USER=$(grep dockerhub_username infrastructure/terraform/terraform.tfvars | cut -d '"' -f2)

# Actualizar config del frontend con la URL real de API Gateway
echo -e "${GREEN}=== Actualizando configuración del frontend con URL de API Gateway ===${NC}"
cd "$PROJECT_ROOT/frontend"
cat > .env.production << EOF
REACT_APP_API_URL=${API_URL}
NODE_ENV=production
EOF

# Reconstruir frontend con la URL de API Gateway
echo -e "${YELLOW}Reconstruyendo frontend con la URL real de API Gateway...${NC}"
npm run build || {
  echo -e "${RED}Error: No se pudo reconstruir el frontend${NC}"
  exit 1
}

# Subir frontend a S3
echo -e "${GREEN}=== Subiendo frontend a S3 ===${NC}"
if [ -d "$PROJECT_ROOT/frontend/build" ]; then
  aws s3 sync "$PROJECT_ROOT/frontend/build/" "s3://$S3_BUCKET/" --delete || {
    echo -e "${RED}Error al subir frontend a S3${NC}"
  }
  
  echo -e "${GREEN}✅ Frontend subido a S3 correctamente${NC}"
else
  echo -e "${RED}Error: No se encontró el directorio de build del frontend${NC}"
fi

# Configurar servicios en la instancia EC2
echo -e "${GREEN}=== Configurando servicios en la instancia backend ===${NC}"
echo -e "${YELLOW}Creando archivo docker-compose.yml en la instancia...${NC}"

# Esperar un poco para asegurar que la instancia esté lista
echo -e "${YELLOW}Esperando que la instancia esté lista (30s)...${NC}"
sleep 30

# Crear docker-compose.yml y enviarlo a la instancia
cat > docker-compose.yml << EOF
version: '3.8'

networks:
  appgestion-network:
    driver: bridge

services:
  user-service:
    image: ${DOCKERHUB_USER}/appgestion-user-service:latest
    container_name: user-service
    environment:
      - POSTGRES_HOST=$(terraform output -raw user_db_endpoint | cut -d ':' -f 1)
      - POSTGRES_DB=$(terraform output -raw db_name_user)
      - POSTGRES_USER=$(grep db_username infrastructure/terraform/terraform.tfvars | cut -d '"' -f2)
      - POSTGRES_PASSWORD=$(grep db_password infrastructure/terraform/terraform.tfvars | cut -d '"' -f2)
      - POSTGRES_PORT=5432
      - CORS_ALLOWED_ORIGINS=https://${FRONTEND_URL}
      - SERVICE_URL=http://localhost:3001
      - API_GATEWAY_URL=${API_URL}
    ports:
      - "3001:3001"
    networks:
      - appgestion-network
    restart: unless-stopped

  product-service:
    image: ${DOCKERHUB_USER}/appgestion-product-service:latest
    container_name: product-service
    environment:
      - POSTGRES_HOST=$(terraform output -raw product_db_endpoint | cut -d ':' -f 1)
      - POSTGRES_DB=$(terraform output -raw db_name_product)
      - POSTGRES_USER=$(grep db_username infrastructure/terraform/terraform.tfvars | cut -d '"' -f2)
      - POSTGRES_PASSWORD=$(grep db_password infrastructure/terraform/terraform.tfvars | cut -d '"' -f2)
      - POSTGRES_PORT=5432
      - CORS_ALLOWED_ORIGINS=https://${FRONTEND_URL}
      - SERVICE_URL=http://localhost:3002
      - API_GATEWAY_URL=${API_URL}
    ports:
      - "3002:3002"
    networks:
      - appgestion-network
    restart: unless-stopped
EOF

# Copiar el archivo docker-compose.yml a la instancia
echo -e "${YELLOW}Copiando archivos a la instancia...${NC}"
scp -i "$SSH_KEY_PATH" -o StrictHostKeyChecking=no docker-compose.yml ubuntu@$BACKEND_IP:~/appgestion/ || {
  echo -e "${RED}Error: No se pudieron copiar los archivos a la instancia${NC}"
}

# Iniciar los servicios
echo -e "${YELLOW}Iniciando servicios en la instancia...${NC}"
ssh -i "$SSH_KEY_PATH" -o StrictHostKeyChecking=no ubuntu@$BACKEND_IP "cd ~/appgestion && docker-compose pull && docker-compose up -d" || {
  echo -e "${RED}Error al iniciar los servicios en la instancia${NC}"
}

# Mostrar información de despliegue
echo -e "${GREEN}=== Despliegue completado exitosamente ===${NC}"
echo -e "${YELLOW}URLs de acceso:${NC}"
echo -e "Frontend: https://${FRONTEND_URL}"
echo -e "API Gateway: ${API_URL}"
echo -e "Backend: ${BACKEND_IP}"
echo -e ""
echo -e "${YELLOW}Comandos útiles:${NC}"
echo -e "SSH al servidor: ssh -i ${SSH_KEY_PATH} ubuntu@${BACKEND_IP}"
echo -e "Ver logs: ssh -i ${SSH_KEY_PATH} ubuntu@${BACKEND_IP} \"cd ~/appgestion && docker-compose logs\""
echo -e "Reiniciar servicios: ssh -i ${SSH_KEY_PATH} ubuntu@${BACKEND_IP} \"cd ~/appgestion && docker-compose restart\""
echo -e "Para eliminar los recursos: cd infrastructure/terraform && terraform destroy -auto-approve"