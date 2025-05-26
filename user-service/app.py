import os
import time
import logging
from datetime import datetime
from flask import Flask, request, jsonify
from flask_sqlalchemy import SQLAlchemy
from flask_cors import CORS
import sqlalchemy.exc
from werkzeug.security import generate_password_hash, check_password_hash

# Configuración inicial de la aplicación Flask
app = Flask(__name__)

# Configuración de logging
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s'
)
logger = logging.getLogger(__name__)

# Configuración CORS - Adaptar según configuración API Gateway
CORS(app, resources={r"/*": {"origins": "*"}})

# Configuración de la base de datos
db_user = os.environ.get("POSTGRES_USER", "dbadmin")
db_password = os.environ.get("POSTGRES_PASSWORD", "placeholder_password")
db_host = os.environ.get("POSTGRES_HOST", "localhost")
db_port = os.environ.get("POSTGRES_PORT", "5432")
db_name = os.environ.get("POSTGRES_DB", "user_db")

# Registrar valores para diagnóstico
logger.info(f"User Service - Parámetros de conexión DB: host={db_host}, port={db_port}, db={db_name}, user={db_user}")

# IMPORTANTE: Forzar explícitamente conexión TCP/IP en vez de socket Unix
# La forma correcta de conectarse a RDS desde EC2
connection_uri = f"postgresql://{db_user}:{db_password}@{db_host}:{db_port}/{db_name}"
logger.info(f"User Service - URI de conexión: {connection_uri.replace(db_password, '******')}")

app.config['SQLALCHEMY_DATABASE_URI'] = connection_uri
app.config['SQLALCHEMY_TRACK_MODIFICATIONS'] = False
app.config['SQLALCHEMY_ENGINE_OPTIONS'] = {
    'pool_pre_ping': True,  # Verificar conexión antes de usarla
    'pool_recycle': 1800,   # Reciclar conexiones cada 30 min
    'pool_timeout': 30,     # Timeout de conexión
    'connect_args': {
        'options': f'-c search_path=public -c statement_timeout=60000'  # Opciones adicionales para psycopg2
    }
}

db = SQLAlchemy(app)

# Modelo de Usuario - Asegurar coherencia con frontend (App.js)
class User(db.Model):
    id = db.Column(db.Integer, primary_key=True)
    name = db.Column(db.String(100), nullable=False)
    email = db.Column(db.String(120), unique=True, nullable=False)
    password_hash = db.Column(db.String(256), nullable=False)
    created_at = db.Column(db.DateTime, default=datetime.utcnow)
    updated_at = db.Column(db.DateTime, default=datetime.utcnow, onupdate=datetime.utcnow)
    
    def to_dict(self):
        """Convertir a diccionario (formato esperado por frontend)"""
        return {
            'id': self.id,
            'name': self.name,
            'email': self.email,
            'created_at': self.created_at.isoformat() if self.created_at else None
        }

# Endpoint de health check para ALB y API Gateway
@app.route('/users/health', methods=['GET'])
@app.route('/health', methods=['GET'])
def health_check():
    try:
        # Verificar conexión a la BD
        db.session.execute(db.text('SELECT 1'))
        return jsonify({"status": "healthy", "service": "user-service"}), 200
    except Exception as e:
        logger.error(f"Health check failed: {str(e)}")
        return jsonify({"status": "unhealthy", "error": str(e)}), 500

# GET - Lista de todos los usuarios
@app.route('/users', methods=['GET'])
def get_users():
    try:
        users = User.query.all()
        return jsonify([user.to_dict() for user in users])
    except Exception as e:
        logger.error(f"Error al obtener usuarios: {e}")
        return jsonify({"error": "Error al obtener usuarios"}), 500

# GET - Detalles de un usuario específico por ID
@app.route('/users/<int:user_id>', methods=['GET'])
def get_user(user_id):
    user = User.query.get(user_id)
    if not user:
        return jsonify({"error": "Usuario no encontrado"}), 404
    return jsonify(user.to_dict())

# POST - Crear nuevo usuario (adaptado al formato del frontend)
@app.route('/users', methods=['POST'])
def create_user():
    try:
        data = request.get_json()
        if not data:
            return jsonify({"error": "Datos inválidos"}), 400
            
        # Validar campos requeridos que coinciden con frontend
        required = ['name', 'email', 'password']
        if not all(field in data for field in required):
            return jsonify({"error": "Faltan campos requeridos (name, email, password)"}), 400
            
        # Verificar email único
        if User.query.filter_by(email=data['email']).first():
            return jsonify({"error": f"Email {data['email']} ya registrado"}), 409
            
        # Crear nuevo usuario
        new_user = User(
            name=data['name'],
            email=data['email'],
            password_hash=generate_password_hash(data['password'])
        )
        
        db.session.add(new_user)
        db.session.commit()
        
        # Formato de respuesta que espera el frontend
        return jsonify({
            "message": "Usuario creado exitosamente",
            "user": new_user.to_dict()
        }), 201
        
    except Exception as e:
        db.session.rollback()
        logger.error(f"Error al crear usuario: {e}")
        return jsonify({"error": "Error al crear usuario"}), 500

# Inicialización de la base de datos con reintentos
def initialize_database():
    max_retries = int(os.environ.get("DB_MAX_RETRIES", "30"))
    retry_interval = int(os.environ.get("DB_RETRY_INTERVAL", "5"))
    
    # Prueba de conexión directa con psycopg2 antes de usar SQLAlchemy
    for i in range(max_retries):
        try:
            logger.info(f"User Service - Intento directo con psycopg2 ({i+1}/{max_retries})...")
            import psycopg2
            conn = psycopg2.connect(
                host=db_host,
                port=int(db_port),
                dbname=db_name,
                user=db_user,
                password=db_password
            )
            cursor = conn.cursor()
            cursor.execute("SELECT VERSION()")
            version = cursor.fetchone()
            logger.info(f"User Service - Conexión psycopg2 exitosa: {version[0]}")
            cursor.close()
            conn.close()
            break
        except Exception as e:
            logger.warning(f"User Service - Intento {i+1} directo psycopg2 falló: {e}")
            if i < max_retries - 1:
                logger.info(f"User Service - Reintentando en {retry_interval} segundos...")
                time.sleep(retry_interval)
            else:
                logger.error(f"User Service - No se pudo conectar directamente con psycopg2 después de {max_retries} intentos")
    
    # Intentar crear tablas con SQLAlchemy
    for i in range(max_retries):
        try:
            logger.info(f"User Service - Creando tablas ({i+1}/{max_retries})...")
            db.create_all()
            
            # Crear usuario de prueba si la BD está vacía
            if User.query.count() == 0:
                test_user = User(
                    name="Usuario de Prueba",
                    email="test@example.com",
                    password_hash=generate_password_hash("password123")
                )
                db.session.add(test_user)
                db.session.commit()
                logger.info("User Service - Usuario de prueba creado")
                
            logger.info("User Service - Conexión exitosa a la base de datos y tablas creadas")
            return True
            
        except Exception as e:
            logger.warning(f"User Service - Error al crear tablas: {e}")
            if i < max_retries - 1:
                logger.info(f"User Service - Reintentando en {retry_interval} segundos...")
                time.sleep(retry_interval)
    
    logger.error("User Service - No se pudo inicializar la base de datos después de múltiples intentos")
    return False

if __name__ == '__main__':
    if initialize_database():
        port = int(os.environ.get("PORT", "3001"))
        app.run(host='0.0.0.0', port=port)
    else:
        exit(1)