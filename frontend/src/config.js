// Configuración simplificada para API Gateway
const getApiUrl = () => {
  // Usar variable de entorno o fallback al origen actual
  return process.env.REACT_APP_API_URL || window.location.origin;
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