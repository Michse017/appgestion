import React, { useState, useEffect } from 'react';
import './app.css';

function App() {
  const [users, setUsers] = useState([]);
  const [products, setProducts] = useState([]);
  const [newUser, setNewUser] = useState({ name: '', email: '' });
  const [newProduct, setNewProduct] = useState({ name: '', price: '' });
  const [loading, setLoading] = useState({ users: false, products: false });
  const [error, setError] = useState({ users: null, products: null });

  // URL base para las APIs - usa variables de entorno si están disponibles
  const API_URL = process.env.REACT_APP_API_URL || '';
  const apiUrl = API_URL === 'https://api-gateway-placeholder' 
  ? `${window.location.origin}` // Usar origen actual
  : API_URL;

  // Cargar datos al iniciar
  useEffect(() => {
    fetchUsers();
    fetchProducts();
  }, []);

  const fetchUsers = async () => {
    setLoading(prev => ({ ...prev, users: true }));
    setError(prev => ({ ...prev, users: null }));
    
    try {
      const response = await fetch(`${apiUrl}/users`);
      if (!response.ok) throw new Error(`Error: ${response.statusText}`);
      const data = await response.json();
      setUsers(data);
    } catch (err) {
      console.error("Error fetching users:", err);
      setError(prev => ({ ...prev, users: err.message }));
    } finally {
      setLoading(prev => ({ ...prev, users: false }));
    }
  };

  const fetchProducts = async () => {
    setLoading(prev => ({ ...prev, products: true }));
    setError(prev => ({ ...prev, products: null }));
    
    try {
      const response = await fetch(`${apiUrl}/products`);
      if (!response.ok) throw new Error(`Error: ${response.statusText}`);
      const data = await response.json();
      setProducts(data);
    } catch (err) {
      console.error("Error fetching products:", err);
      setError(prev => ({ ...prev, products: err.message }));
    } finally {
      setLoading(prev => ({ ...prev, products: false }));
    }
  };

  const handleUserSubmit = async (e) => {
    e.preventDefault();
    setLoading(prev => ({ ...prev, users: true }));
    
    try {
      const response = await fetch(`${apiUrl}/users`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(newUser),
      });
      
      if (!response.ok) throw new Error(`Error: ${response.statusText}`);
      
      setNewUser({ name: '', email: '' });
      fetchUsers();
    } catch (err) {
      console.error("Error creating user:", err);
      setError(prev => ({ ...prev, users: err.message }));
    } finally {
      setLoading(prev => ({ ...prev, users: false }));
    }
  };

  const handleProductSubmit = async (e) => {
    e.preventDefault();
    setLoading(prev => ({ ...prev, products: true }));
    
    try {
      const response = await fetch(`${apiUrl}/products`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          ...newProduct,
          price: parseFloat(newProduct.price),
        }),
      });
      
      if (!response.ok) throw new Error(`Error: ${response.statusText}`);
      
      setNewProduct({ name: '', price: '' });
      fetchProducts();
    } catch (err) {
      console.error("Error creating product:", err);
      setError(prev => ({ ...prev, products: err.message }));
    } finally {
      setLoading(prev => ({ ...prev, products: false }));
    }
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
            disabled={loading.users}
            required
          />
          <input
            type="email"
            placeholder="Email"
            value={newUser.email}
            onChange={(e) => setNewUser({ ...newUser, email: e.target.value })}
            disabled={loading.users}
            required
          />
          <button type="submit" disabled={loading.users}>
            {loading.users ? 'Guardando...' : 'Guardar'}
          </button>
        </form>
        {error.users && <p className="error-message">Error: {error.users}</p>}
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
            disabled={loading.products}
            required
          />
          <input
            type="number"
            step="0.01"
            placeholder="Precio"
            value={newProduct.price}
            onChange={(e) => setNewProduct({ ...newProduct, price: e.target.value })}
            disabled={loading.products}
            required
          />
          <button type="submit" disabled={loading.products}>
            {loading.products ? 'Guardando...' : 'Guardar'}
          </button>
        </form>
        {error.products && <p className="error-message">Error: {error.products}</p>}
      </div>

      {/* Listados */}
      <div className="lists-container">
        <div className="list">
          <h2>Usuarios Registrados</h2>
          {loading.users && <p>Cargando usuarios...</p>}
          {!loading.users && users.length === 0 && !error.users && <p>No hay usuarios registrados.</p>}
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
          {loading.products && <p>Cargando productos...</p>}
          {!loading.products && products.length === 0 && !error.products && <p>No hay productos disponibles.</p>}
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