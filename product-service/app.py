import os
import time
import logging
from flask import Flask, request, jsonify, redirect
from flask_sqlalchemy import SQLAlchemy
from flask_cors import CORS
import sqlalchemy.exc

app = Flask(__name__)

# Configuración de timeout para operaciones largas
service_timeout = int(os.environ.get("SERVICE_TIMEOUT", "60"))

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

# Configuración de CORS mejorada
cors_origins = os.environ.get('CORS_ALLOWED_ORIGINS', '*')
CORS(app, origins=[cors_origins] if cors_origins != '*' else '*', supports_credentials=True)

# Configuración de base de datos desde variables de entorno
db_user = os.environ.get("POSTGRES_USER", "dbadmin")
db_password = os.environ.get("POSTGRES_PASSWORD", "contraseña_segura")
db_host = os.environ.get("POSTGRES_HOST", "localhost")
db_name = os.environ.get("POSTGRES_DB", "product_db")
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

class Product(db.Model):
    id = db.Column(db.Integer, primary_key=True)
    name = db.Column(db.String(100), nullable=False)
    description = db.Column(db.Text)
    price = db.Column(db.Float, nullable=False)
    stock = db.Column(db.Integer, default=0)
    created_at = db.Column(db.DateTime, server_default=db.func.now())
    updated_at = db.Column(db.DateTime, server_default=db.func.now(), onupdate=db.func.now())
    
    def __repr__(self):
        return f'<Product {self.name}>'
    
    def to_dict(self):
        return {
            'id': self.id,
            'name': self.name,
            'description': self.description,
            'price': self.price,
            'stock': self.stock,
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
                # Crear productos de prueba si no existe ninguno
                if Product.query.count() == 0:
                    test_products = [
                        Product(name="Producto 1", description="Descripción del producto 1", price=99.99, stock=10),
                        Product(name="Producto 2", description="Descripción del producto 2", price=149.99, stock=5)
                    ]
                    db.session.bulk_save_objects(test_products)
                    db.session.commit()
                    logger.info("Productos de prueba creados")
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

# Endpoint raíz para información del servicio (compatible con API Gateway)
@app.route('/', methods=['GET'])
def root():
    return jsonify({
        "service": "product-service",
        "status": "running",
        "version": os.environ.get('DEPLOYMENT_VERSION', '1.0.0'),
        "endpoints": ["/products", "/products/{id}", "/health"]
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
            "service": "product-service",
            "version": os.environ.get('DEPLOYMENT_VERSION', '1.0.0'),
            "timestamp": time.time()
        })
    except Exception as e:
        logger.error(f"Health check failed: {str(e)}")
        return jsonify({
            "error": str(e), 
            "status": "unhealthy", 
            "database": "disconnected",
            "service": "product-service",
            "timestamp": time.time()
        }), 500

# Health check adicional para API Gateway
@app.route('/products/health', methods=['GET'])
def products_health_check():
    return health()

@app.route('/products', methods=['GET'])
def get_products():
    try:
        products = Product.query.all()
        return jsonify([product.to_dict() for product in products])
    except Exception as e:
        logger.error(f"Error getting products: {str(e)}")
        return jsonify({"error": str(e)}), 500

@app.route('/products/<int:product_id>', methods=['GET'])
def get_product(product_id):
    try:
        product = Product.query.get(product_id)
        if product:
            return jsonify(product.to_dict())
        return jsonify({"error": "Product not found"}), 404
    except Exception as e:
        logger.error(f"Error getting product {product_id}: {str(e)}")
        return jsonify({"error": str(e)}), 500

@app.route('/products', methods=['POST'])
def create_product():
    try:
        data = request.get_json()
        if not data or not 'name' in data or not 'price' in data:
            return jsonify({"error": "Missing required fields"}), 400
            
        product = Product(
            name=data['name'], 
            description=data.get('description', ''),
            price=float(data['price']),
            stock=int(data.get('stock', 0))
        )
        db.session.add(product)
        db.session.commit()
        
        return jsonify({
            "id": product.id, 
            "message": "Product created successfully",
            "product": product.to_dict()
        }), 201
    except Exception as e:
        db.session.rollback()
        logger.error(f"Error creating product: {str(e)}")
        return jsonify({"error": str(e)}), 500

@app.route('/products/<int:product_id>', methods=['PUT'])
def update_product(product_id):
    try:
        product = Product.query.get(product_id)
        if not product:
            return jsonify({"error": "Product not found"}), 404
            
        data = request.get_json()
        if 'name' in data:
            product.name = data['name']
        if 'description' in data:
            product.description = data['description']
        if 'price' in data:
            product.price = float(data['price'])
        if 'stock' in data:
            product.stock = int(data['stock'])
            
        db.session.commit()
        return jsonify({
            "message": "Product updated successfully",
            "product": product.to_dict()
        })
    except Exception as e:
        db.session.rollback()
        logger.error(f"Error updating product {product_id}: {str(e)}")
        return jsonify({"error": str(e)}), 500

@app.route('/products/<int:product_id>', methods=['DELETE'])
def delete_product(product_id):
    try:
        product = Product.query.get(product_id)
        if not product:
            return jsonify({"error": "Product not found"}), 404
            
        db.session.delete(product)
        db.session.commit()
        return jsonify({"message": "Product deleted successfully"})
    except Exception as e:
        db.session.rollback()
        logger.error(f"Error deleting product {product_id}: {str(e)}")
        return jsonify({"error": str(e)}), 500

# Endpoint catch-all para manejar rutas proxy de API Gateway
@app.route('/<path:path>', methods=['GET', 'POST', 'PUT', 'DELETE', 'OPTIONS'])
def catch_all(path):
    if path.startswith('products/'):
        # Redirigir internamente eliminando el prefijo 'products/'
        path = path[9:]  # longitud de 'products/'
        if not path:
            return get_products() if request.method == 'GET' else create_product()
        else:
            # Intentar parsear ID si es numérico
            try:
                product_id = int(path)
                if request.method == 'GET':
                    return get_product(product_id)
                elif request.method == 'PUT':
                    return update_product(product_id)
                elif request.method == 'DELETE':
                    return delete_product(product_id)
            except ValueError:
                # Si no es ID, verificar si es health
                if path == 'health':
                    return health()
            
    return jsonify({'error': 'Endpoint not found'}), 404

# Manejadores de errores para rutas no encontradas y errores internos
@app.errorhandler(404)
def resource_not_found(e):
    return jsonify(error=str(e)), 404

@app.errorhandler(500)
def internal_server_error(e):
    logger.error(f"Error interno del servidor: {str(e)}")
    return jsonify(error="Error interno del servidor"), 500

# Manejador de CORS para las redirecciones preflighted
@app.after_request
def after_request(response):
    response.headers.add('Access-Control-Allow-Headers', 'Content-Type,Authorization')
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
        port = int(os.environ.get('PORT', 3002))
        app.run(host='0.0.0.0', port=port, debug=os.environ.get('ENVIRONMENT') == 'development')
    else:
        logger.critical("No se pudo inicializar la base de datos. El servicio no se iniciará.")
        exit(1)