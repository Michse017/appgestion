import React, { useState, useEffect } from 'react';
import './app.css';
import { USER_SERVICE_URL, PRODUCT_SERVICE_URL } from './config';

function App() {
  const [users, setUsers] = useState([]);
  const [products, setProducts] = useState([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState(null);

  // Estados para formularios
  const [newUser, setNewUser] = useState({ name: '', email: '', password: '' });
  const [newProduct, setNewProduct] = useState({ name: '', description: '', price: '' });

  useEffect(() => {
    fetchData();
  }, []);

  const fetchData = async () => {
    try {
      setLoading(true);
      setError(null);
      
      // Fetch users
      const usersResponse = await fetch(USER_SERVICE_URL);
      if (!usersResponse.ok) throw new Error(`Users API error: ${usersResponse.status}`);
      const usersData = await usersResponse.json();
      setUsers(usersData);

      // Fetch products
      const productsResponse = await fetch(PRODUCT_SERVICE_URL);
      if (!productsResponse.ok) throw new Error(`Products API error: ${productsResponse.status}`);
      const productsData = await productsResponse.json();
      setProducts(productsData);

    } catch (err) {
      console.error('Error fetching data:', err);
      setError(err.message);
    } finally {
      setLoading(false);
    }
  };

  const createUser = async (e) => {
    e.preventDefault();
    try {
      const response = await fetch(USER_SERVICE_URL, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
        },
        body: JSON.stringify(newUser),
      });
      
      if (!response.ok) throw new Error(`Error creating user: ${response.status}`);
      
      setNewUser({ name: '', email: '', password: '' });
      fetchData(); // Refresh data
    } catch (err) {
      console.error('Error creating user:', err);
      setError(err.message);
    }
  };

  const createProduct = async (e) => {
    e.preventDefault();
    try {
      const productData = {
        ...newProduct,
        price: parseFloat(newProduct.price)
      };
      
      const response = await fetch(PRODUCT_SERVICE_URL, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
        },
        body: JSON.stringify(productData),
      });
      
      if (!response.ok) throw new Error(`Error creating product: ${response.status}`);
      
      setNewProduct({ name: '', description: '', price: '' });
      fetchData(); // Refresh data
    } catch (err) {
      console.error('Error creating product:', err);
      setError(err.message);
    }
  };

  if (loading) {
    return <div className="App"><h1>Cargando...</h1></div>;
  }

  return (
    <div className="App">
      <header className="App-header">
        <h1>AppGestión</h1>
        <p>Sistema de gestión de usuarios y productos</p>
      </header>

      {error && (
        <div className="error">
          <p>Error: {error}</p>
          <button onClick={fetchData}>Reintentar</button>
        </div>
      )}

      <main>
        <section>
          <h2>Usuarios ({users.length})</h2>
          <form onSubmit={createUser}>
            <input
              type="text"
              placeholder="Nombre"
              value={newUser.name}
              onChange={(e) => setNewUser({...newUser, name: e.target.value})}
              required
            />
            <input
              type="email"
              placeholder="Email"
              value={newUser.email}
              onChange={(e) => setNewUser({...newUser, email: e.target.value})}
              required
            />
            <input
              type="password"
              placeholder="Contraseña"
              value={newUser.password}
              onChange={(e) => setNewUser({...newUser, password: e.target.value})}
              required
            />
            <button type="submit">Crear Usuario</button>
          </form>
          
          <ul>
            {users.map(user => (
              <li key={user.id}>
                <strong>{user.name}</strong> - {user.email}
              </li>
            ))}
          </ul>
        </section>

        <section>
          <h2>Productos ({products.length})</h2>
          <form onSubmit={createProduct}>
            <input
              type="text"
              placeholder="Nombre del producto"
              value={newProduct.name}
              onChange={(e) => setNewProduct({...newProduct, name: e.target.value})}
              required
            />
            <input
              type="text"
              placeholder="Descripción"
              value={newProduct.description}
              onChange={(e) => setNewProduct({...newProduct, description: e.target.value})}
            />
            <input
              type="number"
              step="0.01"
              placeholder="Precio"
              value={newProduct.price}
              onChange={(e) => setNewProduct({...newProduct, price: e.target.value})}
              required
            />
            <button type="submit">Crear Producto</button>
          </form>
          
          <ul>
            {products.map(product => (
              <li key={product.id}>
                <strong>{product.name}</strong> - ${product.price}
                <br />
                <small>{product.description}</small>
              </li>
            ))}
          </ul>
        </section>
      </main>
    </div>
  );
}

export default App;