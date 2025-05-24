#!/bin/bash
# filepath: e:\BRNDLD\appgestion\infrastructure\deploy.sh
# deploy.sh - Script mejorado para desplegar la infraestructura en AWS

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

echo -e "${GREEN}=== Desplegando AppGestion en AWS ===${NC}"

# Función para validar disponibilidad de herramientas
check_tool() {
  tool=$1
  if ! command -v $tool &> /dev/null; then
    echo -e "${RED}Error: $tool no está instalado${NC}"
    echo -e "${YELLOW}Por favor instale $tool antes de continuar.${NC}"
    exit 1
  else
    echo -e "${GREEN}✅ $tool encontrado${NC}"
  fi
}

# Verificar herramientas necesarias
echo -e "${YELLOW}Verificando herramientas necesarias...${NC}"
for cmd in terraform ansible-playbook aws docker jq; do
  check_tool $cmd
done

# Función para verificar directorios requeridos
check_directory() {
  dir=$1
  if [ ! -d "$dir" ]; then
    echo -e "${RED}Error: El directorio '$dir' no existe${NC}"
    if [[ "$dir" == *"frontend/build"* ]]; then
      echo -e "${YELLOW}Es necesario construir el frontend primero.${NC}"
      echo -e "${YELLOW}¿Desea ejecutar './infrastructure/build_images.sh' ahora? (s/n)${NC}"
      read -r response
      if [[ "$response" =~ ^([sS][iI]|[sS])$ ]]; then
        "$PROJECT_ROOT/infrastructure/build_images.sh"
        # Verificar nuevamente
        if [ ! -d "$dir" ]; then
          echo -e "${RED}Error: No se pudo crear el directorio build del frontend${NC}"
          exit 1
        fi
      else
        echo -e "${RED}Abortando despliegue. Ejecute primero: ./infrastructure/build_images.sh${NC}"
        exit 1
      fi
    else
      echo -e "${RED}Abortando despliegue. Estructura de proyecto incompleta.${NC}"
      exit 1
    fi
  else
    echo -e "${GREEN}✅ Directorio '$dir' encontrado${NC}"
  fi
}

# Verificar estructura del proyecto
echo -e "${YELLOW}Verificando estructura del proyecto...${NC}"
for dir in "infrastructure/terraform" "infrastructure/ansible" "frontend/build" "user-service" "product-service" "nginx"; do
  check_directory "$dir"
done

# Verificar archivo de variables Terraform
if [ ! -f "infrastructure/terraform/terraform.tfvars" ]; then
  echo -e "${RED}Error: No se encontró el archivo terraform.tfvars${NC}"
  echo -e "${YELLOW}Cree el archivo terraform.tfvars con las variables requeridas.${NC}"
  exit 1
else
  echo -e "${GREEN}✅ Archivo terraform.tfvars encontrado${NC}"
fi

# Validar contenido de terraform.tfvars
required_vars=("aws_region" "project_name" "environment" "db_username" "db_password" 
               "ssh_key_name" "ssh_key_path" "dockerhub_username" "dockerhub_password")
               
for var in "${required_vars[@]}"; do
  if ! grep -q "$var" "infrastructure/terraform/terraform.tfvars"; then
    echo -e "${RED}Error: Variable '$var' no encontrada en terraform.tfvars${NC}"
    exit 1
  fi
done



# Verificar ruta SSH
SSH_KEY_PATH=$(grep ssh_key_path infrastructure/terraform/terraform.tfvars | sed -E 's/ssh_key_path\s*=\s*"(.*)"/\1/')
SSH_KEY_NAME=$(grep ssh_key_name infrastructure/terraform/terraform.tfvars | sed -E 's/ssh_key_name\s*=\s*"(.*)"/\1/')

if [ -z "$SSH_KEY_NAME" ]; then
  # Extraer el nombre base del archivo si no está especificado
  SSH_KEY_NAME=$(basename "$SSH_KEY_PATH" .pem)
  echo -e "${YELLOW}⚠️ ssh_key_name no especificado, usando: $SSH_KEY_NAME${NC}"
  # Actualizar el archivo terraform.tfvars
  sed -i '/ssh_key_name/d' infrastructure/terraform/terraform.tfvars
  echo "ssh_key_name = \"$SSH_KEY_NAME\"" >> infrastructure/terraform/terraform.tfvars
fi

if [ ! -f "$SSH_KEY_PATH" ]; then
  echo -e "${RED}Error: Archivo de clave SSH no encontrado en: $SSH_KEY_PATH${NC}"
  exit 1
else
  echo -e "${GREEN}✅ Clave SSH encontrada en: $SSH_KEY_PATH${NC}"
  # Verificar permisos
  if [[ "$OSTYPE" == "linux-gnu"* || "$OSTYPE" == "darwin"* ]]; then
    current_perms=$(stat -c "%a" "$SSH_KEY_PATH" 2>/dev/null || stat -f "%Lp" "$SSH_KEY_PATH")
    if [ "$current_perms" != "400" ] && [ "$current_perms" != "600" ]; then
      echo -e "${YELLOW}⚠️ Advertencia: Permisos de la clave SSH ($current_perms) no son seguros.${NC}"
      echo -e "${YELLOW}Se recomienda: chmod 400 $SSH_KEY_PATH${NC}"
    fi
  fi
fi

# Verificar imágenes Docker
echo -e "${YELLOW}Verificando imágenes Docker...${NC}"
DOCKERHUB_USER=$(grep dockerhub_username infrastructure/terraform/terraform.tfvars | sed -E 's/dockerhub_username\s*=\s*"(.*)"/\1/')

check_image() {
  IMAGE_NAME="$1"
  echo -e "${YELLOW}Verificando imagen: ${DOCKERHUB_USER}/${IMAGE_NAME}...${NC}"
  HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" "https://hub.docker.com/v2/repositories/${DOCKERHUB_USER}/${IMAGE_NAME}/tags/latest")
  if [ "$HTTP_CODE" -eq 200 ]; then
    echo -e "${GREEN}✅ Imagen ${DOCKERHUB_USER}/${IMAGE_NAME} encontrada${NC}"
    return 0
  else
    echo -e "${RED}❌ Imagen ${DOCKERHUB_USER}/${IMAGE_NAME} no encontrada${NC}"
    return 1
  fi
}

images_missing=false
for image in "appgestion-user-service" "appgestion-product-service" "appgestion-nginx"; do
  if ! check_image "$image"; then
    images_missing=true
  fi
done

if [ "$images_missing" = true ]; then
  echo -e "${YELLOW}¿Desea construir las imágenes faltantes ahora? (s/n)${NC}"
  read -r response
  if [[ "$response" =~ ^([sS][iI]|[sS])$ ]]; then
    "$PROJECT_ROOT/infrastructure/build_images.sh"
  else
    echo -e "${RED}Abortando despliegue. Ejecute primero: ./infrastructure/build_images.sh${NC}"
    exit 1
  fi
fi

# Crear directorios necesarios
echo -e "${YELLOW}Preparando estructura de Ansible...${NC}"
mkdir -p infrastructure/ansible/{inventory,group_vars,roles/appgestion/{tasks,templates}}
mkdir -p infrastructure/terraform/templates

# Crear plantillas si no existen
if [ ! -f "infrastructure/terraform/templates/inventory.tmpl" ]; then
  cat > infrastructure/terraform/templates/inventory.tmpl << 'EOF'
[backend]
${backend_ip} ansible_user=ubuntu ansible_ssh_private_key_file=${ssh_key_path}
EOF
fi

if [ ! -f "infrastructure/terraform/templates/vars.tmpl" ]; then
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

# Desplegar infraestructura con Terraform
echo -e "${GREEN}=== Desplegando infraestructura con Terraform ===${NC}"
cd infrastructure/terraform

echo -e "${YELLOW}Inicializando Terraform...${NC}"
terraform init

echo -e "${YELLOW}Validando configuración Terraform...${NC}"
terraform validate

if [ $? -ne 0 ]; then
  echo -e "${RED}Error: La validación de Terraform falló${NC}"
  exit 1
else
  echo -e "${GREEN}✅ Configuración de Terraform validada correctamente${NC}"
fi

echo -e "${YELLOW}Aplicando configuración Terraform...${NC}"
echo -e "${YELLOW}Este proceso puede tomar varios minutos...${NC}"
terraform apply -auto-approve

if [ $? -ne 0 ]; then
  echo -e "${RED}Error: La aplicación de Terraform falló${NC}"
  exit 1
else
  echo -e "${GREEN}✅ Infraestructura desplegada correctamente con Terraform${NC}"
fi

# Guardar información importante
BACKEND_IP=$(terraform output -raw backend_public_ip)
API_URL=$(terraform output -raw api_gateway_invoke_url)
FRONTEND_URL=$(terraform output -raw frontend_cloudfront_domain)
S3_BUCKET=$(terraform output -raw frontend_bucket_name)
CF_DIST_ID=$(terraform output -raw cloudfront_distribution_id)
SSH_KEY_PATH=$(terraform output -raw ssh_key_path)

# Función para desplegar frontend en S3
deploy_frontend_to_s3() {
  echo -e "${YELLOW}Desplegando frontend en S3 con configuración actualizada...${NC}"
  
  if [ -z "$S3_BUCKET" ]; then
    echo -e "${RED}Error: No se pudo obtener el nombre del bucket S3${NC}"
    return 1
  fi
  
  if [ -n "$API_URL" ]; then
    # Actualizar configuración del frontend con la URL real de la API
    cd "$PROJECT_ROOT/frontend"
    
    API_URL="${API_URL%/}"  # Eliminar barra final si existe
    
    echo -e "${YELLOW}Configurando frontend con API URL: ${API_URL}${NC}"
    cat > .env.production << EOF
REACT_APP_API_URL=${API_URL}
NODE_ENV=production
EOF
    
    echo -e "${YELLOW}Reconstruyendo frontend con configuración actualizada...${NC}"
    echo -e "${YELLOW}Instalando dependencias...${NC}"
    npm ci --silent
    
    echo -e "${YELLOW}Compilando frontend...${NC}"
    npm run build
    
    # Verificar que la compilación fue exitosa
    if [ ! -f "build/index.html" ]; then
      echo -e "${RED}Error: La compilación del frontend falló${NC}"
      return 1
    fi
    
    cd "$PROJECT_ROOT/infrastructure/terraform"
  else
    echo -e "${YELLOW}⚠️ No se pudo obtener la URL de la API. Usando frontend ya compilado.${NC}"
  fi
  
  # Subir al S3
  echo -e "${YELLOW}Subiendo frontend al bucket: ${S3_BUCKET}${NC}"
  aws s3 sync "$PROJECT_ROOT/frontend/build/" "s3://${S3_BUCKET}/" --delete
  
  # Invalidar caché de CloudFront
  if [ -n "$CF_DIST_ID" ]; then
    echo -e "${YELLOW}Invalidando caché de CloudFront...${NC}"
    aws cloudfront create-invalidation --distribution-id ${CF_DIST_ID} --paths "/*"
  fi
  
  echo -e "${GREEN}✅ Frontend desplegado exitosamente${NC}"
}

# Desplegar frontend
deploy_frontend_to_s3

# Función para verificar disponibilidad de EC2
check_ec2_availability() {
  local max_attempts=20
  local retry_interval=15
  
  echo -e "${YELLOW}Esperando que la instancia EC2 esté disponible...${NC}"
  for ((i=1; i<=max_attempts; i++)); do
    echo -e "${YELLOW}Intento $i de $max_attempts...${NC}"
    
    if ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 -i "$SSH_KEY_PATH" ubuntu@"$BACKEND_IP" 'echo "Conexión SSH establecida"' &>/dev/null; then
      echo -e "${GREEN}✅ Instancia EC2 disponible${NC}"
      return 0
    fi
    
    echo -e "${YELLOW}La instancia aún no está disponible. Esperando $retry_interval segundos...${NC}"
    sleep $retry_interval
  done
  
  echo -e "${RED}Error: La instancia EC2 no está disponible después de $max_attempts intentos${NC}"
  return 1
}

# Verificar que la instancia EC2 esté disponible
check_ec2_availability || exit 1

# Ejecutar Ansible
echo -e "${GREEN}=== Configurando servicios con Ansible ===${NC}"
cd "$PROJECT_ROOT/infrastructure/ansible"

if [ -f "inventory/hosts.ini" ]; then
  echo -e "${YELLOW}Ejecutando playbook de Ansible...${NC}"
  ANSIBLE_HOST_KEY_CHECKING=False ansible-playbook -i inventory/hosts.ini playbook.yml
  
  if [ $? -ne 0 ]; then
    echo -e "${RED}Error: La ejecución del playbook de Ansible falló${NC}"
    echo -e "${YELLOW}Revisar logs para más detalles${NC}"
  else
    echo -e "${GREEN}✅ Configuración de servicios completada exitosamente${NC}"
  fi
else
  echo -e "${RED}Error: No se encontró el archivo de inventario${NC}"
  exit 1
fi

# Función para verificar servicios
check_service_endpoint() {
  local endpoint="$1"
  local service_name="$2"
  local max_attempts=10
  local retry_interval=10
  
  echo -e "${YELLOW}Verificando endpoint de $service_name: $endpoint${NC}"
  
  for ((i=1; i<=max_attempts; i++)); do
    echo -e "${YELLOW}Intento $i de $max_attempts...${NC}"
    
    RESPONSE=$(curl -s -w "\n%{http_code}" "$endpoint" 2>/dev/null)
    HTTP_CODE=$(echo "$RESPONSE" | tail -n1)
    CONTENT=$(echo "$RESPONSE" | head -n -1)
    
    if [ "$HTTP_CODE" -eq 200 ]; then
      echo -e "${GREEN}✅ Servicio de $service_name funcionando (HTTP 200)${NC}"
      echo -e "${YELLOW}Respuesta: $CONTENT${NC}"
      return 0
    fi
    
    echo -e "${YELLOW}Servicio de $service_name responde con código HTTP ${HTTP_CODE}${NC}"
    echo -e "${YELLOW}Esperando $retry_interval segundos...${NC}"
    sleep $retry_interval
  done
  
  echo -e "${RED}❌ Servicio de $service_name no está respondiendo correctamente después de $max_attempts intentos${NC}"
  return 1
}

# Verificar servicios desplegados
echo -e "${GREEN}=== Verificando servicios desplegados ===${NC}"
cd "$PROJECT_ROOT/infrastructure/terraform"

# Mostrar URLs importantes
echo -e "${GREEN}=== URLs y recursos desplegados ===${NC}"
echo -e "${YELLOW}URLs de acceso:${NC}"

if [ -n "$FRONTEND_URL" ]; then
  echo -e "Frontend: https://${FRONTEND_URL}"
fi

if [ -n "$API_URL" ]; then
  echo -e "API Gateway: ${API_URL}"
fi

if [ -n "$BACKEND_IP" ]; then
  echo -e "Backend IP: ${BACKEND_IP}"
  echo -e "SSH: ssh -i ${SSH_KEY_PATH} ubuntu@${BACKEND_IP}"
fi

# Esperar a que los servicios estén completamente disponibles
echo -e "${YELLOW}Esperando 60 segundos para que los servicios se inicialicen completamente...${NC}"
sleep 60

# Verificar endpoints
if [ -n "$API_URL" ]; then
  echo -e "${YELLOW}Verificando endpoints de la API...${NC}"
  
  check_service_endpoint "${API_URL}/users" "usuarios"
  check_service_endpoint "${API_URL}/products" "productos"
  
  # Verificar conexión desde frontend a API
  echo -e "${YELLOW}Verificando CORS desde frontend a API...${NC}"
  CORS_TEST=$(curl -s -I -X OPTIONS \
    -H "Origin: https://${FRONTEND_URL}" \
    -H "Access-Control-Request-Method: GET" \
    "${API_URL}/users" | grep -i "Access-Control-Allow")
  
  if [ -n "$CORS_TEST" ]; then
    echo -e "${GREEN}✅ Configuración CORS funcionando correctamente${NC}"
    echo -e "$CORS_TEST"
  else
    echo -e "${RED}⚠️ La configuración CORS puede tener problemas${NC}"
  fi
fi

# Verificar bases de datos
echo -e "${YELLOW}Verificando conexión a bases de datos...${NC}"
ssh -o StrictHostKeyChecking=no -i "$SSH_KEY_PATH" ubuntu@"$BACKEND_IP" << EOF
echo "Verificando servicio de usuarios..."
docker-compose exec -T user-service python -c "
import os
import psycopg2
try:
    conn = psycopg2.connect(
        host=os.environ.get('USER_DB_HOST'),
        port=os.environ.get('USER_DB_PORT'),
        dbname=os.environ.get('USER_DB_NAME'),
        user=os.environ.get('USER_DB_USER'),
        password=os.environ.get('USER_DB_PASSWORD')
    )
    cur = conn.cursor()
    cur.execute('SELECT 1')
    print('✅ Conexión a base de datos de usuarios exitosa')
    cur.close()
    conn.close()
except Exception as e:
    print('❌ Error al conectar a base de datos de usuarios:', e)
    exit(1)
"

echo "Verificando servicio de productos..."
docker-compose exec -T product-service python -c "
import os
import psycopg2
try:
    conn = psycopg2.connect(
        host=os.environ.get('PRODUCT_DB_HOST'),
        port=os.environ.get('PRODUCT_DB_PORT'),
        dbname=os.environ.get('PRODUCT_DB_NAME'),
        user=os.environ.get('PRODUCT_DB_USER'),
        password=os.environ.get('PRODUCT_DB_PASSWORD')
    )
    cur = conn.cursor()
    cur.execute('SELECT 1')
    print('✅ Conexión a base de datos de productos exitosa')
    cur.close()
    conn.close()
except Exception as e:
    print('❌ Error al conectar a base de datos de productos:', e)
    exit(1)
"
EOF

echo -e "${GREEN}=== El sistema AppGestion está desplegado y listo para usar ===${NC}"
echo -e "${YELLOW}Para acceder a la aplicación visite: https://${FRONTEND_URL}${NC}"
echo -e "${YELLOW}Para monitorear los servicios: ssh -i ${SSH_KEY_PATH} ubuntu@${BACKEND_IP} 'cd appgestion && docker-compose ps'${NC}"
