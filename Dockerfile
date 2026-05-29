# =========================================
# ETAPA 1: "deps" - solo instala dependencias
# Separamos esta etapa para aprovechar el cache de Docker.
# Si el código cambia pero package.json no, esta etapa no se re-ejecuta.
# =========================================
FROM node:24-alpine AS deps

WORKDIR /app

COPY package*.json ./

RUN npm ci

# =========================================
# ETAPA 2: "builder" - compila React
# Toma el código fuente y las dependencias, y genera la carpeta /dist
# con archivos HTML, CSS y JS estáticos y optimizados.
# =========================================
FROM node:24-alpine AS builder

WORKDIR /app

# Copiamos las dependencias ya instaladas desde la etapa anterior
COPY --from=deps /app/node_modules ./node_modules
COPY . .

# Este argumento permite inyectar la URL del backend en tiempo de BUILD.
# En GitHub Actions este valor vendrá de los secrets/variables del repositorio.
ARG VITE_API_URL=http://localhost:8080
ENV VITE_API_URL=$VITE_API_URL

# npm run build ejecuta Vite, que compila todo y genera la carpeta dist/
RUN npm run build

# =========================================
# ETAPA 3: "production" - Nginx sirve los archivos estáticos
# Esta es la imagen final. No contiene Node.js, ni código fuente,
# ni dependencias. Solo Nginx y la carpeta dist. Es extremadamente liviana.
# =========================================
FROM nginx:alpine AS production

# Eliminamos la configuración default de Nginx y ponemos la nuestra
RUN rm /etc/nginx/conf.d/default.conf

# Configuración personalizada de Nginx
COPY nginx.conf /etc/nginx/conf.d/

# Copiamos SOLO la carpeta dist desde la etapa builder
COPY --from=builder /app/dist /usr/share/nginx/html

# Nginx corre en el puerto 80 por defecto
EXPOSE 80

CMD ["nginx", "-g", "daemon off;"]