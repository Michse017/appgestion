from flask import Flask, jsonify, request
from flask_sqlalchemy import SQLAlchemy
from flask_cors import CORS
import os
import logging
from dotenv import load_dotenv

# Configuración de logging
logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

# Cargar variables de entorno
load_dotenv()

app = Flask(__name__)

# Configuración CORS mejorada
cors_origins = os.environ.get("CORS_ALLOWED_ORIGINS", "*").split(",")
CORS(app, 
     resources={r"/*": {"origins": cors_origins}}, 
     supports_credentials=True,
     methods=["GET", "POST", "PUT", "DELETE", "OPTIONS"],
     allow_headers=["Content-Type", "X-Amz-Date", "Authorization", "X-Api-Key", "X-Requested-With"])

# Configuración PostgreSQL - Adaptado para AWS RDS y Docker
db_user = os.environ.get("POSTGRES_USER", os.environ.get("DB_USER", "product"))
db_password = os.environ.get("POSTGRES_PASSWORD", os.environ.get("DB_PASSWORD", "password"))
db_host = os.environ.get("POSTGRES_HOST", os.environ.get("DB_HOST", "localhost"))
db_name = os.environ.get("POSTGRES_DB", os.environ.get("DB_NAME", "product_db"))
db_port = os.environ.get("POSTGRES_PORT", "5432")

# Construir URI de conexión a la BD
app.config['SQLALCHEMY_DATABASE_URI'] = f'postgresql://{db_user}:{db_password}@{db_host}:{db_port}/{db_name}'
app.config['SQLALCHEMY_TRACK_MODIFICATIONS'] = False

# Log de la configuración (sin mostrar credenciales)
logger.info(f"Conectando a la base de datos: {db_host}:{db_port}/{db_name}")

db = SQLAlchemy(app)

# Modelo
class Product(db.Model):
    id = db.Column(db.Integer, primary_key=True)
    name = db.Column(db.String(80), nullable=False)
    price = db.Column(db.Float, nullable=False)

# Health check endpoint para monitoreo
@app.route('/health', methods=['GET'])
def health_check():
    try:
        # Verificar conexión a la base de datos
        db.session.execute('SELECT 1')
        return jsonify({"status": "healthy", "service": "product-service"}), 200
    except Exception as e:
        logger.error(f"Health check failed: {str(e)}")
        return jsonify({"status": "unhealthy", "error": str(e)}), 500

# Crear tablas si no existen
try:
    with app.app_context():
        db.create_all()
        logger.info("Tablas creadas/verificadas correctamente")
except Exception as e:
    logger.error(f"Error creando tablas: {str(e)}")

# Rutas
@app.route('/products', methods=['GET'])
def get_products():
    try:
        products = Product.query.all()
        return jsonify([{'id': p.id, 'name': p.name, 'price': p.price} for p in products])
    except Exception as e:
        logger.error(f"Error obteniendo productos: {str(e)}")
        return jsonify({"error": "Error interno del servidor"}), 500

@app.route('/products', methods=['POST'])
def create_product():
    try:
        data = request.get_json()
        if not data or 'name' not in data or 'price' not in data:
            return jsonify({"error": "Datos incompletos"}), 400
            
        new_product = Product(name=data['name'], price=data['price'])
        db.session.add(new_product)
        db.session.commit()
        return jsonify({'message': 'Product created', 'id': new_product.id}), 201
    except Exception as e:
        db.session.rollback()
        logger.error(f"Error creando producto: {str(e)}")
        return jsonify({"error": "Error interno del servidor"}), 500

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=3002)