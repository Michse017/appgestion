from flask import Flask, jsonify, request
from flask_sqlalchemy import SQLAlchemy
from flask_cors import CORS

app = Flask(__name__)
CORS(app)

# Configuración PostgreSQL
app.config['SQLALCHEMY_DATABASE_URI'] = 'postgresql://user:password@user-db:5432/user_db'
db = SQLAlchemy(app)

# Modelo
class User(db.Model):
    id = db.Column(db.Integer, primary_key=True)
    name = db.Column(db.String(80), nullable=False)
    email = db.Column(db.String(120), unique=True, nullable=False)

# Crear tablas
with app.app_context():
    db.create_all()

# Rutas
@app.route('/users', methods=['GET'])
def get_users():
    users = User.query.all()
    return jsonify([{'id': u.id, 'name': u.name, 'email': u.email} for u in users])

@app.route('/users', methods=['POST'])
def create_user():
    data = request.get_json()
    new_user = User(name=data['name'], email=data['email'])
    db.session.add(new_user)
    db.session.commit()
    return jsonify({'message': 'User created'}), 201

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=3001)