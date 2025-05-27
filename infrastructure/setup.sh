#!/bin/bash
# setup.sh - Aprovisionamiento manual para User Service y Product Service en EC2
# Ejecutar como ubuntu: bash setup.sh [user|product]

set -e

if [ "$EUID" -ne 0 ]; then
  echo "Por favor ejecuta como root: sudo bash setup.sh [user|product]"
  exit 1
fi

SERVICE="$1"
if [ "$SERVICE" != "user" ] && [ "$SERVICE" != "product" ]; then
  echo "Uso: sudo bash setup.sh [user|product]"
  exit 1
fi

echo "==== Instalando dependencias base ===="
apt-get update
apt-get install -y docker.io awscli curl jq netcat-openbsd

systemctl enable docker
systemctl start docker
usermod -aG docker ubuntu

# Esperar a que Docker esté activo
sleep 3

# Cargar variables desde .env si existe, si no, crearlas
if [ "$SERVICE" = "user" ]; then
  SERVICE_NAME="user-service"
  IMAGE_TAG="appgestion-user-service:latest"
  PORT=3001
  DB_HOST_VAR="${POSTGRES_HOST:-REEMPLAZA_HOST_USER}"
  DB_USER_VAR="${POSTGRES_USER:-dbadmin}"
  DB_PASS_VAR="${POSTGRES_PASSWORD:-placeholder_password}"
  DB_NAME_VAR="${POSTGRES_DB:-user_db}"
elif [ "$SERVICE" = "product" ]; then
  SERVICE_NAME="product-service"
  IMAGE_TAG="appgestion-product-service:latest"
  PORT=3002
  DB_HOST_VAR="${POSTGRES_HOST:-REEMPLAZA_HOST_PRODUCT}"
  DB_USER_VAR="${POSTGRES_USER:-dbadmin}"
  DB_PASS_VAR="${POSTGRES_PASSWORD:-placeholder_password}"
  DB_NAME_VAR="${POSTGRES_DB:-product_db}"
fi

# Si existe archivo .env lo respeta, si no, lo crea
if [ ! -f /home/ubuntu/.env ]; then
  cat > /home/ubuntu/.env <<EOL
POSTGRES_HOST=$DB_HOST_VAR
POSTGRES_USER=$DB_USER_VAR
POSTGRES_PASSWORD=$DB_PASS_VAR
POSTGRES_DB=$DB_NAME_VAR
POSTGRES_PORT=5432
PORT=$PORT
DB_MAX_RETRIES=60
DB_RETRY_INTERVAL=5
EOL
  chmod 600 /home/ubuntu/.env
  chown ubuntu:ubuntu /home/ubuntu/.env
fi

# Autenticación DockerHub (opcional)
# docker login -u TU_USUARIO -p TU_TOKEN

echo "==== Quitando contenedor previo (si existe) ===="
docker rm -f $SERVICE_NAME || true

echo "==== Limpiando imagen previa (si existe) ===="
docker rmi $IMAGE_TAG || true

echo "==== Descargando imagen desde DockerHub (usa variable DOCKERHUB_USERNAME) ===="
DOCKERHUB_USERNAME=${DOCKERHUB_USERNAME:-michse017}
docker pull $DOCKERHUB_USERNAME/$IMAGE_TAG

echo "==== Lanzando contenedor $SERVICE_NAME ===="
docker run -d --name $SERVICE_NAME \
  --env-file /home/ubuntu/.env \
  -p $PORT:$PORT \
  --restart unless-stopped \
  $DOCKERHUB_USERNAME/$IMAGE_TAG

echo "==== Diagnóstico ===="
docker ps -a
docker logs $SERVICE_NAME --tail 30

echo "==== Script terminado ===="