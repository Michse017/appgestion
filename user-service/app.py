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
db_name = os.environ.get("POSTGRES_DB", "user_db")
db_port = os.environ.get("POSTGRES_PORT", "5432")

app.config['SQLALCHEMY_DATABASE_URI'] = f'postgresql://{db_user}:{db_password}@{db_host}:{db_port}/{db_name}'
app.config['SQLALCHEMY_TRACK_MODIFICATIONS'] = False

logger.info(f"Conectando a la base de datos: {db_host}:{db_port}/{db_name}")

db = SQLAlchemy(app)

class User(db.Model):
    id = db.Column(db.Integer, primary_key=True)
    name = db.Column(db.String(100), nullable=False)
    email = db.Column(db.String(120), unique=True, nullable=False)

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

@app.route('/users', methods=['GET'])
def get_users():
    try:
        users = User.query.all()
        return jsonify([{"id": u.id, "name": u.name, "email": u.email} for u in users])
    except Exception as e:
        logger.error(f"Error getting users: {str(e)}")
        return jsonify({"error": str(e)}), 500

@app.route('/users', methods=['POST'])
def create_user():
    try:
        data = request.get_json()
        user = User(name=data['name'], email=data['email'])
        db.session.add(user)
        db.session.commit()
        return jsonify({"id": user.id, "message": "User created"})
    except Exception as e:
        logger.error(f"Error creating user: {str(e)}")
        return jsonify({"error": str(e)}), 500

# Crear tablas si no existen
try:
    with app.app_context():
        db.create_all()
        # Crear usuario de prueba si no existe
        if User.query.count() == 0:
            test_user = User(name="Usuario Prueba", email="usuario@ejemplo.com")
            db.session.add(test_user)
            db.session.commit()
            logger.info("Usuario de prueba creado")
        logger.info("Tablas creadas/verificadas correctamente")
except Exception as e:
    logger.error(f"Error inicializando base de datos: {str(e)}")

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=3001, debug=False)