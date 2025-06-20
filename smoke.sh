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
    etcdctl get /registry/secrets/default/kthw-generic-secret | hexdump -C
}

#
# 3. create nginx deployment
function kthw-nginx-deploy () {
    kubectl create deployment nginx --image=nginx:latest

    kubectl get pods -A
}

function kthw-nginx-pod-name () {
    kubectl get pods -l app=nginx -o jsonpath="{.items[0].metadata.name}"
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
    kubectl exec -it "$(kthw-nginx-pod-name)" -- nginx -v
}

#
# 7. nginx service
function kthw-nginx-service () {
    local node node_port

    kubectl expose deployment nginx --port 80 --type NodePort
    kubectl get services nginx

    # return nginx's node name
    node=$(kubectl get pods -l app=nginx -o jsonpath="{.items[0].spec.nodeName}")

    node_port=$(kubectl get svc nginx -o jsonpath="{.spec.ports[0].nodePort}")


    curl --head http://${node}:${node_port}
}

#
# 8. create a few alpine pods
function kthw-alpine () (
    for i in {1..6}; do
        kubectl run --env 'PS1=\h:\w\$ ' --image alpine "a$i" -- sleep infinity
    done
)

#
# 9. create a service account token
function kthw-sa-token () {
    kubectl create token default --duration=1h
}
