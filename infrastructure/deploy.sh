#!/bin/bash
# deploy.sh - Script optimizado para desplegar la infraestructura en AWS

set -e

# Colores para mensajes
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
NC='\033[0m'

# Opciones configurables
SKIP_SSH_VERIFY=false
MAX_SSH_ATTEMPTS=30
SSH_RETRY_INTERVAL=30
WAIT_SERVICES=120  # Aumentado para dar más tiempo a la inicialización

# Procesar parámetros
for arg in "$@"; do
  case $arg in
    --skip-ssh-verify)
    SKIP_SSH_VERIFY=true
    shift
    ;;
    --help)
    echo "Uso: ./deploy.sh [opciones]"
    echo "Opciones:"
    echo "  --skip-ssh-verify    Omitir verificación de conectividad SSH"
    exit 0
    ;;
  esac
done

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
               "ssh_key_path" "dockerhub_username" "dockerhub_password")
               
for var in "${required_vars[@]}"; do
  if ! grep -q "$var" "infrastructure/terraform/terraform.tfvars"; then
    echo -e "${RED}Error: Variable '$var' no encontrada en terraform.tfvars${NC}"
    exit 1
  fi
done

# CORRECCIÓN 1: Mejorar extracción y manejo del nombre de la clave SSH
SSH_KEY_PATH=$(grep -oP 'ssh_key_path\s*=\s*"\K[^"]*' infrastructure/terraform/terraform.tfvars)
SSH_KEY_NAME=$(grep -oP 'ssh_key_name\s*=\s*"\K[^"]*' infrastructure/terraform/terraform.tfvars 2>/dev/null || echo "")

if [ -z "$SSH_KEY_NAME" ]; then
  # Extraer el nombre base del archivo si no está especificado
  SSH_KEY_NAME=$(basename "$SSH_KEY_PATH")
  # Manejar correctamente archivos con múltiples puntos (.ssh/aws-key.pem)
  if [[ "$SSH_KEY_NAME" == *.pem ]]; then
    SSH_KEY_NAME=${SSH_KEY_NAME%.pem}
  elif [[ "$SSH_KEY_NAME" == *.key ]]; then
    SSH_KEY_NAME=${SSH_KEY_NAME%.key}
  fi
  
  echo -e "${YELLOW}⚠️ ssh_key_name no especificado, usando: $SSH_KEY_NAME${NC}"
  
  # Verificar si el key_name ya existe en AWS
  aws ec2 describe-key-pairs --key-names "$SSH_KEY_NAME" >/dev/null 2>&1 || {
    echo -e "${RED}Error: El nombre de clave SSH '$SSH_KEY_NAME' no existe en AWS.${NC}"
    echo -e "${YELLOW}Por favor, cree la clave en AWS o especifique ssh_key_name en terraform.tfvars${NC}"
    exit 1
  }
  
  # Actualizar el archivo terraform.tfvars
  echo "ssh_key_name = \"$SSH_KEY_NAME\"" >> infrastructure/terraform/terraform.tfvars
fi

# Verificar que el archivo SSH existe y tiene permisos adecuados
if [ ! -f "$SSH_KEY_PATH" ]; then
  echo -e "${RED}Error: Archivo de clave SSH no encontrado en: $SSH_KEY_PATH${NC}"
  exit 1
else
  echo -e "${GREEN}✅ Clave SSH encontrada en: $SSH_KEY_PATH${NC}"
  # Verificar permisos y corregirlos si es necesario
  if [[ "$OSTYPE" == "linux-gnu"* || "$OSTYPE" == "darwin"* ]]; then
    current_perms=$(stat -c "%a" "$SSH_KEY_PATH" 2>/dev/null || stat -f "%Lp" "$SSH_KEY_PATH")
    if [ "$current_perms" != "400" ] && [ "$current_perms" != "600" ]; then
      echo -e "${YELLOW}⚠️ Corrigiendo permisos de la clave SSH (de $current_perms a 400)...${NC}"
      chmod 400 "$SSH_KEY_PATH"
      if [ $? -ne 0 ]; then
        echo -e "${RED}Error: No se pudieron cambiar los permisos de la clave SSH${NC}"
        echo -e "${YELLOW}Ejecute manualmente: chmod 400 $SSH_KEY_PATH${NC}"
      else
        echo -e "${GREEN}✅ Permisos de la clave SSH corregidos${NC}"
      fi
    fi
    
    # Verificar formato de la clave SSH
    if ! ssh-keygen -l -f "$SSH_KEY_PATH" &>/dev/null; then
      echo -e "${RED}⚠️ Advertencia: El formato de la clave SSH parece ser incorrecto${NC}"
      echo -e "${YELLOW}Si hay problemas de conexión, verifique que sea una clave SSH válida en formato PEM${NC}"
    fi
  fi
fi

# Verificar imágenes Docker con función mejorada
echo -e "${YELLOW}Verificando imágenes Docker...${NC}"
DOCKERHUB_USER=$(grep dockerhub_username infrastructure/terraform/terraform.tfvars | cut -d '"' -f2)

if [ -z "$DOCKERHUB_USER" ]; then
  echo -e "${RED}Error: No se pudo obtener el nombre de usuario de DockerHub${NC}"
  exit 1
fi

check_image() {
  IMAGE_NAME="$1"
  FULL_IMAGE_NAME="${DOCKERHUB_USER}/${IMAGE_NAME}"
  echo -e "${YELLOW}Verificando imagen: ${FULL_IMAGE_NAME}...${NC}"
  
  # Verificar primero localmente con formato de nombre exacto
  if docker images --format "{{.Repository}}" | grep -q "^${FULL_IMAGE_NAME}$"; then
    echo -e "${GREEN}✅ Imagen ${FULL_IMAGE_NAME} encontrada localmente${NC}"
    return 0
  fi
  
  # Segundo intento con docker inspect
  if docker image inspect "$FULL_IMAGE_NAME" &>/dev/null; then
    echo -e "${GREEN}✅ Imagen ${FULL_IMAGE_NAME} encontrada localmente${NC}"
    return 0
  fi
  
  # Tercer intento, intentar en Docker Hub
  HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" "https://hub.docker.com/v2/repositories/${DOCKERHUB_USER}/${IMAGE_NAME}/tags/latest")
  if [ "$HTTP_CODE" -eq 200 ]; then
    echo -e "${GREEN}✅ Imagen ${FULL_IMAGE_NAME} encontrada en Docker Hub${NC}"
    return 0
  else
    echo -e "${RED}❌ Imagen ${FULL_IMAGE_NAME} no encontrada ni local ni remotamente${NC}"
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

# Crear directorios necesarios para Ansible
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

# CORRECCIÓN 2: Mejorar manejo de URL de API para eliminar barras al final de manera correcta
if [ -n "$API_URL" ]; then
  # Asegurarse de eliminar cualquier barra al final y preservar el protocolo
  API_URL=$(echo "$API_URL" | sed 's/\/$//')
  echo -e "${GREEN}API URL procesada: ${API_URL}${NC}"
fi

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
    
    echo -e "${YELLOW}Configurando frontend con API URL: ${API_URL}${NC}"
    cat > .env.production << EOF
REACT_APP_API_URL=${API_URL}
NODE_ENV=production
EOF
    
    echo -e "${YELLOW}Reconstruyendo frontend con configuración actualizada...${NC}"
    echo -e "${YELLOW}Instalando dependencias...${NC}"
    npm ci --silent || npm install --silent
    
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

# CORRECCIÓN 3: Mejorar verificación de disponibilidad de EC2
check_ec2_availability() {
  if [ "$SKIP_SSH_VERIFY" = true ]; then
    echo -e "${YELLOW}⚠️ Omitiendo verificación de disponibilidad EC2${NC}"
    return 0
  fi
  
  echo -e "${YELLOW}Esperando que la instancia EC2 esté disponible...${NC}"
  for ((i=1; i<=MAX_SSH_ATTEMPTS; i++)); do
    echo -e "${YELLOW}Intento $i de $MAX_SSH_ATTEMPTS...${NC}"
    
    # Primero verificamos conectividad básica con timeout corto
    if nc -zv -w 5 "$BACKEND_IP" 22 &>/dev/null; then
      echo -e "${YELLOW}Puerto SSH abierto, intentando conexión completa...${NC}"
      
      # Intentamos una conexión SSH real con verificación de comando
      if ssh -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=no -i "$SSH_KEY_PATH" ubuntu@"$BACKEND_IP" 'echo "Conexión SSH establecida"' &>/dev/null; then
        echo -e "${GREEN}✅ Instancia EC2 disponible y SSH funcionando${NC}"
        return 0
      fi
    fi
    
    echo -e "${YELLOW}La instancia aún no está disponible. Esperando $SSH_RETRY_INTERVAL segundos...${NC}"
    sleep $SSH_RETRY_INTERVAL
  done
  
  echo -e "${RED}Error: La instancia EC2 no está disponible después de $MAX_SSH_ATTEMPTS intentos${NC}"
  
  # Ofrecer la opción de continuar a pesar del error
  echo -e "${YELLOW}¿Desea continuar de todos modos? Esto puede causar errores en el despliegue. (s/n)${NC}"
  read -r response
  if [[ "$response" =~ ^([sS][iI]|[sS])$ ]]; then
    echo -e "${YELLOW}Continuando el despliegue sin verificación SSH...${NC}"
    return 0
  else
    echo -e "${RED}Abortando despliegue.${NC}"
    return 1
  fi
}

# Verificar que la instancia EC2 esté disponible
check_ec2_availability || exit 1

# Ejecutar Ansible
echo -e "${GREEN}=== Configurando servicios con Ansible ===${NC}"
cd "$PROJECT_ROOT/infrastructure/ansible"

if [ -f "inventory/hosts.ini" ]; then
  echo -e "${YELLOW}Ejecutando playbook de Ansible...${NC}"
  export ANSIBLE_HOST_KEY_CHECKING=False
  ansible-playbook -i inventory/hosts.ini playbook.yml
  
  if [ $? -ne 0 ]; then
    echo -e "${RED}Error: La ejecución del playbook de Ansible falló${NC}"
    echo -e "${YELLOW}Revisar logs para más detalles${NC}"
    
    # Ofrecer la opción de continuar a pesar del error
    echo -e "${YELLOW}¿Desea continuar con la verificación de servicios de todos modos? (s/n)${NC}"
    read -r response
    if ! [[ "$response" =~ ^([sS][iI]|[sS])$ ]]; then
      echo -e "${RED}Abortando despliegue.${NC}"
      exit 1
    fi
  else
    echo -e "${GREEN}✅ Configuración de servicios completada exitosamente${NC}"
  fi
else
  echo -e "${RED}Error: No se encontró el archivo de inventario${NC}"
  exit 1
fi

# CORRECCIÓN 4: Mejorar verificación de servicios
check_service_endpoint() {
  local endpoint="$1"
  local service_name="$2"
  local max_attempts=15
  local retry_interval=8
  local timeout=5
  
  echo -e "${YELLOW}Verificando endpoint de $service_name: $endpoint${NC}"
  
  for ((i=1; i<=max_attempts; i++)); do
    echo -e "${YELLOW}Intento $i de $max_attempts...${NC}"
    
    RESPONSE=$(curl -s -m $timeout -w "\n%{http_code}" "$endpoint" 2>/dev/null)
    if [ $? -ne 0 ]; then
      echo -e "${YELLOW}Error de conexión, posiblemente el servicio aún no está accesible${NC}"
    else
      HTTP_CODE=$(echo "$RESPONSE" | tail -n1)
      CONTENT=$(echo "$RESPONSE" | head -n -1)
      
      if [ "$HTTP_CODE" -eq 200 ] || [ "$HTTP_CODE" -eq 201 ] || [ "$HTTP_CODE" -eq 204 ]; then
        echo -e "${GREEN}✅ Servicio de $service_name funcionando (HTTP $HTTP_CODE)${NC}"
        echo -e "${YELLOW}Respuesta: $CONTENT${NC}"
        return 0
      fi
      
      echo -e "${YELLOW}Servicio de $service_name responde con código HTTP ${HTTP_CODE}${NC}"
    fi
    
    echo -e "${YELLOW}Esperando $retry_interval segundos...${NC}"
    sleep $retry_interval
  done
  
  echo -e "${RED}❌ Servicio de $service_name no está respondiendo correctamente${NC}"
  echo -e "${YELLOW}Esto puede ser normal si el servicio no tiene datos iniciales${NC}"
  return 0 # Continuamos a pesar del error
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

# CORRECCIÓN 5: Espera activa para servicios con verificación adicional
echo -e "${YELLOW}Verificando inicialización de servicios...${NC}"
wait_count=0
max_wait=12  # 6 minutos máximo

echo -e "${YELLOW}Esperando 30 segundos para inicialización básica...${NC}"
sleep 30

# Verificar servicios activamente
echo -e "${YELLOW}Verificando disponibilidad de servicios...${NC}"
while [ $wait_count -lt $max_wait ]; do
  wait_count=$((wait_count + 1))
  
  # Intentar verificar que docker está funcionando en la instancia
  if ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 -i "$SSH_KEY_PATH" ubuntu@"$BACKEND_IP" \
     "docker ps | grep -q 'running' && echo 'OK'" 2>/dev/null | grep -q "OK"; then
    echo -e "${GREEN}✅ Servicios Docker iniciados correctamente${NC}"
    break
  fi
  
  echo -e "${YELLOW}Intento $wait_count/$max_wait: Servicios aún iniciando. Esperando 30s más...${NC}"
  sleep 30
done

# Verificar endpoints
if [ -n "$API_URL" ]; then
  echo -e "${YELLOW}Verificando endpoints de la API...${NC}"
  
  check_service_endpoint "${API_URL}/users" "usuarios"
  check_service_endpoint "${API_URL}/products" "productos"
  
  # CORRECCIÓN 6: Mejorar verificación CORS
  echo -e "${YELLOW}Verificando CORS desde frontend a API...${NC}"
  CORS_TEST=$(curl -s -I -X OPTIONS \
    -H "Origin: https://${FRONTEND_URL}" \
    -H "Access-Control-Request-Method: GET" \
    -H "Access-Control-Request-Headers: Content-Type,Authorization" \
    "${API_URL}/users" | grep -i "Access-Control-Allow")

  if [ -n "$CORS_TEST" ]; then
    echo -e "${GREEN}✅ Configuración CORS funcionando correctamente${NC}"
    echo -e "$CORS_TEST"
  else
    echo -e "${RED}⚠️ La configuración CORS puede tener problemas${NC}"
    echo -e "${YELLOW}Probando con entrada de API alternativa...${NC}"
    # Intentar con URL directa al backend como alternativa
    DIRECT_CORS_TEST=$(curl -s -I -X OPTIONS \
      -H "Origin: https://${FRONTEND_URL}" \
      -H "Access-Control-Request-Method: GET" \
      -H "Access-Control-Request-Headers: Content-Type,Authorization" \
      "http://${BACKEND_IP}/users" | grep -i "Access-Control-Allow")
      
    if [ -n "$DIRECT_CORS_TEST" ]; then
      echo -e "${GREEN}✅ CORS funciona directamente con backend${NC}"
      echo -e "${YELLOW}Para solucionar problemas de CORS, considere usar la URL directa: http://${BACKEND_IP}${NC}"
      echo -e "${YELLOW}Ejecute el siguiente comando para actualizar el frontend:${NC}"
      echo -e "cd frontend && echo \"REACT_APP_API_URL=http://${BACKEND_IP}\" > .env.production && npm run build && cd .. && aws s3 sync frontend/build/ s3://${S3_BUCKET}/ --delete && aws cloudfront create-invalidation --distribution-id ${CF_DIST_ID} --paths \"/*\""
    else
      echo -e "${RED}Los problemas CORS persisten. Verifique la configuración:${NC}"
      echo -e "1. Revisar nginx/nginx.conf"
      echo -e "2. Revisar API Gateway en main.tf"
      echo -e "3. Revisar configuración CORS en los servicios Python"
    fi
  fi
fi

echo -e "${GREEN}=== El sistema AppGestion está desplegado y listo para usar ===${NC}"
echo -e "${YELLOW}Para acceder a la aplicación visite: https://${FRONTEND_URL}${NC}"
echo -e "${YELLOW}Para monitorear los servicios: ssh -i ${SSH_KEY_PATH} ubuntu@${BACKEND_IP} 'cd /opt/appgestion && docker-compose ps'${NC}"

# Comandos útiles adicionales
echo -e "${GREEN}=== Comandos útiles para administrar el sistema ===${NC}"
echo -e "${YELLOW}Ver logs de servicios:${NC}"
echo -e "ssh -i ${SSH_KEY_PATH} ubuntu@${BACKEND_IP} 'cd /opt/appgestion && docker-compose logs user-service'"
echo -e "ssh -i ${SSH_KEY_PATH} ubuntu@${BACKEND_IP} 'cd /opt/appgestion && docker-compose logs product-service'"
echo -e "ssh -i ${SSH_KEY_PATH} ubuntu@${BACKEND_IP} 'cd /opt/appgestion && docker-compose logs nginx'"

echo -e "${YELLOW}Reiniciar servicios:${NC}"
echo -e "ssh -i ${SSH_KEY_PATH} ubuntu@${BACKEND_IP} 'cd /opt/appgestion && docker-compose restart'"

echo -e "${YELLOW}Eliminar recursos cuando ya no sean necesarios:${NC}"
echo -e "cd infrastructure/terraform && terraform destroy -auto-approve"