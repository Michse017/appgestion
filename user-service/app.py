import os
import time
import logging
from datetime import datetime
from flask import Flask, request, jsonify
from flask_sqlalchemy import SQLAlchemy
from flask_cors import CORS
from werkzeug.security import generate_password_hash, check_password_hash

# Configuración de logging mejorada
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s [%(levelname)s] %(message)s',
)
logger = logging.getLogger(__name__)

app = Flask(__name__)
logger.info("Iniciando User Service")

# Configuración CORS - Fundamental para API Gateway
CORS(app, resources={r"/*": {"origins": "*"}})

# Obtener variables de entorno con valores por defecto
db_user = os.environ.get("POSTGRES_USER", "dbadmin")
db_password = os.environ.get("POSTGRES_PASSWORD", "placeholder_password")
db_host = os.environ.get("POSTGRES_HOST", "localhost")
db_port = os.environ.get("POSTGRES_PORT", "5432")
db_name = os.environ.get("POSTGRES_DB", "user_db")

# Log de la configuración para diagnóstico
logger.info(f"Configuración DB: host={db_host}, port={db_port}, db={db_name}, user={db_user}")

# Conexión a la base de datos
db_uri = f"postgresql://{db_user}:{db_password}@{db_host}:{db_port}/{db_name}"
app.config['SQLALCHEMY_DATABASE_URI'] = db_uri
app.config['SQLALCHEMY_TRACK_MODIFICATIONS'] = False

db = SQLAlchemy(app)

# Modelo de Usuario
class User(db.Model):
    id = db.Column(db.Integer, primary_key=True)
    name = db.Column(db.String(100), nullable=False)
    email = db.Column(db.String(120), unique=True, nullable=False)
    password_hash = db.Column(db.String(256), nullable=False)
    created_at = db.Column(db.DateTime, default=datetime.utcnow)
    updated_at = db.Column(db.DateTime, default=datetime.utcnow, onupdate=datetime.utcnow)
    
    def to_dict(self):
        return {
            'id': self.id,
            'name': self.name,
            'email': self.email,
            'created_at': self.created_at.isoformat() if self.created_at else None
        }

# Endpoint principal para verificar que el servicio esté en funcionamiento
@app.route('/', methods=['GET'])
def index():
    return jsonify({"status": "running", "service": "user-service"}), 200

# Endpoint específico para ALB health checks - CRÍTICO
@app.route('/health', methods=['GET'])
def alb_health_check():
    return jsonify({"status": "healthy", "service": "user-service"}), 200

# Endpoint específico para API Gateway health checks - CRÍTICO
@app.route('/users/health', methods=['GET'])
def api_health_check():
    try:
        # Verificar conexión a la BD
        db.session.execute(db.text('SELECT 1'))
        return jsonify({"status": "healthy", "service": "user-service", "database": "connected"}), 200
    except Exception as e:
        logger.error(f"Health check error: {e}")
        # Incluso con error de BD, respondemos 200 para ALB (diagnóstico)
        return jsonify({"status": "unhealthy", "error": str(e)}), 200

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
    try:
        user = User.query.get(user_id)
        if not user:
            return jsonify({"error": "Usuario no encontrado"}), 404
        return jsonify(user.to_dict())
    except Exception as e:
        logger.error(f"Error al obtener usuario {user_id}: {e}")
        return jsonify({"error": f"Error al obtener usuario {user_id}"}), 500

# POST - Crear nuevo usuario
@app.route('/users', methods=['POST'])
def create_user():
    try:
        data = request.get_json()
        if not data:
            return jsonify({"error": "Datos inválidos"}), 400
            
        required = ['name', 'email', 'password']
        if not all(field in data for field in required):
            return jsonify({"error": "Faltan campos requeridos (name, email, password)"}), 400
            
        if User.query.filter_by(email=data['email']).first():
            return jsonify({"error": f"Email {data['email']} ya registrado"}), 409
            
        new_user = User(
            name=data['name'],
            email=data['email'],
            password_hash=generate_password_hash(data['password'])
        )
        
        db.session.add(new_user)
        db.session.commit()
        
        return jsonify({
            "message": "Usuario creado exitosamente",
            "user": new_user.to_dict()
        }), 201
        
    except Exception as e:
        db.session.rollback()
        logger.error(f"Error al crear usuario: {e}")
        return jsonify({"error": "Error al crear usuario"}), 500

# Función para inicializar la base de datos con reintentos
def setup_database():
    max_attempts = int(os.environ.get("DB_MAX_RETRIES", "30"))
    retry_interval = int(os.environ.get("DB_RETRY_INTERVAL", "5"))
    
    logger.info(f"Intentando conectar a la base de datos (máx {max_attempts} intentos)")
    
    for attempt in range(max_attempts):
        try:
            db.create_all()
            logger.info("Tablas creadas correctamente")
            
            # Crear usuario de prueba si no existe ninguno
            if User.query.count() == 0:
                logger.info("Creando usuario de prueba inicial")
                test_user = User(
                    name="Admin",
                    email="admin@example.com",
                    password_hash=generate_password_hash("admin123")
                )
                db.session.add(test_user)
                db.session.commit()
                logger.info("Usuario de prueba creado")
            
            logger.info("Base de datos inicializada correctamente")
            return True
        except Exception as e:
            if attempt < max_attempts - 1:
                logger.warning(f"Intento {attempt+1}/{max_attempts} falló: {e}")
                logger.info(f"Reintentando en {retry_interval} segundos...")
                time.sleep(retry_interval)
            else:
                logger.error(f"No se pudo conectar a la base de datos después de {max_attempts} intentos")
                # No hacemos exit para permitir que la app inicie igual
                # y responda a health checks aunque la BD no esté disponible
    return False

# Inicializar la base de datos al inicio
setup_database()

# Para ser ejecutado por Gunicorn
if __name__ == '__main__':
    port = int(os.environ.get("PORT", "3001"))
    logger.info(f"Iniciando servicio en puerto {port}")
    app.run(host='0.0.0.0', port=port)