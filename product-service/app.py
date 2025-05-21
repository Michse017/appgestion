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
# Permitir CORS para todas las rutas y orígenes
CORS(app, supports_credentials=True, origins="*")

# Configuración PostgreSQL - Adaptado para AWS RDS y Docker
db_user = os.environ.get("POSTGRES_USER", os.environ.get("DB_USER", "user"))
db_password = os.environ.get("POSTGRES_PASSWORD", os.environ.get("DB_PASSWORD", "password"))
db_host = os.environ.get("POSTGRES_HOST", os.environ.get("DB_HOST", "localhost"))
db_name = os.environ.get("POSTGRES_DB", os.environ.get("DB_NAME", "user_db"))
db_port = os.environ.get("POSTGRES_PORT", "5432")

# Construir URI de conexión a la BD
app.config['SQLALCHEMY_DATABASE_URI'] = f'postgresql://{db_user}:{db_password}@{db_host}:{db_port}/{db_name}'
app.config['SQLALCHEMY_TRACK_MODIFICATIONS'] = False

# Log de la configuración (sin mostrar credenciales)
logger.info(f"Conectando a la base de datos: {db_host}:{db_port}/{db_name}")

db = SQLAlchemy(app)

# Modelo
class User(db.Model):
    id = db.Column(db.Integer, primary_key=True)
    name = db.Column(db.String(80), nullable=False)
    email = db.Column(db.String(120), unique=True, nullable=False)

# Health check endpoint para monitoreo
@app.route('/health', methods=['GET'])
def health_check():
    try:
        # Verificar conexión a la base de datos
        db.session.execute('SELECT 1')
        return jsonify({"status": "healthy", "service": "user-service"}), 200
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
@app.route('/users', methods=['GET'])
def get_users():
    try:
        users = User.query.all()
        return jsonify([{'id': u.id, 'name': u.name, 'email': u.email} for u in users])
    except Exception as e:
        logger.error(f"Error obteniendo usuarios: {str(e)}")
        return jsonify({"error": "Error interno del servidor"}), 500

@app.route('/users', methods=['POST'])
def create_user():
    try:
        data = request.get_json()
        if not data or 'name' not in data or 'email' not in data:
            return jsonify({"error": "Datos incompletos"}), 400
            
        new_user = User(name=data['name'], email=data['email'])
        db.session.add(new_user)
        db.session.commit()
        return jsonify({'message': 'User created', 'id': new_user.id}), 201
    except Exception as e:
        db.session.rollback()
        logger.error(f"Error creando usuario: {str(e)}")
        return jsonify({"error": "Error interno del servidor"}), 500

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=3001)