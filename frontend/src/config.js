// Configuración dinámica de API
const getApiUrl = () => {
  // En producción, usar la variable de entorno
  if (process.env.NODE_ENV === 'production' && process.env.REACT_APP_API_URL) {
    return process.env.REACT_APP_API_URL;
  }
  
  // En desarrollo, usar localhost con nginx
  if (process.env.NODE_ENV === 'development') {
    return 'http://localhost';
  }
  
  // Fallback para CloudFront
  return window.location.origin;
};

export const API_BASE_URL = getApiUrl();
export const USER_SERVICE_URL = `${API_BASE_URL}/users`;
export const PRODUCT_SERVICE_URL = `${API_BASE_URL}/products`;

console.log('API Configuration:', {
  environment: process.env.NODE_ENV,
  apiBaseUrl: API_BASE_URL,
  userServiceUrl: USER_SERVICE_URL,
  productServiceUrl: PRODUCT_SERVICE_URL
});