from flask import Flask, jsonify, request
from flask_sqlalchemy import SQLAlchemy
from flask_cors import CORS
import os

app = Flask(__name__)
CORS(app)

# Configuración PostgreSQL
db_user = os.environ.get("DB_USER", "product")
db_password = os.environ.get("DB_PASSWORD", "password")
db_host = os.environ.get("DB_HOST", "localhost")
db_name = os.environ.get("DB_NAME", "product_db")

app.config['SQLALCHEMY_DATABASE_URI'] = f'postgresql://{db_user}:{db_password}@{db_host}:5432/{db_name}'
db = SQLAlchemy(app)

# Modelo
class Product(db.Model):
    id = db.Column(db.Integer, primary_key=True)
    name = db.Column(db.String(80), nullable=False)
    price = db.Column(db.Float, nullable=False)

# Crear tablas
with app.app_context():
    db.create_all()

# Rutas
@app.route('/products', methods=['GET'])
def get_products():
    products = Product.query.all()
    return jsonify([{'id': p.id, 'name': p.name, 'price': p.price} for p in products])

@app.route('/products', methods=['POST'])
def create_product():
    data = request.get_json()
    new_product = Product(name=data['name'], price=data['price'])
    db.session.add(new_product)
    db.session.commit()
    return jsonify({'message': 'Product created'}), 201

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=3002)