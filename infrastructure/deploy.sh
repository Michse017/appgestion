#!/bin/bash
# deploy.sh - Script simplificado para desplegar la infraestructura

set -e

# Colores para mensajes
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
NC='\033[0m'

# Directorio raíz y variables
PROJECT_ROOT=$(dirname "$(realpath "$0")")/..
TERRAFORM_DIR="$PROJECT_ROOT/infrastructure/terraform"
MY_PUBLIC_IP=$(curl -s https://api.ipify.org)

echo -e "${GREEN}=== Desplegando AppGestion ===${NC}"

# Verificar herramientas básicas
for cmd in terraform aws docker npm; do
  if ! command -v $cmd &> /dev/null; then
    echo -e "${RED}Error: $cmd no está instalado${NC}"
    exit 1
  fi
done

# Construir imágenes Docker si se solicita
echo -e "${YELLOW}¿Construir imágenes Docker? (s/n)${NC}"
read -r response
if [[ "$response" =~ ^([sS][iI]|[sS])$ ]]; then
  bash "$PROJECT_ROOT/infrastructure/build_images.sh" || exit 1
fi

# Ejecutar Terraform
cd "$TERRAFORM_DIR"
echo -e "${YELLOW}Agregando IP para acceso remoto seguro: $MY_PUBLIC_IP${NC}"
echo "allowed_ssh_ip = \"$MY_PUBLIC_IP/32\"" >> terraform.tfvars

echo -e "${YELLOW}Inicializando y desplegando infraestructura...${NC}"
terraform init
terraform validate || exit 1
terraform apply -auto-approve || exit 1

# Obtener información importante
echo -e "${GREEN}=== Obteniendo datos de salida ===${NC}"
API_URL=$(terraform output -raw api_gateway_invoke_url)
FRONTEND_URL=$(terraform output -raw frontend_cloudfront_domain)
S3_BUCKET=$(terraform output -raw frontend_bucket_name)

# Actualizar frontend con URL real de API
cd "$PROJECT_ROOT/frontend"
echo "REACT_APP_API_URL=${API_URL}" > .env.production
echo -e "${YELLOW}Reconstruyendo frontend con API URL: ${API_URL}${NC}"
npm install && npm run build || exit 1

# Desplegar frontend a S3 y invalidar caché
aws s3 sync build/ "s3://$S3_BUCKET/" --delete
DISTRIBUTION_ID=$(aws cloudfront list-distributions --query "DistributionList.Items[?contains(DomainName,'${FRONTEND_URL}')].Id" --output text)
if [ -n "$DISTRIBUTION_ID" ]; then
  aws cloudfront create-invalidation --distribution-id $DISTRIBUTION_ID --paths "/*"
fi

# Mostrar información de acceso
echo -e "${GREEN}=== Despliegue completado ===${NC}"
echo -e "Frontend: https://${FRONTEND_URL}"
echo -e "API Gateway: ${API_URL}"
echo -e "${YELLOW}Importante: Los servicios pueden tardar ~5-10 minutos en estar completamente disponibles${NC}"
echo -e "${YELLOW}Para eliminar recursos: cd $TERRAFORM_DIR && terraform destroy -auto-approve${NC}"