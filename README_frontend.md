# Innovatech Chile — Frontend

Aplicación React con Vite servida por Nginx, desplegada en AWS ECS Fargate como parte del EP3 de ISY1101 (Introducción a Herramientas DevOps, DuocUC 2025).

## Stack tecnológico

- **Framework**: React 19 + Vite
- **Servidor web**: Nginx (Alpine)
- **Contenedor**: Docker (multi-stage build)
- **Orquestación**: AWS ECS + Fargate
- **Registro de imágenes**: Amazon ECR
- **CI/CD**: GitHub Actions
- **Logs**: Amazon CloudWatch

## Arquitectura en producción

```
Internet
    ↓
ALB Público (:80) — innovatech-alb-frontend
    ↓
Fargate Task (SG_FRONT — subred pública 10.0.1.0/24)
    └── Contenedor: frontend (Nginx :80)
              ↓ proxy_pass (DNS dinámico con resolver 169.254.169.253)
        ALB Interno Backend (:8080)
              ↓
        Fargate Task Backend
```

### Decisión de diseño: proxy en Nginx

`VITE_API_URL` se deja vacío (`""`), por lo que el JavaScript compilado usa **rutas relativas** (`/health`, `/api/productos`). El navegador las envía al mismo origen (el ALB público), y Nginx las redirige internamente al ALB del backend dentro de la VPC.

**Ventajas:**
- Elimina CORS por completo (mismo origen)
- El backend nunca queda expuesto a internet
- No se necesita hardcodear IPs ni URLs en el frontend

## Ejecución local

```bash
# Clonar el repositorio
git clone https://github.com/se-escamilla98/DEVOPS--InnovatechChile-frontend.git
cd DEVOPS--InnovatechChile-frontend

# Instalar dependencias
npm install

# Ejecutar en modo desarrollo (apunta a backend local en :8080)
npm run dev
```

El archivo `.env` define:
```env
VITE_API_URL=http://localhost:8080
```

En desarrollo, el browser llama directamente al backend local. En producción, `VITE_API_URL=""` y Nginx hace el proxy.

## Build de la imagen Docker

```bash
# Build para producción (VITE_API_URL vacío → proxy Nginx)
docker build --no-cache --build-arg VITE_API_URL= -t innovatech-frontend:latest .
```

El Dockerfile usa **multi-stage build**:
- Stage `deps`: instala dependencias con `npm ci`
- Stage `builder`: compila con `npm run build` usando `VITE_API_URL` como `ARG`
- Stage `production`: copia el `dist/` a Nginx Alpine

## Configuración de Nginx

El archivo `nginx.conf` configura:

1. **Proxy dinámico al backend** usando el resolver de AWS en Fargate (`169.254.169.253`) para resolver el DNS del ALB interno en runtime:

```nginx
resolver 169.254.169.253 valid=30s ipv6=off;

location /health {
    set $backend "internal-innovatech-alb-backend-1722042669.us-east-1.elb.amazonaws.com";
    proxy_pass http://$backend:8080/health;
}

location /api/ {
    set $backend "internal-innovatech-alb-backend-1722042669.us-east-1.elb.amazonaws.com";
    proxy_pass http://$backend:8080/api/;
}
```

2. **React Router** con `try_files $uri $uri/ /index.html` para que las rutas del SPA funcionen correctamente.

3. **Cache agresivo** para assets compilados por Vite (tienen hash único en el nombre).

## Pipeline CI/CD (GitHub Actions)

Se activa automáticamente con cada `push` a la rama `deploy`.

### Pasos del pipeline

| Paso | Acción | Descripción |
|------|--------|-------------|
| 1 | `actions/checkout@v4` | Descarga el código |
| 2 | `configure-aws-credentials@v4` | Configura credenciales AWS |
| 3 | `amazon-ecr-login@v2` | Login en Amazon ECR |
| 4 | `docker build + push` | Build con `--build-arg VITE_API_URL=` (vacío), tags SHA + latest |
| 5 | `aws ecs update-service` | Rolling deploy en ECS sin downtime |

### Secrets requeridos en GitHub

| Secret | Descripción |
|--------|-------------|
| `AWS_ACCESS_KEY_ID` | Clave de acceso del Learner Lab |
| `AWS_SECRET_ACCESS_KEY` | Clave secreta del Learner Lab |
| `AWS_SESSION_TOKEN` | Token de sesión (se renueva con cada sesión del Lab) |
| `AWS_ACCOUNT_ID` | `234744815650` |
| `AWS_REGION` | `us-east-1` |

> ⚠️ Los tres primeros secrets son temporales y deben actualizarse cada vez que se reinicia el Learner Lab.

## Despliegue en AWS ECS

### Recursos desplegados

| Recurso | Valor |
|---------|-------|
| Clúster | `innovatech-cluster` |
| Servicio | `frontend-service` |
| Task Definition | `innovatech-frontend:4` |
| Imagen ECR | `234744815650.dkr.ecr.us-east-1.amazonaws.com/innovatech-frontend:v4` |
| Subred | Pública (`subnet-01185930d85bb5362`) |
| Security Group | `SG_FRONT` (sg-009c0a8d58abb736f) |
| ALB público | `innovatech-alb-frontend` (`:80`) |
| URL pública | `http://innovatech-alb-frontend-281708325.us-east-1.elb.amazonaws.com` |

### Autoscaling

- **Tipo**: Target Tracking
- **Métrica**: `ECSServiceAverageCPUUtilization`
- **Umbral**: 50% CPU
- **Mínimo**: 1 tarea | **Máximo**: 3 tareas

### Logs

Los logs se envían automáticamente a CloudWatch:
- **Log Group**: `/ecs/innovatech-frontend`
- **Streams**: `frontend/frontend/<task-id>`

## URL de la aplicación

```
http://innovatech-alb-frontend-281708325.us-east-1.elb.amazonaws.com
```

> La app requiere que el Learner Lab esté activo y las credenciales vigentes.

## Autores

- **Sebastián Escamilla** — se.escamilla@duocuc.cl
- **Livan Sepúlveda**

DuocUC — Analista Programador — ISY1101 Introducción a Herramientas DevOps — 2025