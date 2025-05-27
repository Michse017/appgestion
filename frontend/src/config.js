const getApiUrl = () => {
  // Mostrar log para diagnóstico en todas las situaciones
  console.log('Environment:', process.env.NODE_ENV);
  console.log('REACT_APP_API_URL:', process.env.REACT_APP_API_URL);
  
  // Usar API URL configurada o fallback
  const apiUrl = process.env.REACT_APP_API_URL || window.location.origin;
  console.log('Using API URL:', apiUrl);
  return apiUrl;
};

export const API_BASE_URL = getApiUrl();
export const USER_SERVICE_URL = `${API_BASE_URL}/users`;
export const PRODUCT_SERVICE_URL = `${API_BASE_URL}/products`;

// Solo log en desarrollo
if (process.env.NODE_ENV === 'development') {
  console.log('API Configuration:', {
    apiBaseUrl: API_BASE_URL,
    userServiceUrl: USER_SERVICE_URL,
    productServiceUrl: PRODUCT_SERVICE_URL
  });
}