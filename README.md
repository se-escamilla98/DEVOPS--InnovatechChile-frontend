# Innovatech Chile — Frontend

Aplicación web desarrollada con React y Vite, containerizada con Docker usando Nginx como servidor de producción, y desplegada automáticamente en AWS EC2 mediante GitHub Actions.

## Tecnologías utilizadas

- React 18 + Vite
- Nginx (servidor de producción)
- Docker + Docker Compose
- GitHub Actions (CI/CD)
- AWS EC2

## Arquitectura

El frontend corre en una subred pública de AWS, accesible desde Internet mediante los puertos 80 y 443. Se comunica con el backend desplegado en la subred privada mediante el puerto 8080, respetando las políticas de seguridad definidas en los Security Groups.

```
Internet → Frontend:80 (subred pública) → Backend:8080 (subred privada)
```

## Estructura del proyecto

```
frontend/
├── src/
│   └── App.jsx           # Componente principal con consumo de API
├── Dockerfile            # Multi-stage build: deps → builder → production (Nginx)
├── docker-compose.yml    # Configuración del contenedor frontend
├── nginx.conf            # Configuración personalizada de Nginx
├── .dockerignore         # Excluye node_modules, dist y .env
├── .env                  # Variables de entorno locales (no se sube a GitHub)
└── .github/
    └── workflows/
        └── deploy.yml    # Pipeline CI/CD
```

## Variables de entorno

| Variable | Descripción | Valor por defecto |
|----------|-------------|-------------------|
| `VITE_API_URL` | URL del backend | `http://localhost:8080` |

## Cómo correr el proyecto localmente

### Requisitos previos
- Docker Desktop instalado
- Git
- Backend corriendo en `http://localhost:8080`

### Pasos

1. Clona el repositorio:
```bash
git clone https://github.com/se-escamilla98/DEVOPS--InnovatechChile-frontend.git
cd DEVOPS--InnovatechChile-frontend
```

2. Crea el archivo de variables de entorno:
```bash
cp .env.example .env
```

3. Levanta el contenedor:
```bash
docker compose up --build
```

4. Abre el navegador en:
```
http://localhost
```

## Pipeline CI/CD

El pipeline se activa automáticamente con cada push a la rama `deploy`.

```
push a rama deploy
        ↓
GitHub Actions (ubuntu-latest)
        ↓
Checkout código
        ↓
Login en Docker Hub
        ↓
Build imagen Docker (3 etapas: deps → builder → Nginx)
        ↓
Push imagen → seescamilla/innovatech-frontend:latest
        ↓
SSH a EC2 → docker pull → docker compose up -d
```

### Secrets requeridos en GitHub

| Secret | Descripción |
|--------|-------------|
| `DOCKER_USERNAME` | Usuario de Docker Hub |
| `DOCKER_PASSWORD` | Access token de Docker Hub |
| `BACKEND_URL` | URL del backend en EC2 (IP privada) |
| `EC2_HOST` | IP pública de la instancia EC2 |
| `EC2_USER` | Usuario SSH de EC2 |
| `EC2_KEY` | Llave privada SSH |

## Decisiones técnicas

**¿Por qué Dockerfile con 3 etapas?**
React necesita compilarse antes de servirse. La etapa `deps` instala dependencias, la etapa `builder` compila el proyecto con Vite generando la carpeta `dist`, y la etapa `production` usa Nginx para servir únicamente los archivos estáticos. La imagen final no contiene Node.js ni el código fuente, lo que la hace extremadamente liviana y segura.

**¿Por qué Nginx en producción?**
Nginx es un servidor web de alto rendimiento diseñado para servir archivos estáticos de forma eficiente. Es el estándar de la industria para servir aplicaciones React en producción, mucho más eficiente que el servidor de desarrollo de Vite que está pensado solo para desarrollo local.

**¿Por qué VITE_API_URL como argumento de build?**
Vite compila el código fuente en tiempo de build, no en runtime. Esto significa que la URL del backend debe conocerse al momento de construir la imagen. Al inyectarla como argumento de build desde GitHub Actions, la imagen queda configurada con la IP correcta del backend en AWS sin necesidad de hardcodear valores en el código.

**¿Por qué rama deploy como trigger?**
Permite trabajar libremente en la rama main sin disparar despliegues accidentales. Solo cuando el código está revisado y listo se hace merge o push a deploy, garantizando que solo código estable llega a producción.

**¿Por qué solo el Frontend es accesible desde Internet?**
Por seguridad. El Backend y la base de datos viven en subredes privadas, inaccesibles directamente desde Internet. Todo el tráfico externo entra por el Frontend, que actúa como punto de entrada único. Esto reduce la superficie de ataque del sistema.