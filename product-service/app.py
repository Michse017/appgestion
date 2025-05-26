import os
import time
import logging
from datetime import datetime
from flask import Flask, request, jsonify
from flask_sqlalchemy import SQLAlchemy
from flask_cors import CORS

# Configuración de logging mejorada
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s [%(levelname)s] %(message)s',
)
logger = logging.getLogger(__name__)

app = Flask(__name__)
logger.info("Iniciando Product Service")

# Configuración CORS - Fundamental para API Gateway
CORS(app, resources={r"/*": {"origins": "*"}})

# Obtener variables de entorno con valores por defecto
db_user = os.environ.get("POSTGRES_USER", "dbadmin")
db_password = os.environ.get("POSTGRES_PASSWORD", "placeholder_password")
db_host = os.environ.get("POSTGRES_HOST", "localhost")
db_port = os.environ.get("POSTGRES_PORT", "5432")
db_name = os.environ.get("POSTGRES_DB", "product_db")

# Log de la configuración para diagnóstico
logger.info(f"Configuración DB: host={db_host}, port={db_port}, db={db_name}, user={db_user}")

# Conexión a la base de datos
db_uri = f"postgresql://{db_user}:{db_password}@{db_host}:{db_port}/{db_name}"
app.config['SQLALCHEMY_DATABASE_URI'] = db_uri
app.config['SQLALCHEMY_TRACK_MODIFICATIONS'] = False

db = SQLAlchemy(app)

# Modelo de Producto
class Product(db.Model):
    id = db.Column(db.Integer, primary_key=True)
    name = db.Column(db.String(100), nullable=False)
    description = db.Column(db.Text, nullable=True)
    price = db.Column(db.Float, nullable=False)
    stock = db.Column(db.Integer, default=0)
    created_at = db.Column(db.DateTime, default=datetime.utcnow)
    updated_at = db.Column(db.DateTime, default=datetime.utcnow, onupdate=datetime.utcnow)
    
    def to_dict(self):
        return {
            'id': self.id,
            'name': self.name,
            'description': self.description,
            'price': self.price,
            'stock': self.stock
        }

# Endpoint principal para verificar que el servicio esté en funcionamiento
@app.route('/', methods=['GET'])
def index():
    return jsonify({"status": "running", "service": "product-service"}), 200

# Endpoint específico para ALB health checks - CRÍTICO
@app.route('/health', methods=['GET'])
def alb_health_check():
    return jsonify({"status": "healthy", "service": "product-service"}), 200

# Endpoint específico para API Gateway health checks - CRÍTICO
@app.route('/products/health', methods=['GET'])
def api_health_check():
    try:
        # Verificar conexión a la BD
        db.session.execute(db.text('SELECT 1'))
        return jsonify({"status": "healthy", "service": "product-service", "database": "connected"}), 200
    except Exception as e:
        logger.error(f"Health check error: {e}")
        # Incluso con error de BD, respondemos 200 para ALB (diagnóstico)
        return jsonify({"status": "unhealthy", "error": str(e)}), 200

# GET - Lista de todos los productos
@app.route('/products', methods=['GET'])
def get_products():
    try:
        products = Product.query.all()
        return jsonify([product.to_dict() for product in products])
    except Exception as e:
        logger.error(f"Error al obtener productos: {e}")
        return jsonify({"error": "Error al obtener productos"}), 500

# GET - Detalles de un producto específico por ID
@app.route('/products/<int:product_id>', methods=['GET'])
def get_product(product_id):
    try:
        product = Product.query.get(product_id)
        if not product:
            return jsonify({"error": "Producto no encontrado"}), 404
        return jsonify(product.to_dict())
    except Exception as e:
        logger.error(f"Error al obtener producto {product_id}: {e}")
        return jsonify({"error": f"Error al obtener producto {product_id}"}), 500

# POST - Crear nuevo producto
@app.route('/products', methods=['POST'])
def create_product():
    try:
        data = request.get_json()
        if not data:
            return jsonify({"error": "Datos inválidos"}), 400
            
        if 'name' not in data or 'price' not in data:
            return jsonify({"error": "Faltan campos requeridos (name, price)"}), 400
            
        new_product = Product(
            name=data['name'],
            description=data.get('description', ''),
            price=float(data['price']),
            stock=data.get('stock', 0)
        )
        
        db.session.add(new_product)
        db.session.commit()
        
        return jsonify({
            "message": "Producto creado exitosamente",
            "product": new_product.to_dict()
        }), 201
        
    except Exception as e:
        db.session.rollback()
        logger.error(f"Error al crear producto: {e}")
        return jsonify({"error": "Error al crear producto"}), 500

# Función para inicializar la base de datos con reintentos
def setup_database():
    max_attempts = int(os.environ.get("DB_MAX_RETRIES", "30"))
    retry_interval = int(os.environ.get("DB_RETRY_INTERVAL", "5"))
    
    logger.info(f"Intentando conectar a la base de datos (máx {max_attempts} intentos)")
    
    for attempt in range(max_attempts):
        try:
            db.create_all()
            logger.info("Tablas creadas correctamente")
            
            # Crear productos de prueba si no existe ninguno
            if Product.query.count() == 0:
                logger.info("Creando productos de prueba iniciales")
                test_products = [
                    Product(name="Producto 1", description="Descripción del producto 1", price=99.99, stock=10),
                    Product(name="Producto 2", description="Descripción del producto 2", price=149.99, stock=5)
                ]
                db.session.bulk_save_objects(test_products)
                db.session.commit()
                logger.info("Productos de prueba creados")
            
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
    port = int(os.environ.get("PORT", "3002"))
    logger.info(f"Iniciando servicio en puerto {port}")
    app.run(host='0.0.0.0', port=port)