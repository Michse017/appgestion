#!/bin/bash
# verify_deployment.sh - Verifica el despliegue completo

set -e
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${YELLOW}=== Verificando despliegue de AppGestion ===${NC}"

# Obtener outputs de Terraform
cd infrastructure/terraform
API_URL=$(terraform output -raw api_gateway_invoke_url)
FRONTEND_URL=$(terraform output -raw frontend_cloudfront_domain)
USER_ALB=$(terraform output -raw user_service_endpoint)
PRODUCT_ALB=$(terraform output -raw product_service_endpoint)
USER_DB=$(terraform output -raw user_db_endpoint)
PRODUCT_DB=$(terraform output -raw product_db_endpoint)

echo -e "${YELLOW}Verificando bases de datos...${NC}"
# Obtener credenciales de BD de terraform.tfvars
DB_USER=$(grep db_username terraform.tfvars | cut -d '"' -f2)
DB_PASS=$(grep db_password terraform.tfvars | cut -d '"' -f2)

echo "Probando conexión a User DB..."
PGPASSWORD=$DB_PASS psql -h ${USER_DB%:*} -p ${USER_DB#*:} -U $DB_USER -d user_db -c "SELECT count(*) FROM users;" || {
  echo -e "${RED}Error conectando a User DB${NC}"
}

echo "Probando conexión a Product DB..."
PGPASSWORD=$DB_PASS psql -h ${PRODUCT_DB%:*} -p ${PRODUCT_DB#*:} -U $DB_USER -d product_db -c "SELECT count(*) FROM products;" || {
  echo -e "${RED}Error conectando a Product DB${NC}"
}

echo -e "${YELLOW}Verificando servicios en ALB...${NC}"
echo "User Service Health Check:"
curl -v http://$USER_ALB/health || echo -e "${RED}Error accediendo al User Service${NC}"

echo "Product Service Health Check:"
curl -v http://$PRODUCT_ALB/health || echo -e "${RED}Error accediendo al Product Service${NC}"

echo -e "${YELLOW}Verificando API Gateway...${NC}"
echo "User API Health Check:"
curl -v ${API_URL}users/health || echo -e "${RED}Error accediendo a la API de Users${NC}"

echo "Product API Health Check:"
curl -v ${API_URL}products/health || echo -e "${RED}Error accediendo a la API de Products${NC}"

echo -e "${YELLOW}Probando Frontend URL...${NC}"
curl -I https://$FRONTEND_URL || echo -e "${RED}Error accediendo al Frontend${NC}"

echo -e "${GREEN}=== Verificación completa ===${NC}"