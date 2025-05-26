#!/bin/bash
# Script para esperar a que PostgreSQL esté disponible

set -e

host="$1"
port="$2"
user="$3"
db="$4"
password="$5"
max_retries=30

echo "Esperando a que PostgreSQL esté disponible en $host:$port..."
export PGPASSWORD="$password"

for i in $(seq 1 $max_retries); do
    echo "Intento $i/$max_retries"
    if psql -h "$host" -p "$port" -U "$user" -d "$db" -c '\q' > /dev/null 2>&1; then
        echo "PostgreSQL está disponible"
        exit 0
    fi
    echo "PostgreSQL no disponible aún, esperando 5 segundos..."
    sleep 5
done

echo "Error: No se pudo conectar a PostgreSQL después de $max_retries intentos"
exit 1