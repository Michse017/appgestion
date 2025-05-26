import React, { useState, useEffect } from 'react';
import './app.css';
import { USER_SERVICE_URL, PRODUCT_SERVICE_URL } from './config';

function App() {
  // Estados para datos
  const [users, setUsers] = useState([]);
  const [products, setProducts] = useState([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState(null);
  const [successMessage, setSuccessMessage] = useState(null);

  // Estados para formularios
  const [newUser, setNewUser] = useState({ name: '', email: '', password: '' });
  const [newProduct, setNewProduct] = useState({ name: '', description: '', price: '' });
  
  // Estados para operaciones en curso
  const [creatingUser, setCreatingUser] = useState(false);
  const [creatingProduct, setCreatingProduct] = useState(false);

  useEffect(() => {
    fetchData();
    
    // Limpiar mensaje de éxito después de 5 segundos
    const timer = setTimeout(() => {
      if (successMessage) setSuccessMessage(null);
    }, 5000);
    
    return () => clearTimeout(timer);
  }, [successMessage]);

  const fetchData = async () => {
    try {
      setLoading(true);
      setError(null);
      
      // Fetch users
      const usersResponse = await fetch(USER_SERVICE_URL);
      if (!usersResponse.ok) {
        const errorData = await usersResponse.json().catch(() => ({}));
        throw new Error(errorData.error || `Error en API de usuarios: ${usersResponse.status}`);
      }
      const usersData = await usersResponse.json();
      setUsers(usersData);

      // Fetch products
      const productsResponse = await fetch(PRODUCT_SERVICE_URL);
      if (!productsResponse.ok) {
        const errorData = await productsResponse.json().catch(() => ({}));
        throw new Error(errorData.error || `Error en API de productos: ${productsResponse.status}`);
      }
      const productsData = await productsResponse.json();
      setProducts(productsData);

    } catch (err) {
      console.error('Error al cargar datos:', err);
      setError(err.message);
    } finally {
      setLoading(false);
    }
  };

  const createUser = async (e) => {
    e.preventDefault();
    setCreatingUser(true);
    setError(null);
    setSuccessMessage(null);
    
    try {
      const response = await fetch(USER_SERVICE_URL, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
        },
        body: JSON.stringify(newUser),
      });
      
      // Manejar errores HTTP
      if (!response.ok) {
        const errorData = await response.json().catch(() => ({}));
        throw new Error(errorData.error || `Error al crear usuario: ${response.status}`);
      }
      
      const result = await response.json();
      setNewUser({ name: '', email: '', password: '' });
      setSuccessMessage(`Usuario "${result.user.name}" creado correctamente`);
      fetchData(); // Actualizar la lista de usuarios
      
    } catch (err) {
      console.error('Error al crear usuario:', err);
      setError(err.message);
    } finally {
      setCreatingUser(false);
    }
  };

  const createProduct = async (e) => {
    e.preventDefault();
    setCreatingProduct(true);
    setError(null);
    setSuccessMessage(null);
    
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
      
      // Manejar errores HTTP
      if (!response.ok) {
        const errorData = await response.json().catch(() => ({}));
        throw new Error(errorData.error || `Error al crear producto: ${response.status}`);
      }
      
      const result = await response.json();
      setNewProduct({ name: '', description: '', price: '' });
      setSuccessMessage(`Producto "${result.product.name}" creado correctamente`);
      fetchData(); // Actualizar la lista de productos
      
    } catch (err) {
      console.error('Error al crear producto:', err);
      setError(err.message);
    } finally {
      setCreatingProduct(false);
    }
  };

  if (loading && users.length === 0 && products.length === 0) {
    return (
      <div className="App">
        <div className="loading-container">
          <h2>Cargando datos...</h2>
          <div className="loading-spinner"></div>
        </div>
      </div>
    );
  }

  return (
    <div className="App">
      <header className="App-header">
        <h1>AppGestión</h1>
        <p>Sistema de gestión de usuarios y productos</p>
      </header>

      {/* Mensajes de estado */}
      {error && (
        <div className="error-message">
          <p>{error}</p>
          <button onClick={() => { setError(null); fetchData(); }}>Reintentar</button>
        </div>
      )}
      
      {successMessage && (
        <div className="success-message">
          <p>{successMessage}</p>
        </div>
      )}

      <main>
        {/* Sección de Usuarios */}
        <section className="data-section">
          <h2>Usuarios ({users.length})</h2>
          
          <form onSubmit={createUser} className="data-form">
            <div className="form-group">
              <label htmlFor="userName">Nombre:</label>
              <input
                id="userName"
                type="text"
                placeholder="Nombre completo"
                value={newUser.name}
                onChange={(e) => setNewUser({...newUser, name: e.target.value})}
                required
              />
            </div>
            
            <div className="form-group">
              <label htmlFor="userEmail">Email:</label>
              <input
                id="userEmail"
                type="email"
                placeholder="correo@ejemplo.com"
                value={newUser.email}
                onChange={(e) => setNewUser({...newUser, email: e.target.value})}
                required
              />
            </div>
            
            <div className="form-group">
              <label htmlFor="userPassword">Contraseña:</label>
              <input
                id="userPassword"
                type="password"
                placeholder="Contraseña segura"
                value={newUser.password}
                onChange={(e) => setNewUser({...newUser, password: e.target.value})}
                required
              />
            </div>
            
            <button type="submit" disabled={creatingUser}>
              {creatingUser ? 'Creando...' : 'Crear Usuario'}
            </button>
          </form>
          
          {/* Tabla de usuarios */}
          <div className="data-table-container">
            {users.length > 0 ? (
              <table className="data-table">
                <thead>
                  <tr>
                    <th>ID</th>
                    <th>Nombre</th>
                    <th>Email</th>
                    <th>Fecha Creación</th>
                  </tr>
                </thead>
                <tbody>
                  {users.map(user => (
                    <tr key={user.id}>
                      <td>{user.id}</td>
                      <td>{user.name}</td>
                      <td>{user.email}</td>
                      <td>{new Date(user.created_at).toLocaleDateString()}</td>
                    </tr>
                  ))}
                </tbody>
              </table>
            ) : (
              <p className="no-data">No hay usuarios registrados</p>
            )}
          </div>
        </section>

        {/* Sección de Productos */}
        <section className="data-section">
          <h2>Productos ({products.length})</h2>
          
          <form onSubmit={createProduct} className="data-form">
            <div className="form-group">
              <label htmlFor="productName">Nombre:</label>
              <input
                id="productName"
                type="text"
                placeholder="Nombre del producto"
                value={newProduct.name}
                onChange={(e) => setNewProduct({...newProduct, name: e.target.value})}
                required
              />
            </div>
            
            <div className="form-group">
              <label htmlFor="productDescription">Descripción:</label>
              <textarea
                id="productDescription"
                placeholder="Descripción del producto"
                value={newProduct.description}
                onChange={(e) => setNewProduct({...newProduct, description: e.target.value})}
              />
            </div>
            
            <div className="form-group">
              <label htmlFor="productPrice">Precio:</label>
              <input
                id="productPrice"
                type="number"
                step="0.01"
                placeholder="99.99"
                value={newProduct.price}
                onChange={(e) => setNewProduct({...newProduct, price: e.target.value})}
                required
              />
            </div>
            
            <button type="submit" disabled={creatingProduct}>
              {creatingProduct ? 'Creando...' : 'Crear Producto'}
            </button>
          </form>
          
          {/* Tabla de productos */}
          <div className="data-table-container">
            {products.length > 0 ? (
              <table className="data-table">
                <thead>
                  <tr>
                    <th>ID</th>
                    <th>Nombre</th>
                    <th>Descripción</th>
                    <th>Precio</th>
                    <th>Stock</th>
                  </tr>
                </thead>
                <tbody>
                  {products.map(product => (
                    <tr key={product.id}>
                      <td>{product.id}</td>
                      <td>{product.name}</td>
                      <td>{product.description}</td>
                      <td>${product.price.toFixed(2)}</td>
                      <td>{product.stock}</td>
                    </tr>
                  ))}
                </tbody>
              </table>
            ) : (
              <p className="no-data">No hay productos registrados</p>
            )}
          </div>
        </section>
      </main>
      
      <footer>
        <p>AppGestión © {new Date().getFullYear()} - Todos los derechos reservados</p>
      </footer>
    </div>
  );
}

export default App;