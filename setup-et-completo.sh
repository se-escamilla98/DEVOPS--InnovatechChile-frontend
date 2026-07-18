#!/bin/bash
# ================================================================
# EP3 Innovatech Chile - Setup COMPLETO desde cero
# ================================================================
# USO:
#   chmod +x setup-ep3-completo.sh
#   ./setup-ep3-completo.sh "/ruta/al/repo/frontend" ["/ruta/al/repo/backend"]
#
#   El 2º argumento (backend) es opcional: si no se pasa, se asume que
#   frontend y backend son carpetas hermanas (.../algo/frontend y
#   .../algo/backend). Al final el script dispara AMBOS pipelines.
#
# REQUISITOS:
#   1. ~/.aws/credentials configurado con el nuevo lab
#   2. Docker Desktop corriendo
#   3. Ruta al repo del frontend como argumento
#   4. Secrets de AWS actualizados en AMBOS repos de GitHub
# ================================================================
set -e

# ─── Colores ───
GREEN='\033[0;32m'; BLUE='\033[0;34m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
ok()   { echo -e "${GREEN}[OK]${NC} $1"; }
info() { echo -e "${BLUE}[..] $1${NC}"; }
warn() { echo -e "${YELLOW}[!!] $1${NC}"; }
die()  { echo -e "${RED}[ERROR] $1${NC}"; exit 1; }

FRONTEND_REPO="$1"
REGION="us-east-1"
AZ_A="us-east-1a"
AZ_B="us-east-1b"
DB_PASSWORD="Innov@tech2025"

# ─── Validaciones ───
echo ""
echo "======================================================="
echo "  EP3 Innovatech Chile — Setup Completo"
echo "======================================================="
echo ""

[ -z "$FRONTEND_REPO" ] && die "Falta la ruta del repo frontend.\nUso: ./setup-ep3-completo.sh \"/ruta/repo/frontend\""
[ ! -f "$FRONTEND_REPO/nginx.conf" ] && die "No se encontró nginx.conf en: $FRONTEND_REPO"
[ ! -f "$FRONTEND_REPO/Dockerfile" ] && die "No se encontró Dockerfile en: $FRONTEND_REPO"

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text 2>/dev/null) \
  || die "Sin credenciales AWS. Configura ~/.aws/credentials primero."

docker info > /dev/null 2>&1 || die "Docker Desktop no está corriendo. Ábrelo primero."

LABROL_ARN="arn:aws:iam::${ACCOUNT_ID}:role/LabRole"
ECR_BASE="${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com"

ok "Account ID: $ACCOUNT_ID"
ok "LabRole: $LABROL_ARN"
ok "ECR: $ECR_BASE"
ok "Frontend repo: $FRONTEND_REPO"
ok "Docker Desktop: corriendo"
echo ""
warn "Este proceso tarda ~15-20 minutos en total."
warn "NO cierres la terminal ni el Learner Lab."
echo ""
read -p "¿Todo listo? Presiona ENTER para comenzar..." _

echo ""

# ================================================================
# FASE 1: RED (VPC, subredes, IGW, NAT, SGs)
# ================================================================
info "FASE 1/8: Creando infraestructura de red..."

VPC_ID=$(aws ec2 create-vpc --cidr-block 10.0.0.0/16 --region $REGION \
  --tag-specifications 'ResourceType=vpc,Tags=[{Key=Name,Value=innovatech-vpc}]' \
  --query 'Vpc.VpcId' --output text)
aws ec2 modify-vpc-attribute --vpc-id $VPC_ID --enable-dns-support --region $REGION
aws ec2 modify-vpc-attribute --vpc-id $VPC_ID --enable-dns-hostnames --region $REGION

IGW_ID=$(aws ec2 create-internet-gateway --region $REGION \
  --tag-specifications 'ResourceType=internet-gateway,Tags=[{Key=Name,Value=innovatech-igw}]' \
  --query 'InternetGateway.InternetGatewayId' --output text)
aws ec2 attach-internet-gateway --vpc-id $VPC_ID --internet-gateway-id $IGW_ID --region $REGION

PUB_A=$(aws ec2 create-subnet --vpc-id $VPC_ID --cidr-block 10.0.1.0/24 \
  --availability-zone $AZ_A --region $REGION \
  --tag-specifications 'ResourceType=subnet,Tags=[{Key=Name,Value=innovatech-public-a}]' \
  --query 'Subnet.SubnetId' --output text)
aws ec2 modify-subnet-attribute --subnet-id $PUB_A --map-public-ip-on-launch --region $REGION

PUB_B=$(aws ec2 create-subnet --vpc-id $VPC_ID --cidr-block 10.0.3.0/24 \
  --availability-zone $AZ_B --region $REGION \
  --tag-specifications 'ResourceType=subnet,Tags=[{Key=Name,Value=innovatech-public-b}]' \
  --query 'Subnet.SubnetId' --output text)
aws ec2 modify-subnet-attribute --subnet-id $PUB_B --map-public-ip-on-launch --region $REGION

PRIV_A=$(aws ec2 create-subnet --vpc-id $VPC_ID --cidr-block 10.0.2.0/24 \
  --availability-zone $AZ_A --region $REGION \
  --tag-specifications 'ResourceType=subnet,Tags=[{Key=Name,Value=innovatech-private-a}]' \
  --query 'Subnet.SubnetId' --output text)

PRIV_B=$(aws ec2 create-subnet --vpc-id $VPC_ID --cidr-block 10.0.4.0/24 \
  --availability-zone $AZ_B --region $REGION \
  --tag-specifications 'ResourceType=subnet,Tags=[{Key=Name,Value=innovatech-private-b}]' \
  --query 'Subnet.SubnetId' --output text)

EIP_ID=$(aws ec2 allocate-address --domain vpc --region $REGION --query 'AllocationId' --output text)
NAT_ID=$(aws ec2 create-nat-gateway --subnet-id $PUB_A --allocation-id $EIP_ID \
  --region $REGION \
  --tag-specifications 'ResourceType=natgateway,Tags=[{Key=Name,Value=innovatech-nat}]' \
  --query 'NatGateway.NatGatewayId' --output text)
echo -n "  Esperando NAT Gateway (puede tardar 2 min)..."
aws ec2 wait nat-gateway-available --nat-gateway-ids $NAT_ID --region $REGION
echo " listo."

PUB_RT=$(aws ec2 create-route-table --vpc-id $VPC_ID --region $REGION \
  --tag-specifications 'ResourceType=route-table,Tags=[{Key=Name,Value=innovatech-public-rt}]' \
  --query 'RouteTable.RouteTableId' --output text)
aws ec2 create-route --route-table-id $PUB_RT --destination-cidr-block 0.0.0.0/0 --gateway-id $IGW_ID --region $REGION > /dev/null
aws ec2 associate-route-table --route-table-id $PUB_RT --subnet-id $PUB_A --region $REGION > /dev/null
aws ec2 associate-route-table --route-table-id $PUB_RT --subnet-id $PUB_B --region $REGION > /dev/null

PRIV_RT=$(aws ec2 create-route-table --vpc-id $VPC_ID --region $REGION \
  --tag-specifications 'ResourceType=route-table,Tags=[{Key=Name,Value=innovatech-private-rt}]' \
  --query 'RouteTable.RouteTableId' --output text)
aws ec2 create-route --route-table-id $PRIV_RT --destination-cidr-block 0.0.0.0/0 --nat-gateway-id $NAT_ID --region $REGION > /dev/null
aws ec2 associate-route-table --route-table-id $PRIV_RT --subnet-id $PRIV_A --region $REGION > /dev/null
aws ec2 associate-route-table --route-table-id $PRIV_RT --subnet-id $PRIV_B --region $REGION > /dev/null

SG_ALB=$(aws ec2 create-security-group --group-name SG_ALB \
  --description "Trafico publico ALB frontend" --vpc-id $VPC_ID --region $REGION \
  --query 'GroupId' --output text)
aws ec2 authorize-security-group-ingress --group-id $SG_ALB --protocol tcp --port 80 --cidr 0.0.0.0/0 --region $REGION > /dev/null

SG_FRONT=$(aws ec2 create-security-group --group-name SG_FRONT \
  --description "Fargate frontend" --vpc-id $VPC_ID --region $REGION \
  --query 'GroupId' --output text)
aws ec2 authorize-security-group-ingress --group-id $SG_FRONT --protocol tcp --port 80 --source-group $SG_ALB --region $REGION > /dev/null

SG_ALB_BACK=$(aws ec2 create-security-group --group-name SG_ALB_BACK \
  --description "ALB interno backend" --vpc-id $VPC_ID --region $REGION \
  --query 'GroupId' --output text)
aws ec2 authorize-security-group-ingress --group-id $SG_ALB_BACK --protocol tcp --port 8080 --source-group $SG_FRONT --region $REGION > /dev/null

SG_BACK=$(aws ec2 create-security-group --group-name SG_BACK \
  --description "Fargate backend" --vpc-id $VPC_ID --region $REGION \
  --query 'GroupId' --output text)
aws ec2 authorize-security-group-ingress --group-id $SG_BACK --protocol tcp --port 8080 --source-group $SG_ALB_BACK --region $REGION > /dev/null

ok "FASE 1 completa: VPC=$VPC_ID | Subredes x4 | NAT | IGW | 4 SGs"

# ================================================================
# FASE 2: ECR + IMAGEN BACKEND
# ================================================================
info "FASE 2/8: ECR e imagen del backend..."

aws ecr create-repository --repository-name innovatech-frontend --region $REGION > /dev/null 2>&1 || warn "Repo frontend ya existia"
aws ecr create-repository --repository-name innovatech-backend --region $REGION > /dev/null 2>&1 || warn "Repo backend ya existia"

aws ecr get-login-password --region $REGION | docker login --username AWS --password-stdin $ECR_BASE

docker pull seescamilla/innovatech-backend:latest
docker tag seescamilla/innovatech-backend:latest $ECR_BASE/innovatech-backend:latest
docker push $ECR_BASE/innovatech-backend:latest

ok "FASE 2 completa: ECR creado + backend en ECR"

# ================================================================
# FASE 3: ALB INTERNO BACKEND (necesitamos el DNS para el nginx.conf)
# ================================================================
info "FASE 3/8: ALB interno del backend..."

ALB_BACK_ARN=$(aws elbv2 create-load-balancer --name innovatech-alb-backend \
  --type application --scheme internal \
  --subnets $PRIV_A $PRIV_B \
  --security-groups $SG_ALB_BACK --region $REGION \
  --query 'LoadBalancers[0].LoadBalancerArn' --output text)
echo -n "  Esperando ALB backend (puede tardar 2 min)..."
aws elbv2 wait load-balancer-available --load-balancer-arns $ALB_BACK_ARN --region $REGION
echo " listo."

ALB_BACK_DNS=$(aws elbv2 describe-load-balancers \
  --load-balancer-arns $ALB_BACK_ARN --region $REGION \
  --query 'LoadBalancers[0].DNSName' --output text)

TG_BACK_ARN=$(MSYS_NO_PATHCONV=1 aws elbv2 create-target-group \
  --name innovatech-tg-backend \
  --protocol HTTP --port 8080 --vpc-id $VPC_ID --target-type ip \
  --health-check-path /health --health-check-interval-seconds 15 \
  --region $REGION --query 'TargetGroups[0].TargetGroupArn' --output text)

aws elbv2 create-listener --load-balancer-arn $ALB_BACK_ARN \
  --protocol HTTP --port 8080 \
  --default-actions Type=forward,TargetGroupArn=$TG_BACK_ARN \
  --region $REGION > /dev/null

ok "FASE 3 completa: ALB backend DNS=$ALB_BACK_DNS"

# ================================================================
# FASE 4: ECS + BACKEND SERVICE
# ================================================================
info "FASE 4/8: Cluster ECS y servicio backend..."

aws ecs create-cluster --cluster-name innovatech-cluster \
  --capacity-providers FARGATE FARGATE_SPOT --region $REGION > /dev/null

# Task Definition backend (escrita a archivo para evitar problemas de escaping)
cat > backend-td.json << TDJSON
{
  "family": "innovatech-backend",
  "networkMode": "awsvpc",
  "requiresCompatibilities": ["FARGATE"],
  "cpu": "1024",
  "memory": "2048",
  "taskRoleArn": "${LABROL_ARN}",
  "executionRoleArn": "${LABROL_ARN}",
  "containerDefinitions": [
    {
      "name": "backend",
      "image": "${ECR_BASE}/innovatech-backend:latest",
      "essential": true,
      "portMappings": [{"containerPort": 8080, "protocol": "tcp", "name": "backend-8080"}],
      "environment": [
        {"name": "DB_HOST", "value": "localhost"},
        {"name": "DB_PORT", "value": "5432"},
        {"name": "DB_NAME", "value": "innovatech"},
        {"name": "DB_USER", "value": "innovatech_user"},
        {"name": "DB_PASSWORD", "value": "${DB_PASSWORD}"}
      ],
      "dependsOn": [{"containerName": "postgres", "condition": "HEALTHY"}],
      "logConfiguration": {
        "logDriver": "awslogs",
        "options": {
          "awslogs-group": "/ecs/innovatech-backend",
          "awslogs-region": "${REGION}",
          "awslogs-stream-prefix": "backend",
          "awslogs-create-group": "true"
        }
      }
    },
    {
      "name": "postgres",
      "image": "postgres:15",
      "essential": true,
      "portMappings": [{"containerPort": 5432, "protocol": "tcp"}],
      "environment": [
        {"name": "POSTGRES_DB", "value": "innovatech"},
        {"name": "POSTGRES_USER", "value": "innovatech_user"},
        {"name": "POSTGRES_PASSWORD", "value": "${DB_PASSWORD}"}
      ],
      "healthCheck": {
        "command": ["CMD-SHELL", "pg_isready -U innovatech_user -d innovatech"],
        "interval": 10,
        "timeout": 5,
        "retries": 5,
        "startPeriod": 15
      },
      "logConfiguration": {
        "logDriver": "awslogs",
        "options": {
          "awslogs-group": "/ecs/innovatech-backend",
          "awslogs-region": "${REGION}",
          "awslogs-stream-prefix": "postgres",
          "awslogs-create-group": "true"
        }
      }
    }
  ]
}
TDJSON

aws ecs register-task-definition --cli-input-json file://backend-td.json --region $REGION > /dev/null
rm -f backend-td.json

aws ecs create-service \
  --cluster innovatech-cluster \
  --service-name backend-service \
  --task-definition innovatech-backend \
  --desired-count 1 \
  --launch-type FARGATE \
  --network-configuration "{\"awsvpcConfiguration\":{\"subnets\":[\"$PRIV_A\"],\"securityGroups\":[\"$SG_BACK\"],\"assignPublicIp\":\"DISABLED\"}}" \
  --load-balancers "[{\"targetGroupArn\":\"$TG_BACK_ARN\",\"containerName\":\"backend\",\"containerPort\":8080}]" \
  --region $REGION > /dev/null

info "Esperando que el backend esté healthy (~3-4 min, postgres tarda en arrancar)..."
ELAPSED=0
while true; do
  STATE=$(aws elbv2 describe-target-health --target-group-arn "$TG_BACK_ARN" \
    --region $REGION --query 'TargetHealthDescriptions[0].TargetHealth.State' \
    --output text 2>/dev/null || echo "pending")
  printf "\r  Estado: %-12s (%ss)" "$STATE" "$ELAPSED"
  if [ "$STATE" = "healthy" ]; then
    echo ""
    ok "Backend healthy"
    break
  fi
  if [ $ELAPSED -ge 360 ]; then
    echo ""
    die "Timeout (6 min). Revisa ECS Console → backend-service → Events para ver el error."
  fi
  sleep 15
  ELAPSED=$((ELAPSED + 15))
done

ok "FASE 4 completa: cluster ECS + backend-service corriendo"

# ================================================================
# FASE 5: IMAGEN FRONTEND (con el DNS real del ALB backend)
# ================================================================
info "FASE 5/8: Buildear frontend con nginx.conf actualizado..."
info "  ALB backend DNS: $ALB_BACK_DNS"

# Backup
cp "$FRONTEND_REPO/nginx.conf" "$FRONTEND_REPO/nginx.conf.bak"

# Escribir nginx.conf con el DNS dinámico
cat > "$FRONTEND_REPO/nginx.conf" << NGINXEOF
server {
    listen 80;
    root /usr/share/nginx/html;
    index index.html;

    resolver 169.254.169.253 valid=30s ipv6=off;

    location /health {
        set \$backend "$ALB_BACK_DNS";
        proxy_pass http://\$backend:8080/health;
        proxy_set_header Host \$backend;
        proxy_connect_timeout 5s;
        proxy_read_timeout 10s;
    }

    location /api/ {
        set \$backend "$ALB_BACK_DNS";
        proxy_pass http://\$backend:8080;
        proxy_set_header Host \$backend;
        proxy_connect_timeout 5s;
        proxy_read_timeout 10s;
    }

    location / {
        try_files \$uri \$uri/ /index.html;
    }

    location ~* \.(js|css|png|jpg|jpeg|gif|ico|svg)\$ {
        expires 1y;
        add_header Cache-Control "public, immutable";
    }
}
NGINXEOF

ok "nginx.conf actualizado con: $ALB_BACK_DNS"

# Build y push frontend
cd "$FRONTEND_REPO"
docker build --no-cache --build-arg VITE_API_URL= -t innovatech-frontend:latest .
docker tag innovatech-frontend:latest $ECR_BASE/innovatech-frontend:v1
docker push $ECR_BASE/innovatech-frontend:v1
cd - > /dev/null

ok "FASE 5 completa: imagen frontend en ECR ($ECR_BASE/innovatech-frontend:v1)"

# ================================================================
# FASE 6: ALB PÚBLICO FRONTEND + SERVICIO FRONTEND
# ================================================================
info "FASE 6/8: ALB público y servicio frontend..."

ALB_FRONT_ARN=$(aws elbv2 create-load-balancer --name innovatech-alb-frontend \
  --type application --scheme internet-facing \
  --subnets $PUB_A $PUB_B \
  --security-groups $SG_ALB --region $REGION \
  --query 'LoadBalancers[0].LoadBalancerArn' --output text)
echo -n "  Esperando ALB frontend (puede tardar 2 min)..."
aws elbv2 wait load-balancer-available --load-balancer-arns $ALB_FRONT_ARN --region $REGION
echo " listo."

ALB_FRONT_DNS=$(aws elbv2 describe-load-balancers \
  --load-balancer-arns $ALB_FRONT_ARN --region $REGION \
  --query 'LoadBalancers[0].DNSName' --output text)

TG_FRONT_ARN=$(MSYS_NO_PATHCONV=1 aws elbv2 create-target-group \
  --name innovatech-tg-frontend \
  --protocol HTTP --port 80 --vpc-id $VPC_ID --target-type ip \
  --health-check-path / --health-check-interval-seconds 15 \
  --region $REGION --query 'TargetGroups[0].TargetGroupArn' --output text)

aws elbv2 create-listener --load-balancer-arn $ALB_FRONT_ARN \
  --protocol HTTP --port 80 \
  --default-actions Type=forward,TargetGroupArn=$TG_FRONT_ARN \
  --region $REGION > /dev/null

# Task Definition frontend
cat > frontend-td.json << TDJSON
{
  "family": "innovatech-frontend",
  "networkMode": "awsvpc",
  "requiresCompatibilities": ["FARGATE"],
  "cpu": "256",
  "memory": "512",
  "taskRoleArn": "${LABROL_ARN}",
  "executionRoleArn": "${LABROL_ARN}",
  "containerDefinitions": [{
    "name": "frontend",
    "image": "${ECR_BASE}/innovatech-frontend:v1",
    "essential": true,
    "portMappings": [{"containerPort": 80, "protocol": "tcp"}],
    "logConfiguration": {
      "logDriver": "awslogs",
      "options": {
        "awslogs-group": "/ecs/innovatech-frontend",
        "awslogs-region": "${REGION}",
        "awslogs-stream-prefix": "frontend",
        "awslogs-create-group": "true"
      }
    }
  }]
}
TDJSON

aws ecs register-task-definition --cli-input-json file://frontend-td.json --region $REGION > /dev/null
rm -f frontend-td.json

aws ecs create-service \
  --cluster innovatech-cluster \
  --service-name frontend-service \
  --task-definition innovatech-frontend \
  --desired-count 1 \
  --launch-type FARGATE \
  --network-configuration "{\"awsvpcConfiguration\":{\"subnets\":[\"$PUB_A\"],\"securityGroups\":[\"$SG_FRONT\"],\"assignPublicIp\":\"ENABLED\"}}" \
  --load-balancers "[{\"targetGroupArn\":\"$TG_FRONT_ARN\",\"containerName\":\"frontend\",\"containerPort\":80}]" \
  --region $REGION > /dev/null

ok "FASE 6 completa: ALB frontend=$ALB_FRONT_DNS"

# ================================================================
# FASE 7: AUTOSCALING
# ================================================================
info "FASE 7/8: Configurando autoscaling..."

for SVC in backend-service frontend-service; do
  aws application-autoscaling register-scalable-target \
    --service-namespace ecs \
    --resource-id service/innovatech-cluster/$SVC \
    --scalable-dimension ecs:service:DesiredCount \
    --min-capacity 1 --max-capacity 3 --region $REGION

  aws application-autoscaling put-scaling-policy \
    --service-namespace ecs \
    --resource-id service/innovatech-cluster/$SVC \
    --scalable-dimension ecs:service:DesiredCount \
    --policy-name "${SVC}-cpu-tracking" \
    --policy-type TargetTrackingScaling \
    --target-tracking-scaling-policy-configuration '{
      "TargetValue": 50.0,
      "PredefinedMetricSpecification": {
        "PredefinedMetricType": "ECSServiceAverageCPUUtilization"
      },
      "ScaleOutCooldown": 60,
      "ScaleInCooldown": 120
    }' --region $REGION > /dev/null
done

ok "FASE 7 completa: autoscaling Target Tracking 50% CPU en ambos servicios"

# ================================================================
# FASE 8: ESPERAR FRONTEND + GUARDAR IDs
# ================================================================
info "FASE 8/8: Esperando que el frontend esté healthy..."

ELAPSED=0
while true; do
  STATE=$(aws elbv2 describe-target-health --target-group-arn "$TG_FRONT_ARN" \
    --region $REGION --query 'TargetHealthDescriptions[0].TargetHealth.State' \
    --output text 2>/dev/null || echo "pending")
  printf "\r  Estado: %-12s (%ss)" "$STATE" "$ELAPSED"
  if [ "$STATE" = "healthy" ]; then
    echo ""
    ok "Frontend healthy"
    break
  fi
  if [ $ELAPSED -ge 240 ]; then
    echo ""
    warn "El frontend aún no está healthy. Puede tardar unos minutos más. Revisa en la consola."
    break
  fi
  sleep 15
  ELAPSED=$((ELAPSED + 15))
done

# Guardar todos los IDs
cat > infra-ids.txt << EOF
ACCOUNT_ID=$ACCOUNT_ID
REGION=$REGION
VPC_ID=$VPC_ID
IGW_ID=$IGW_ID
PUB_A=$PUB_A
PUB_B=$PUB_B
PRIV_A=$PRIV_A
PRIV_B=$PRIV_B
NAT_ID=$NAT_ID
SG_ALB=$SG_ALB
SG_FRONT=$SG_FRONT
SG_ALB_BACK=$SG_ALB_BACK
SG_BACK=$SG_BACK
ALB_BACK_ARN=$ALB_BACK_ARN
ALB_BACK_DNS=$ALB_BACK_DNS
TG_BACK_ARN=$TG_BACK_ARN
ALB_FRONT_ARN=$ALB_FRONT_ARN
ALB_FRONT_DNS=$ALB_FRONT_DNS
TG_FRONT_ARN=$TG_FRONT_ARN
LABROL_ARN=$LABROL_ARN
ECR_BASE=$ECR_BASE
EOF

# ================================================================
# DISPARAR AMBOS PIPELINES (frontend y backend)
# ================================================================
# El BACKEND_REPO se toma del 2º argumento; si no se pasa, se deriva
# asumiendo que frontend y backend son carpetas hermanas
# (ej: .../innovatech-devops/frontend  y  .../innovatech-devops/backend)
BACKEND_REPO="${2:-$(dirname "$FRONTEND_REPO")/backend}"

# --- Frontend: commitear el nginx.conf actualizado y pushear ---
info "Disparando pipeline del FRONTEND..."
cd "$FRONTEND_REPO"
git add nginx.conf
git commit -m "ci: actualizar nginx.conf con nuevo ALB DNS (nuevo Learner Lab)" \
  || warn "Sin cambios para commitear en el frontend"
git push origin deploy \
  && ok "Push al frontend OK — pipeline disparado" \
  || warn "No se pudo pushear el frontend. Hazlo manualmente si es necesario."
cd - > /dev/null

# --- Backend: commit vacío para disparar su pipeline ---
# El código del backend no cambió, así que se usa un commit vacío
# (--allow-empty) solo para detonar el workflow de GitHub Actions.
if [ -d "$BACKEND_REPO/.git" ]; then
  info "Disparando pipeline del BACKEND ($BACKEND_REPO)..."
  cd "$BACKEND_REPO"
  git commit --allow-empty -m "ci: redeploy backend (nuevo Learner Lab)" \
    || warn "No se pudo crear el commit en el backend"
  git push origin deploy \
    && ok "Push al backend OK — pipeline disparado" \
    || warn "No se pudo pushear el backend. Hazlo manualmente si es necesario."
  cd - > /dev/null
else
  warn "No se encontró repo git del backend en: $BACKEND_REPO"
  warn "Pásalo como 2º argumento:  ./setup-et-completo.sh \"/ruta/frontend\" \"/ruta/backend\""
fi

# ================================================================
# RESUMEN FINAL
# ================================================================
echo ""
echo "======================================================="
echo -e "${GREEN}  ¡SETUP EP3 COMPLETO!${NC}"
echo "======================================================="
echo ""
echo "  URL DE LA APLICACIÓN:"
echo ""
echo -e "  ${BLUE}http://$ALB_FRONT_DNS${NC}"
echo ""
echo "  IDs guardados en: infra-ids.txt"
echo ""
echo "-------------------------------------------------------"
echo "  IMPORTANTE ANTES DE PRESENTAR:"
echo "-------------------------------------------------------"
echo ""
echo "  1. Verifica que la app funciona en el navegador"
echo "     → debe mostrar 'Backend Innovatech funcionando'"
echo ""
echo "  2. Actualiza los GitHub Secrets con las credenciales"
echo "     nuevas del Lab (en AMBOS repos):"
echo "       AWS_ACCESS_KEY_ID"
echo "       AWS_SECRET_ACCESS_KEY"
echo "       AWS_SESSION_TOKEN"
echo ""
echo "  3. Los pipelines de frontend Y backend ya fueron"
echo "     disparados por este script. Verifica en GitHub"
echo "     Actions que ambos terminen en verde."
echo ""
echo "-------------------------------------------------------"
echo "  CRÉDITOS del nuevo Lab (para renovar en GitHub):"
echo "-------------------------------------------------------"
echo "  cat ~/.aws/credentials"
echo ""
