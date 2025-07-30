#!/bin/bash

set -e

echo "=== Replacing Karmada Controller Manager ==="

# 配置变量
IMAGE_TAG="dev"
REGISTRY="karmada"
NAMESPACE="karmada-system"
COMPONENT="karmada-controller-manager"
IMAGE_NAME="$REGISTRY/$COMPONENT:$IMAGE_TAG"

export KUBECONFIG="$HOME/.kube/karmada.config" && kubectl config use-context karmada-host

echo "Step 1: Cleaning up existing deployment..."
# 删除现有部署
if kubectl get deployment $COMPONENT -n $NAMESPACE &>/dev/null; then
    echo "Deleting existing deployment: $COMPONENT"
    kubectl delete deployment $COMPONENT -n $NAMESPACE --ignore-not-found=true
    
    # 等待 Pod 完全删除
    echo "Waiting for pods to be deleted..."
    kubectl wait --for=delete pods -l app=$COMPONENT -n $NAMESPACE --timeout=60s || true
fi

echo "Step 2: Cleaning up existing images from kind clusters..."
# 删除所有 kind 集群中的旧镜像
for cluster in $(kind get clusters); do
    echo "Cleaning up image in cluster: $cluster"
    # 获取镜像 ID 并删除
    image_id=$(docker exec -it $cluster-control-plane crictl images | grep "$COMPONENT.*$IMAGE_TAG" | awk '{print $3}' | head -1 || true)
    if [ ! -z "$image_id" ]; then
        echo "Removing image $image_id from cluster $cluster"
        docker exec -it $cluster-control-plane crictl rmi $image_id || true
    fi
done

echo "Step 3: Building new karmada-controller-manager image..."
# 删除本地镜像
docker rmi $IMAGE_NAME 2>/dev/null || true

# 构建新镜像
make image-karmada-controller-manager VERSION=$IMAGE_TAG

echo "Loading $IMAGE_NAME to cluster: karmada-host"
kind load docker-image $IMAGE_NAME --name karmada-host

echo "Step 5: Deploying new controller-manager..."
# 直接应用部署文件
kubectl apply -f artifacts/deploy/karmada-controller-manager.yaml

echo "Step 6: Waiting for deployment to be ready..."
# 等待部署完成
kubectl rollout status deployment/$COMPONENT -n $NAMESPACE --timeout=300s

echo "Step 7: Verifying deployment..."
kubectl get pods -n $NAMESPACE -l app=$COMPONENT
echo "Current image:"
kubectl get deployment $COMPONENT -n $NAMESPACE -o jsonpath='{.spec.template.spec.containers[0].image}'

echo "✅ Controller Manager replacement completed successfully!"

# echo "Image verification in clusters:"
# for cluster in $(kind get clusters); do
#     echo -n "Cluster $cluster: "
#     if docker exec -it $cluster-control-plane crictl images | grep -q "$COMPONENT.*$IMAGE_TAG"; then
#         echo "✅ New image present"
#     else
#         echo "❌ New image not found"
#     fi
# done