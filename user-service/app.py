import os
import time
import logging
from flask import Flask, request, jsonify
from flask_sqlalchemy import SQLAlchemy
from flask_cors import CORS
import sqlalchemy.exc

app = Flask(__name__)

# Configuración de timeout para operaciones largas
service_timeout = int(os.environ.get("SERVICE_TIMEOUT", "60"))

# Configuración de profiling para desarrollo
enable_profiling = os.environ.get("ENABLE_PROFILING", "false").lower() == "true"

# Ajustar configuración de logging según entorno
if os.environ.get("ENVIRONMENT") == "production":
    logging.basicConfig(
        level=logging.INFO,
        format='%(asctime)s - %(name)s - %(levelname)s - [%(process)d] - %(message)s'
    )
else:
    logging.basicConfig(
        level=logging.DEBUG if os.environ.get("LOG_LEVEL", "").upper() == "DEBUG" else logging.INFO,
        format='%(asctime)s - %(name)s - %(levelname)s - %(message)s'
    )
logger = logging.getLogger(__name__)

# Configuración de CORS
cors_origins = os.environ.get('CORS_ALLOWED_ORIGINS', '*')
CORS(app, origins=[cors_origins], supports_credentials=True)

# Configuración de base de datos desde variables de entorno
db_user = os.environ.get("POSTGRES_USER", "dbadmin")
db_password = os.environ.get("POSTGRES_PASSWORD", "contraseña_segura")
db_host = os.environ.get("POSTGRES_HOST", "localhost")
db_name = os.environ.get("POSTGRES_DB", "user_db")
db_port = os.environ.get("POSTGRES_PORT", "5432")

# Configuración de reintentos de conexión
max_retries = int(os.environ.get("DB_MAX_RETRIES", "30"))
retry_interval = int(os.environ.get("DB_RETRY_INTERVAL", "5"))

app.config['SQLALCHEMY_DATABASE_URI'] = f'postgresql://{db_user}:{db_password}@{db_host}:{db_port}/{db_name}'
app.config['SQLALCHEMY_TRACK_MODIFICATIONS'] = False
app.config['SQLALCHEMY_ENGINE_OPTIONS'] = {
    'pool_recycle': 600,
    'pool_pre_ping': True,
    'pool_timeout': 10,
    'pool_size': 10,
    'max_overflow': 20
}

logger.info(f"Configurando conexión a la base de datos: {db_host}:{db_port}/{db_name}")

db = SQLAlchemy(app)

class User(db.Model):
    id = db.Column(db.Integer, primary_key=True)
    name = db.Column(db.String(100), nullable=False)
    email = db.Column(db.String(120), unique=True, nullable=False)
    created_at = db.Column(db.DateTime, server_default=db.func.now())
    updated_at = db.Column(db.DateTime, server_default=db.func.now(), onupdate=db.func.now())
    
    def __repr__(self):
        return f'<User {self.name}>'
    
    def to_dict(self):
        return {
            'id': self.id,
            'name': self.name,
            'email': self.email,
            'created_at': self.created_at.isoformat() if self.created_at else None,
            'updated_at': self.updated_at.isoformat() if self.updated_at else None
        }

# Función para inicializar la base de datos con reintentos
def initialize_database():
    for attempt in range(1, max_retries + 1):
        try:
            logger.info(f"Intento {attempt} de {max_retries} para conectar a la base de datos")
            with app.app_context():
                db.create_all()
                # Crear usuario de prueba si no existe
                if User.query.count() == 0:
                    test_user = User(name="Usuario Prueba", email="usuario@ejemplo.com")
                    db.session.add(test_user)
                    db.session.commit()
                    logger.info("Usuario de prueba creado")
                logger.info("Tablas creadas/verificadas correctamente")
                return True
        except sqlalchemy.exc.OperationalError as e:
            logger.warning(f"No se pudo conectar a la base de datos: {str(e)}")
            if attempt < max_retries:
                logger.info(f"Reintentando en {retry_interval} segundos...")
                time.sleep(retry_interval)
            else:
                logger.error("Se agotó el número máximo de intentos. No se pudo conectar a la base de datos.")
                return False
        except Exception as e:
            logger.error(f"Error inicializando base de datos: {str(e)}")
            return False

# Endpoint de health check mejorado
@app.route('/health', methods=['GET'])
def health():
    try:
        # Verificar conexión a la BD
        result = db.session.execute(db.text('SELECT 1 as test'))
        db.session.commit()
        return jsonify({
            "status": "healthy", 
            "database": "connected",
            "service": "user-service",
            "version": os.environ.get('DEPLOYMENT_VERSION', '1.0.0'),
            "timestamp": time.time()
        })
    except Exception as e:
        logger.error(f"Health check failed: {str(e)}")
        return jsonify({
            "error": str(e), 
            "status": "unhealthy", 
            "database": "disconnected",
            "service": "user-service",
            "timestamp": time.time()
        }), 500

@app.route('/users', methods=['GET'])
def get_users():
    try:
        users = User.query.all()
        return jsonify([user.to_dict() for user in users])
    except Exception as e:
        logger.error(f"Error getting users: {str(e)}")
        return jsonify({"error": str(e)}), 500

@app.route('/users/<int:user_id>', methods=['GET'])
def get_user(user_id):
    try:
        user = User.query.get(user_id)
        if user:
            return jsonify(user.to_dict())
        return jsonify({"error": "User not found"}), 404
    except Exception as e:
        logger.error(f"Error getting user {user_id}: {str(e)}")
        return jsonify({"error": str(e)}), 500

@app.route('/users', methods=['POST'])
def create_user():
    try:
        data = request.get_json()
        if not data or not 'name' in data or not 'email' in data:
            return jsonify({"error": "Missing required fields"}), 400
        
        # Verificar si el email ya existe
        existing_user = User.query.filter_by(email=data['email']).first()
        if existing_user:
            return jsonify({"error": "Email already exists"}), 409
            
        user = User(name=data['name'], email=data['email'])
        db.session.add(user)
        db.session.commit()
        
        return jsonify({
            "id": user.id, 
            "message": "User created successfully",
            "user": user.to_dict()
        }), 201
    except Exception as e:
        db.session.rollback()
        logger.error(f"Error creating user: {str(e)}")
        return jsonify({"error": str(e)}), 500

@app.route('/users/<int:user_id>', methods=['PUT'])
def update_user(user_id):
    try:
        user = User.query.get(user_id)
        if not user:
            return jsonify({"error": "User not found"}), 404
            
        data = request.get_json()
        if 'name' in data:
            user.name = data['name']
        if 'email' in data:
            # Verificar que el nuevo email no exista ya
            if data['email'] != user.email and User.query.filter_by(email=data['email']).first():
                return jsonify({"error": "Email already exists"}), 409
            user.email = data['email']
            
        db.session.commit()
        return jsonify({
            "message": "User updated successfully",
            "user": user.to_dict()
        })
    except Exception as e:
        db.session.rollback()
        logger.error(f"Error updating user {user_id}: {str(e)}")
        return jsonify({"error": str(e)}), 500

@app.route('/users/<int:user_id>', methods=['DELETE'])
def delete_user(user_id):
    try:
        user = User.query.get(user_id)
        if not user:
            return jsonify({"error": "User not found"}), 404
            
        db.session.delete(user)
        db.session.commit()
        return jsonify({"message": "User deleted successfully"})
    except Exception as e:
        db.session.rollback()
        logger.error(f"Error deleting user {user_id}: {str(e)}")
        return jsonify({"error": str(e)}), 500

if __name__ == '__main__':
    # Inicializar la base de datos antes de iniciar el servicio
    if initialize_database():
        app.run(host='0.0.0.0', port=3001, debug=os.environ.get('ENVIRONMENT') == 'development')
    else:
        logger.critical("No se pudo inicializar la base de datos. El servicio no se iniciará.")
        exit(1)