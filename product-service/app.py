import os
import time
import logging
from datetime import datetime
from flask import Flask, request, jsonify
from flask_sqlalchemy import SQLAlchemy
from flask_cors import CORS
import sqlalchemy.exc

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
db_name = os.environ.get("POSTGRES_DB", "product_db")

# Registrar valores para diagnóstico
logger.info(f"Product Service - Parámetros de conexión DB: host={db_host}, port={db_port}, db={db_name}, user={db_user}")

# IMPORTANTE: Forzar explícitamente conexión TCP/IP en vez de socket Unix
# La forma correcta de conectarse a RDS desde EC2
connection_uri = f"postgresql://{db_user}:{db_password}@{db_host}:{db_port}/{db_name}"
logger.info(f"Product Service - URI de conexión: {connection_uri.replace(db_password, '******')}")

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

# Modelo de Producto - Asegurar coherencia con frontend (App.js)
class Product(db.Model):
    id = db.Column(db.Integer, primary_key=True)
    name = db.Column(db.String(100), nullable=False)
    description = db.Column(db.Text, nullable=True)
    price = db.Column(db.Float, nullable=False)
    stock = db.Column(db.Integer, default=0)
    created_at = db.Column(db.DateTime, default=datetime.utcnow)
    updated_at = db.Column(db.DateTime, default=datetime.utcnow, onupdate=datetime.utcnow)
    
    def to_dict(self):
        """Convertir a diccionario (formato esperado por frontend)"""
        return {
            'id': self.id,
            'name': self.name,
            'description': self.description,
            'price': self.price,
            'stock': self.stock
        }

# Endpoint de health check para ALB y API Gateway
@app.route('/products/health', methods=['GET'])
@app.route('/health', methods=['GET'])
def health_check():
    try:
        # Verificar conexión a la BD
        db.session.execute(db.text('SELECT 1'))
        return jsonify({"status": "healthy", "service": "product-service"}), 200
    except Exception as e:
        logger.error(f"Health check failed: {str(e)}")
        return jsonify({"status": "unhealthy", "error": str(e)}), 500

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
    product = Product.query.get(product_id)
    if not product:
        return jsonify({"error": "Producto no encontrado"}), 404
    return jsonify(product.to_dict())

# POST - Crear nuevo producto (adaptado al formato del frontend)
@app.route('/products', methods=['POST'])
def create_product():
    try:
        data = request.get_json()
        if not data:
            return jsonify({"error": "Datos inválidos"}), 400
            
        # Validar campos requeridos que coinciden con frontend
        if 'name' not in data or 'price' not in data:
            return jsonify({"error": "Faltan campos requeridos (name, price)"}), 400
            
        # Crear nuevo producto
        new_product = Product(
            name=data['name'],
            description=data.get('description', ''),
            price=float(data['price']),
            stock=data.get('stock', 0)
        )
        
        db.session.add(new_product)
        db.session.commit()
        
        # Formato de respuesta que espera el frontend
        return jsonify({
            "message": "Producto creado exitosamente",
            "product": new_product.to_dict()
        }), 201
        
    except Exception as e:
        db.session.rollback()
        logger.error(f"Error al crear producto: {e}")
        return jsonify({"error": "Error al crear producto"}), 500

# Inicialización de la base de datos con reintentos
def initialize_database():
    max_retries = int(os.environ.get("DB_MAX_RETRIES", "30"))
    retry_interval = int(os.environ.get("DB_RETRY_INTERVAL", "5"))
    
    # Prueba de conexión directa con psycopg2 antes de usar SQLAlchemy
    for i in range(max_retries):
        try:
            logger.info(f"Product Service - Intento directo con psycopg2 ({i+1}/{max_retries})...")
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
            logger.info(f"Product Service - Conexión psycopg2 exitosa: {version[0]}")
            cursor.close()
            conn.close()
            break
        except Exception as e:
            logger.warning(f"Product Service - Intento {i+1} directo psycopg2 falló: {e}")
            if i < max_retries - 1:
                logger.info(f"Product Service - Reintentando en {retry_interval} segundos...")
                time.sleep(retry_interval)
            else:
                logger.error(f"Product Service - No se pudo conectar directamente con psycopg2 después de {max_retries} intentos")
    
    # Intentar crear tablas con SQLAlchemy
    for i in range(max_retries):
        try:
            logger.info(f"Product Service - Creando tablas ({i+1}/{max_retries})...")
            db.create_all()
            
            # Crear productos de prueba si la BD está vacía
            if Product.query.count() == 0:
                test_products = [
                    Product(name="Producto 1", description="Descripción del producto 1", price=99.99, stock=10),
                    Product(name="Producto 2", description="Descripción del producto 2", price=149.99, stock=5)
                ]
                db.session.bulk_save_objects(test_products)
                db.session.commit()
                logger.info("Product Service - Productos de prueba creados")
                
            logger.info("Product Service - Conexión exitosa a la base de datos y tablas creadas")
            return True
            
        except Exception as e:
            logger.warning(f"Product Service - Error al crear tablas: {e}")
            if i < max_retries - 1:
                logger.info(f"Product Service - Reintentando en {retry_interval} segundos...")
                time.sleep(retry_interval)
    
    logger.error("Product Service - No se pudo inicializar la base de datos después de múltiples intentos")
    return False

if __name__ == '__main__':
    if initialize_database():
        port = int(os.environ.get("PORT", "3002"))
        app.run(host='0.0.0.0', port=port)
    else:
        exit(1)