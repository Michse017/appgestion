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

# Definir ruta absoluta al archivo terraform.tfvars para mantener consistencia
TFVARS_PATH="$PROJECT_ROOT/infrastructure/terraform/terraform.tfvars"
TERRAFORM_DIR="$PROJECT_ROOT/infrastructure/terraform"

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

# Obtener y verificar SSH key
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
cd "$TERRAFORM_DIR"

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
DOCKERHUB_USER=$(grep -oP 'dockerhub_username\s*=\s*"\K[^"]*' "$TFVARS_PATH")

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

# Imprimir para verificación
echo -e "${YELLOW}Configuración frontend generada:${NC}"
cat .env.production

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

# Esperar más tiempo para asegurar que la instancia esté completamente inicializada
echo -e "${YELLOW}Esperando que la instancia esté completamente lista (5min)...${NC}"
sleep 300

# Crear directorio de la aplicación en la instancia (puede que ya exista del user_data)
echo -e "${YELLOW}Creando directorio de la aplicación en la instancia...${NC}"
ssh -i "$SSH_KEY_PATH" -o StrictHostKeyChecking=no -o ConnectTimeout=30 -o ConnectionAttempts=5 ubuntu@$BACKEND_IP "mkdir -p ~/appgestion" || {
  echo -e "${YELLOW}⚠️ Esperando 60 segundos adicionales para asegurar que la instancia esté lista...${NC}"
  sleep 60
  ssh -i "$SSH_KEY_PATH" -o StrictHostKeyChecking=no -o ConnectTimeout=30 -o ConnectionAttempts=5 ubuntu@$BACKEND_IP "mkdir -p ~/appgestion" || {
    echo -e "${RED}Error: No se pudo conectar a la instancia después de esperar. Verifique el grupo de seguridad y la inicialización.${NC}"
    exit 1
  }
}

# Crear docker-compose.yml y enviarlo a la instancia
cd "$PROJECT_ROOT"
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
      - POSTGRES_HOST=$(cd "$TERRAFORM_DIR" && terraform output -raw user_db_endpoint | cut -d ':' -f 1)
      - POSTGRES_DB=$(cd "$TERRAFORM_DIR" && terraform output -raw db_name_user)
      - POSTGRES_USER=$(grep -oP 'db_username\s*=\s*"\K[^"]*' "$TFVARS_PATH")
      - POSTGRES_PASSWORD=$(grep -oP 'db_password\s*=\s*"\K[^"]*' "$TFVARS_PATH")
      - POSTGRES_PORT=5432
      - CORS_ALLOWED_ORIGINS=https://${FRONTEND_URL},${API_URL}
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
      - POSTGRES_HOST=$(cd "$TERRAFORM_DIR" && terraform output -raw product_db_endpoint | cut -d ':' -f 1)
      - POSTGRES_DB=$(cd "$TERRAFORM_DIR" && terraform output -raw db_name_product)
      - POSTGRES_USER=$(grep -oP 'db_username\s*=\s*"\K[^"]*' "$TFVARS_PATH")
      - POSTGRES_PASSWORD=$(grep -oP 'db_password\s*=\s*"\K[^"]*' "$TFVARS_PATH")
      - POSTGRES_PORT=5432
      - CORS_ALLOWED_ORIGINS=https://${FRONTEND_URL},${API_URL}
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
scp -i "$SSH_KEY_PATH" -o StrictHostKeyChecking=no -o ConnectTimeout=30 -o ConnectionAttempts=3 docker-compose.yml ubuntu@$BACKEND_IP:~/appgestion/ || {
  echo -e "${RED}Error: No se pudieron copiar los archivos a la instancia${NC}"
  echo -e "${YELLOW}Verificando el estado de la instancia y la configuración SSH...${NC}"
  aws ec2 describe-instances --instance-ids $(cd "$TERRAFORM_DIR" && terraform output -raw backend_instance_id 2>/dev/null || echo "unknown") --query 'Reservations[0].Instances[0].State.Name'
  exit 1
}

# Iniciar los servicios
echo -e "${YELLOW}Iniciando servicios en la instancia...${NC}"
ssh -i "$SSH_KEY_PATH" -o StrictHostKeyChecking=no -o ConnectTimeout=30 ubuntu@$BACKEND_IP "cd ~/appgestion && docker-compose pull && docker-compose up -d" || {
  echo -e "${RED}Error al iniciar los servicios en la instancia${NC}"
  echo -e "${YELLOW}Verificando Docker en la instancia...${NC}"
  ssh -i "$SSH_KEY_PATH" -o StrictHostKeyChecking=no ubuntu@$BACKEND_IP "sudo systemctl status docker || (sudo systemctl start docker && sudo systemctl status docker)"
  echo -e "${YELLOW}Reintentando la implementación de contenedores...${NC}"
  ssh -i "$SSH_KEY_PATH" -o StrictHostKeyChecking=no ubuntu@$BACKEND_IP "cd ~/appgestion && sudo docker-compose pull && sudo docker-compose up -d"
}

# Verificar que los servicios estén ejecutándose
echo -e "${YELLOW}Verificando que los servicios estén en ejecución...${NC}"
ssh -i "$SSH_KEY_PATH" -o StrictHostKeyChecking=no ubuntu@$BACKEND_IP "docker ps | grep -E 'user-service|product-service'" && {
  echo -e "${GREEN}✅ Servicios desplegados correctamente${NC}"
} || {
  echo -e "${RED}⚠️ Los servicios no parecen estar ejecutándose. Verificando logs:${NC}"
  ssh -i "$SSH_KEY_PATH" -o StrictHostKeyChecking=no ubuntu@$BACKEND_IP "cd ~/appgestion && docker-compose logs --tail=20"
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