#!/bin/bash

set -e

echo "=== Replacing Karmada Scheduler Estimator ==="

# 配置变量
IMAGE_TAG="dev"
REGISTRY="karmada"
NAMESPACE="karmada-system"
COMPONENT="karmada-scheduler-estimator"
IMAGE_NAME="$REGISTRY/$COMPONENT:$IMAGE_TAG"
REPO_ROOT=$(pwd)
MEMBER_CLUSTERS="member1 member2 member3"

export KUBECONFIG="$HOME/.kube/karmada.config" && kubectl config use-context karmada-host

echo "Step 1: Cleaning up existing estimator deployments..."
for deployment in $(kubectl get deployments -n $NAMESPACE -o name | grep "$COMPONENT"); do
    kubectl delete $deployment -n $NAMESPACE --ignore-not-found=true
done
kubectl wait --for=delete pods -l app.kubernetes.io/name=$COMPONENT -n $NAMESPACE --timeout=60s || true

echo "Step 2: Cleaning up existing images from kind clusters..."
for cluster in $(kind get clusters); do
    image_id=$(docker exec -it $cluster-control-plane crictl images | grep "$COMPONENT.*$IMAGE_TAG" | awk '{print $3}' | head -1 || true)
    if [ ! -z "$image_id" ]; then
        docker exec -it $cluster-control-plane crictl rmi $image_id || true
    fi
done

echo "Step 3: Building new karmada-scheduler-estimator image..."
docker rmi $IMAGE_NAME 2>/dev/null || true
make image-karmada-scheduler-estimator VERSION=$IMAGE_TAG

echo "Step 4: Loading new image to kind clusters..."
for cluster in $(kind get clusters); do
    kind load docker-image $IMAGE_NAME --name $cluster
done

echo "Step 5: Deploying new estimators for each member cluster..."
for cluster_name in $MEMBER_CLUSTERS; do
    echo "Creating estimator for cluster: $cluster_name"
    
    # 创建临时目录
    TEMP_PATH=$(mktemp -d)
    
    # 复制模板文件
    cp "${REPO_ROOT}"/artifacts/deploy/karmada-scheduler-estimator.yaml "${TEMP_PATH}"/karmada-scheduler-estimator.yaml
    
    # 替换模板变量
    sed -i'' -e "s/{{member_cluster_name}}/${cluster_name}/g" "${TEMP_PATH}"/karmada-scheduler-estimator.yaml
    
    echo -e "Apply dynamic rendered deployment in ${TEMP_PATH}/karmada-scheduler-estimator.yaml\n"
    
    # 应用部署
    kubectl apply -f "${TEMP_PATH}"/karmada-scheduler-estimator.yaml
    
    # 等待部署完成
    kubectl rollout status deployment/$COMPONENT-$cluster_name -n $NAMESPACE --timeout=300s
    
    # 清理临时文件
    rm -rf "${TEMP_PATH}"
done

echo "Step 6: Verifying all estimator deployments..."
kubectl get pods -n $NAMESPACE -l app.kubernetes.io/name=$COMPONENT

echo ""
echo "✅ Scheduler Estimator replacement completed successfully!"