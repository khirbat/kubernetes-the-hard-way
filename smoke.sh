#!/bin/bash

# Kubernetes Smoke Tests

if ! (return 0 2>/dev/null); then
    echo "Usage: source $0"
    echo
    # grep -E '^#([^!#]|$)' "$0"
    cat <<'EOF'
After sourcing the script, run the functions marked with an # N. comment in the order they appear

EOF
    grep -A1 -E '^# [[:digit:]]+\.' "$0" | sed 's/^function //;s/ ().*//'
    exit 1
fi

#
# 1. create a generic secret
function kthw-generic-secret () {
    kubectl create secret generic kthw-generic-secret --from-literal="username=admin" --from-literal="password=1f2d1e2e67df"
}

#
# 2. dump generic secret
function kthw-generic-secret-hexdump () {
    ssh debian@server etcdctl get /registry/secrets/default/kthw-generic-secret | hexdump -C
}

#
# 3. create nginx deployment
function kthw-nginx-deploy () {
    kubectl create deployment nginx --image=nginx:latest

    kubectl get pods -A
}

function kthw-pod-name () {  # label
    kubectl get pods -l app="$1" -o jsonpath="{.items[0].metadata.name}"
}

#
# 4. nginx port forwarding
function kthw-nginx-port-forward () {
    kubectl port-forward "$(kthw-nginx-pod-name)" 8080:80 &
    sleep 2
    curl --head http://127.0.0.1:8080
    fg
}

#
# 5. nginx logs
function kthw-nginx-logs () {
    kubectl logs "$(kthw-nginx-pod-name)"
}

#
# 6. nginx exec
function kthw-nginx-exec () {
    kubectl exec -it "$(kthw-pod-name nginx)" -- nginx -v
}

#
# 7. nginx service
function kthw-nginx-service () (
    kubectl expose deployment nginx --port 80 --type NodePort
    kubectl get services nginx

    # return nginx's node name
    node=$(kubectl get pods -l app=nginx -o jsonpath="{.items[0].spec.nodeName}")

    node_port=$(kubectl get svc nginx -o jsonpath="{.spec.ports[0].nodePort}")

    curl --head "http://${node}:${node_port}"
)

#
# 8. create netshoot pods
function kthw-netshoot () {
    kubectl apply -f configs/netshoot-deployment.yaml
}

#
# 9. access API server from a pod
# https://kubernetes.io/docs/tasks/run-application/access-api-from-pod/#without-using-a-proxy
function kthw-api-from-pod () (
    pod=$(kthw-pod-name netshoot)

    kubectl exec -i "$pod" -- bash <<'EOF' | jq
SA=/var/run/secrets/kubernetes.io/serviceaccount

curl -s --cacert "$SA/ca.crt" \
    -H "Authorization: Bearer $(cat "$SA/token")" \
    https://${KUBERNETES_SERVICE_HOST}/api
EOF
)
