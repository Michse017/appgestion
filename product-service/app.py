import os
import logging
from flask import Flask, request, jsonify
from flask_sqlalchemy import SQLAlchemy
from flask_cors import CORS

app = Flask(__name__)
CORS(app)

# Configuración de logging
logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

# Configuración de base de datos desde variables de entorno
db_user = os.environ.get("POSTGRES_USER", "dbadmin")
db_password = os.environ.get("POSTGRES_PASSWORD", "contraseña_segura")
db_host = os.environ.get("POSTGRES_HOST", "localhost")
db_name = os.environ.get("POSTGRES_DB", "product_db")
db_port = os.environ.get("POSTGRES_PORT", "5432")

app.config['SQLALCHEMY_DATABASE_URI'] = f'postgresql://{db_user}:{db_password}@{db_host}:{db_port}/{db_name}'
app.config['SQLALCHEMY_TRACK_MODIFICATIONS'] = False

logger.info(f"Conectando a la base de datos: {db_host}:{db_port}/{db_name}")

db = SQLAlchemy(app)

class Product(db.Model):
    id = db.Column(db.Integer, primary_key=True)
    name = db.Column(db.String(100), nullable=False)
    description = db.Column(db.Text)
    price = db.Column(db.Float, nullable=False)

# Health check endpoint CORREGIDO
@app.route('/health', methods=['GET'])
def health():
    try:
        # Usar execute con db.text() explícito
        result = db.session.execute(db.text('SELECT 1 as test'))
        db.session.commit()  # Agregar commit
        return jsonify({"status": "healthy"})
    except Exception as e:
        logger.error(f"Health check failed: {str(e)}")
        return jsonify({"error": str(e), "status": "unhealthy"}), 500

@app.route('/products', methods=['GET'])
def get_products():
    try:
        products = Product.query.all()
        return jsonify([{"id": p.id, "name": p.name, "description": p.description, "price": p.price} for p in products])
    except Exception as e:
        logger.error(f"Error getting products: {str(e)}")
        return jsonify({"error": str(e)}), 500

@app.route('/products', methods=['POST'])
def create_product():
    try:
        data = request.get_json()
        product = Product(name=data['name'], description=data.get('description', ''), price=data['price'])
        db.session.add(product)
        db.session.commit()
        return jsonify({"id": product.id, "message": "Product created"})
    except Exception as e:
        logger.error(f"Error creating product: {str(e)}")
        return jsonify({"error": str(e)}), 500

# Crear tablas si no existen
try:
    with app.app_context():
        db.create_all()
        logger.info("Tablas creadas/verificadas correctamente")
except Exception as e:
    logger.error(f"Error inicializando base de datos: {str(e)}")

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=3002, debug=False)