#!/bin/bash
# deploy.sh - Script mejorado para desplegar la infraestructura y servicios end-to-end

set -e

GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
NC='\033[0m'

PROJECT_ROOT=$(dirname "$(realpath "$0")")/..
TERRAFORM_DIR="$PROJECT_ROOT/infrastructure/terraform"
MY_PUBLIC_IP=$(curl -s https://api.ipify.org)

echo -e "${GREEN}=== Desplegando AppGestion ===${NC}"

for cmd in terraform aws docker npm; do
  if ! command -v $cmd &> /dev/null; then
    echo -e "${RED}Error: $cmd no está instalado${NC}"
    exit 1
  fi
done

echo -e "${YELLOW}Verificando terraform.tfvars...${NC}"
if ! grep -q "db_username" "$TERRAFORM_DIR/terraform.tfvars"; then
  echo -e "${RED}Error: terraform.tfvars no está correctamente configurado${NC}"
  exit 1
fi

SSH_KEY_NAME=$(grep ssh_key_name "$TERRAFORM_DIR/terraform.tfvars" | cut -d '"' -f2)
if ! aws ec2 describe-key-pairs --key-name "$SSH_KEY_NAME" &>/dev/null; then
  echo -e "${RED}Error: La clave SSH '$SSH_KEY_NAME' no existe en AWS${NC}"
  exit 1
fi

# Añadir validación de variables antes de desplegar
SSH_KEY_NAME=$(grep ssh_key_name "$TERRAFORM_DIR/terraform.tfvars" | cut -d '"' -f2)
if ! aws ec2 describe-key-pairs --key-name "$SSH_KEY_NAME" &>/dev/null; then
  echo -e "${RED}Error: La clave SSH '$SSH_KEY_NAME' no existe en AWS${NC}"
  exit 1
fi

echo -e "${YELLOW}¿Desea construir y publicar imágenes Docker? (s/n)${NC}"
read -r response

if [[ "$response" =~ ^([sS][iI]|[sS])$ ]]; then
  echo -e "${YELLOW}Construyendo y publicando imágenes Docker...${NC}"
  bash "$PROJECT_ROOT/infrastructure/build_images.sh" || exit 1
fi

cd "$TERRAFORM_DIR"
echo -e "${YELLOW}Agregando IP para acceso remoto seguro: $MY_PUBLIC_IP${NC}"
if grep -q "allowed_ssh_ip" terraform.tfvars; then
  sed -i "s/allowed_ssh_ip = .*/allowed_ssh_ip = \"$MY_PUBLIC_IP\/32\"/" terraform.tfvars
else
  echo "allowed_ssh_ip = \"$MY_PUBLIC_IP/32\"" >> terraform.tfvars
fi

echo -e "${YELLOW}Inicializando y desplegando infraestructura...${NC}"
terraform init
terraform validate || exit 1
terraform apply -auto-approve || exit 1

echo -e "${GREEN}=== Obteniendo datos de salida ===${NC}"
API_URL=$(terraform output -raw api_gateway_invoke_url)
FRONTEND_URL=$(terraform output -raw frontend_cloudfront_domain)
S3_BUCKET=$(terraform output -raw frontend_bucket_name)

PROJECT_NAME=$(grep project_name "$TERRAFORM_DIR/terraform.tfvars" | cut -d '"' -f2)
USER_SERVICE_IP=$(aws ec2 describe-instances --filters "Name=tag:Name,Values=$PROJECT_NAME-user-service" --query "Reservations[0].Instances[0].PublicIpAddress" --output text)
PRODUCT_SERVICE_IP=$(aws ec2 describe-instances --filters "Name=tag:Name,Values=$PROJECT_NAME-product-service" --query "Reservations[0].Instances[0].PublicIpAddress" --output text)

cd "$PROJECT_ROOT/frontend"
echo "REACT_APP_API_URL=${API_URL}" > .env.production
echo -e "${YELLOW}Reconstruyendo frontend con API URL: ${API_URL}${NC}"
npm install && npm run build || exit 1

aws s3 sync build/ "s3://$S3_BUCKET/" --delete
DISTRIBUTION_ID=$(aws cloudfront list-distributions --query "DistributionList.Items[?contains(DomainName,'${FRONTEND_URL}')].Id" --output text)
if [ -n "$DISTRIBUTION_ID" ]; then
  aws cloudfront create-invalidation --distribution-id $DISTRIBUTION_ID --paths "/*"
fi

echo -e "${YELLOW}Esperando 5 minutos para que los recursos se inicialicen...${NC}"
echo -e "${YELLOW}Mientras tanto, aquí están las direcciones IP de los servidores:${NC}"
echo -e "User Service: ${USER_SERVICE_IP}"
echo -e "Product Service: ${PRODUCT_SERVICE_IP}"
echo -e "${YELLOW}Puedes conectarte usando: ssh -i ~/ruta/a/tu-clave.pem ubuntu@IP${NC}"

sleep 300

echo -e "${YELLOW}Verificando despliegue...${NC}"
if [ ! -f "$PROJECT_ROOT/infrastructure/verify_deployment.sh" ]; then
  echo -e "${RED}Error: Script de verificación no encontrado${NC}"
  echo -e "${RED}Ruta buscada: $PROJECT_ROOT/infrastructure/verify_deployment.sh${NC}"
  echo -e "${RED}Directorio actual: $(pwd)${NC}"
  exit 1
fi

chmod +x "$PROJECT_ROOT/infrastructure/verify_deployment.sh"
echo -e "${YELLOW}Ejecutando: $PROJECT_ROOT/infrastructure/verify_deployment.sh${NC}"
bash "$PROJECT_ROOT/infrastructure/verify_deployment.sh" || {
  echo -e "${RED}Error ejecutando script de verificación${NC}"
}

echo -e "${GREEN}=== Despliegue completado ===${NC}"
echo -e "Frontend: https://${FRONTEND_URL}"
echo -e "API Gateway: ${API_URL}"
echo -e "${YELLOW}Importante: Los servicios pueden tardar ~5-10 minutos en estar completamente disponibles${NC}"
echo -e "${YELLOW}Para verificar el estado de los servicios, conéctate por SSH a los servidores y ejecuta:${NC}"
echo -e "  sudo docker ps"
echo -e "  sudo docker logs user-service"
echo -e "  sudo docker logs product-service"
echo -e "  bash /home/ubuntu/diagnose.sh"
echo -e "${YELLOW}Para eliminar recursos: cd $TERRAFORM_DIR && terraform destroy -auto-approve${NC}"
