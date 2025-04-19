import React, { useState, useEffect } from 'react';
import './app.css';

function App() {
  const [users, setUsers] = useState([]);
  const [products, setProducts] = useState([]);
  const [newUser, setNewUser] = useState({ name: '', email: '' });
  const [newProduct, setNewProduct] = useState({ name: '', price: '' });

  // Cargar datos al iniciar
  useEffect(() => {
    fetchUsers();
    fetchProducts();
  }, []);

  const fetchUsers = async () => {
    const response = await fetch('http://localhost:3001/users');
    const data = await response.json();
    setUsers(data);
  };

  const fetchProducts = async () => {
    const response = await fetch('http://localhost:3002/products');
    const data = await response.json();
    setProducts(data);
  };

  const handleUserSubmit = async (e) => {
    e.preventDefault();
    await fetch('http://localhost:3001/users', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(newUser),
    });
    setNewUser({ name: '', email: '' });
    fetchUsers();
  };

  const handleProductSubmit = async (e) => {
    e.preventDefault();
    await fetch('http://localhost:3002/products', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        ...newProduct,
        price: parseFloat(newProduct.price),
      }),
    });
    setNewProduct({ name: '', price: '' });
    fetchProducts();
  };

  return (
    <div className="app-container">
      <h1>Gestor de Usuarios y Productos</h1>

      {/* Formulario Usuarios */}
      <div className="form-container">
        <h2>Crear Usuario</h2>
        <form onSubmit={handleUserSubmit}>
          <input
            type="text"
            placeholder="Nombre"
            value={newUser.name}
            onChange={(e) => setNewUser({ ...newUser, name: e.target.value })}
          />
          <input
            type="email"
            placeholder="Email"
            value={newUser.email}
            onChange={(e) => setNewUser({ ...newUser, email: e.target.value })}
          />
          <button type="submit">Guardar</button>
        </form>
      </div>

      {/* Formulario Productos */}
      <div className="form-container">
        <h2>Crear Producto</h2>
        <form onSubmit={handleProductSubmit}>
          <input
            type="text"
            placeholder="Nombre del producto"
            value={newProduct.name}
            onChange={(e) => setNewProduct({ ...newProduct, name: e.target.value })}
          />
          <input
            type="number"
            step="0.01"
            placeholder="Precio"
            value={newProduct.price}
            onChange={(e) => setNewProduct({ ...newProduct, price: e.target.value })}
          />
          <button type="submit">Guardar</button>
        </form>
      </div>

      {/* Listados */}
      <div className="lists-container">
        <div className="list">
          <h2>Usuarios Registrados</h2>
          <ul>
            {users.map((user) => (
              <li key={user.id}>
                {user.name} - {user.email}
              </li>
            ))}
          </ul>
        </div>

        <div className="list">
          <h2>Productos Disponibles</h2>
          <ul>
            {products.map((product) => (
              <li key={product.id}>
                {product.name} - ${product.price.toFixed(2)}
              </li>
            ))}
          </ul>
        </div>
      </div>
    </div>
  );
}

export default App;