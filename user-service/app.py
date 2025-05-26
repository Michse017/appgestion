import os
import time
import logging
import traceback
from flask import Flask, request, jsonify, redirect
from flask_sqlalchemy import SQLAlchemy
from flask_cors import CORS
import sqlalchemy.exc
from werkzeug.security import generate_password_hash

app = Flask(__name__)

# Configuración de timeout para operaciones largas
service_timeout = int(os.environ.get("SERVICE_TIMEOUT", "60"))

# Configuración avanzada de logging
log_level = os.environ.get("LOG_LEVEL", "INFO").upper()
log_format = '%(asctime)s - %(name)s - %(levelname)s - [%(process)d] - %(message)s' if os.environ.get("ENVIRONMENT") == "production" else '%(asctime)s - %(name)s - %(levelname)s - %(message)s'

logging.basicConfig(
    level=getattr(logging, log_level),
    format=log_format
)
logger = logging.getLogger(__name__)

# Mejorar configuración CORS para asegurar compatibilidad con CloudFront
cors_origins = os.environ.get('CORS_ALLOWED_ORIGINS', '*')
api_gateway_url = os.environ.get('API_GATEWAY_URL', '')

if cors_origins == '*':
    logger.info("Configurando CORS para aceptar cualquier origen (desarrollo)")
    CORS(app, supports_credentials=True)
else:
    # Para producción, permitir también API Gateway como origen
    origins = [origin.strip() for origin in cors_origins.split(',')]
    # Añadir API Gateway si está definida
    if api_gateway_url and api_gateway_url not in origins:
        origins.append(api_gateway_url)
    logger.info(f"Configurando CORS para orígenes específicos: {origins}")
    CORS(app, origins=origins, supports_credentials=True, allow_headers=['Content-Type', 'Authorization', 'X-Requested-With'])

# Configuración de base de datos desde variables de entorno
db_user = os.environ.get("POSTGRES_USER", "dbadmin")
db_password = os.environ.get("POSTGRES_PASSWORD", "contraseña_segura")
db_host = os.environ.get("POSTGRES_HOST", "localhost")
db_name = os.environ.get("POSTGRES_DB", "user_db")
db_port = os.environ.get("POSTGRES_PORT", "5432")

# Configuración de reintentos de conexión
max_retries = int(os.environ.get("DB_MAX_RETRIES", "30"))
retry_interval = int(os.environ.get("DB_RETRY_INTERVAL", "5"))

# Configuración optimizada de SQLAlchemy para entornos cloud
app.config['SQLALCHEMY_DATABASE_URI'] = f'postgresql://{db_user}:{db_password}@{db_host}:{db_port}/{db_name}'
app.config['SQLALCHEMY_TRACK_MODIFICATIONS'] = False
app.config['SQLALCHEMY_ENGINE_OPTIONS'] = {
    'pool_recycle': 600,  # Reciclar conexiones cada 10 minutos
    'pool_pre_ping': True,  # Verificar conexión antes de usarla
    'pool_timeout': 20,  # Aumentar timeout para entornos cloud
    'pool_size': 15,  # Aumentar pool size para manejar más conexiones
    'max_overflow': 25  # Permitir más conexiones en momentos de picos
}

logger.info(f"Configurando conexión a la base de datos: {db_host}:{db_port}/{db_name}")

db = SQLAlchemy(app)

class User(db.Model):
    id = db.Column(db.Integer, primary_key=True)
    name = db.Column(db.String(100), nullable=False)
    email = db.Column(db.String(120), unique=True, nullable=False)
    password_hash = db.Column(db.String(256))
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
                    test_user = User(
                        name="Usuario Prueba", 
                        email="usuario@ejemplo.com",
                        password_hash=generate_password_hash("password123")
                    )
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
            logger.error(traceback.format_exc())
            return False

# Endpoint raíz para información del servicio (compatible con API Gateway)
@app.route('/', methods=['GET'])
def root():
    return jsonify({
        "service": "user-service",
        "status": "running",
        "version": os.environ.get('DEPLOYMENT_VERSION', '1.0.0'),
        "endpoints": ["/users", "/users/{id}", "/health"],
        "environment": os.environ.get('ENVIRONMENT', 'development')
    })

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
            "environment": os.environ.get('ENVIRONMENT', 'development'),
            "timestamp": time.time()
        })
    except Exception as e:
        logger.error(f"Health check failed: {str(e)}")
        logger.error(traceback.format_exc())
        return jsonify({
            "error": str(e), 
            "status": "unhealthy", 
            "database": "disconnected",
            "service": "user-service",
            "timestamp": time.time()
        }), 500

# Health check adicional para API Gateway
@app.route('/users/health', methods=['GET'])
def users_health_check():
    return health()

@app.route('/users', methods=['GET'])
def get_users():
    try:
        users = User.query.all()
        return jsonify([user.to_dict() for user in users])
    except Exception as e:
        logger.error(f"Error getting users: {str(e)}")
        logger.error(traceback.format_exc())
        return jsonify({"error": str(e)}), 500

@app.route('/users/<int:user_id>', methods=['GET'])
def get_user(user_id):
    try:
        user = User.query.get(user_id)
        if user:
            return jsonify(user.to_dict())
        return jsonify({"error": "Usuario no encontrado"}), 404
    except Exception as e:
        logger.error(f"Error getting user {user_id}: {str(e)}")
        logger.error(traceback.format_exc())
        return jsonify({"error": str(e)}), 500

@app.route('/users', methods=['POST'])
def create_user():
    try:
        data = request.get_json()
        if not data:
            return jsonify({"error": "Datos de entrada inválidos o faltantes"}), 400
            
        # Validar campos requeridos
        required_fields = ['name', 'email']
        missing_fields = [field for field in required_fields if field not in data]
        
        if missing_fields:
            return jsonify({
                "error": f"Campos requeridos faltantes: {', '.join(missing_fields)}"
            }), 400
        
        # Verificar si el email ya existe
        existing_user = User.query.filter_by(email=data['email']).first()
        if existing_user:
            return jsonify({"error": f"El email {data['email']} ya está registrado"}), 409
        
        # Crear usuario con contraseña (compatibilidad con frontend)
        user = User(
            name=data['name'], 
            email=data['email'],
            # Almacenando hash de contraseña si se proporciona
            password_hash=generate_password_hash(data.get('password', '')) if 'password' in data else None
        )
        
        db.session.add(user)
        db.session.commit()
        
        logger.info(f"Usuario creado: {user.id} - {user.name}")
        
        return jsonify({
            "id": user.id, 
            "message": "Usuario creado correctamente",
            "user": user.to_dict()
        }), 201
    except sqlalchemy.exc.IntegrityError as e:
        db.session.rollback()
        logger.error(f"Error de integridad al crear usuario: {str(e)}")
        return jsonify({"error": "Error de integridad en la base de datos. Verifique que los datos sean válidos."}), 400
    except Exception as e:
        db.session.rollback()
        logger.error(f"Error creating user: {str(e)}")
        logger.error(traceback.format_exc())
        return jsonify({"error": f"Error interno del servidor: {str(e)}"}), 500

@app.route('/users/<int:user_id>', methods=['PUT'])
def update_user(user_id):
    try:
        user = User.query.get(user_id)
        if not user:
            return jsonify({"error": "Usuario no encontrado"}), 404
            
        data = request.get_json()
        if not data:
            return jsonify({"error": "Datos de entrada inválidos o faltantes"}), 400
            
        if 'name' in data:
            user.name = data['name']
        if 'email' in data:
            # Verificar que el nuevo email no exista ya
            if data['email'] != user.email:
                existing_email = User.query.filter_by(email=data['email']).first()
                if existing_email:
                    return jsonify({"error": f"El email {data['email']} ya está registrado"}), 409
            user.email = data['email']
        # Actualizar contraseña si se proporciona
        if 'password' in data and data['password']:
            user.password_hash = generate_password_hash(data['password'])
            
        db.session.commit()
        logger.info(f"Usuario actualizado: {user.id} - {user.name}")
        
        return jsonify({
            "message": "Usuario actualizado correctamente",
            "user": user.to_dict()
        })
    except sqlalchemy.exc.IntegrityError as e:
        db.session.rollback()
        logger.error(f"Error de integridad al actualizar usuario {user_id}: {str(e)}")
        return jsonify({"error": "Error de integridad en la base de datos. Verifique que los datos sean válidos."}), 400
    except Exception as e:
        db.session.rollback()
        logger.error(f"Error updating user {user_id}: {str(e)}")
        logger.error(traceback.format_exc())
        return jsonify({"error": f"Error interno del servidor: {str(e)}"}), 500

@app.route('/users/<int:user_id>', methods=['DELETE'])
def delete_user(user_id):
    try:
        user = User.query.get(user_id)
        if not user:
            return jsonify({"error": "Usuario no encontrado"}), 404
            
        db.session.delete(user)
        db.session.commit()
        logger.info(f"Usuario eliminado: {user_id}")
        
        return jsonify({
            "message": "Usuario eliminado correctamente",
            "id": user_id
        })
    except Exception as e:
        db.session.rollback()
        logger.error(f"Error deleting user {user_id}: {str(e)}")
        logger.error(traceback.format_exc())
        return jsonify({"error": f"Error interno del servidor: {str(e)}"}), 500

# Endpoint catch-all para manejar rutas proxy de API Gateway
@app.route('/<path:path>', methods=['GET', 'POST', 'PUT', 'DELETE', 'OPTIONS'])
def catch_all(path):
    logger.debug(f"Ruta catch-all invocada: {path} - Método: {request.method}")
    
    if path.startswith('users/'):
        # Redirigir internamente eliminando el prefijo 'users/'
        path = path[6:]  # longitud de 'users/'
        if not path:
            if request.method == 'GET':
                return get_users()
            elif request.method == 'POST':
                return create_user()
        else:
            # Intentar parsear ID si es numérico
            try:
                user_id = int(path)
                if request.method == 'GET':
                    return get_user(user_id)
                elif request.method == 'PUT':
                    return update_user(user_id)
                elif request.method == 'DELETE':
                    return delete_user(user_id)
            except ValueError:
                # Si no es ID, verificar si es health
                if path == 'health':
                    return health()
    
    logger.warning(f"Endpoint no encontrado: {path}")
    return jsonify({'error': f'Endpoint no encontrado: {path}'}), 404

# Manejadores de errores para rutas no encontradas y errores internos
@app.errorhandler(404)
def resource_not_found(e):
    logger.warning(f"Recurso no encontrado: {request.path}")
    return jsonify(error=str(e)), 404

@app.errorhandler(500)
def internal_server_error(e):
    logger.error(f"Error interno del servidor: {str(e)}")
    logger.error(traceback.format_exc())
    return jsonify(error="Error interno del servidor"), 500

# Manejador de CORS para las redirecciones preflighted
@app.after_request
def after_request(response):
    # Asegurar que los encabezados CORS estén presentes
    response.headers.add('Access-Control-Allow-Origin', cors_origins if cors_origins != '*' else '*')
    response.headers.add('Access-Control-Allow-Headers', 'Content-Type,Authorization,X-Requested-With')
    response.headers.add('Access-Control-Allow-Methods', 'GET,PUT,POST,DELETE,OPTIONS')
    response.headers.add('Access-Control-Allow-Credentials', 'true')
    return response

# Hook para cerrar sesiones expiradas
@app.teardown_appcontext
def shutdown_session(exception=None):
    db.session.remove()

if __name__ == '__main__':
    # Inicializar la base de datos antes de iniciar el servicio
    if initialize_database():
        port = int(os.environ.get('PORT', 3001))
        debug = os.environ.get('ENVIRONMENT') == 'development'
        app.run(host='0.0.0.0', port=port, debug=debug)
    else:
        logger.critical("No se pudo inicializar la base de datos. El servicio no se iniciará.")
        exit(1)