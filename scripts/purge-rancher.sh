#!/usr/bin/env bash

set -Eeuo pipefail

banner() {
echo
echo "=================================================================="
echo "$1"
echo "=================================================================="
}

delete_resource_list() {
local resources="$1"

[[ -z "${resources}" ]] && return 0

while IFS= read -r resource; do
[[ -z "${resource}" ]] && continue
kubectl delete "${resource}"
done <<< "${resources}"
}

delete_resource_list_nowait() {
local resources="$1"

[[ -z "${resources}" ]] && return 0

while IFS= read -r resource; do
[[ -z "${resource}" ]] && continue
kubectl delete "${resource}" --wait=false || true
done <<< "${resources}"
}

banner "1. Removing Helm releases"

helm uninstall rancher -n cattle-system 2>/dev/null || true
helm uninstall rancher-webhook -n cattle-system 2>/dev/null || true
helm uninstall fleet -n cattle-fleet-system 2>/dev/null || true
helm uninstall fleet-crd -n cattle-fleet-system 2>/dev/null || true

banner "2. Waiting for Rancher/Fleet workloads to stop"

for _ in $(seq 1 60); do

PODS=$(kubectl get pods -A --no-headers 2>/dev/null | grep -Ei 'rancher|fleet|cattle' || true)

if [[ -z "${PODS}" ]]; then
break
fi

sleep 2

done

banner "3. Removing Rancher webhooks"

VALIDATING=$(kubectl get validatingwebhookconfigurations -o name 2>/dev/null | grep rancher || true)
delete_resource_list "${VALIDATING}"

MUTATING=$(kubectl get mutatingwebhookconfigurations -o name 2>/dev/null | grep rancher || true)
delete_resource_list "${MUTATING}"

banner "4. Removing Rancher APIServices"

APISERVICES=$(kubectl get apiservices -o name 2>/dev/null | grep cattle || true)
delete_resource_list "${APISERVICES}"

banner "5. Removing Rancher/Fleet CRDs"

CRDS=$(kubectl get crd -o name 2>/dev/null | grep -E '(cattle.io|fleet.cattle.io)' || true)

if [[ -n "${CRDS}" ]]; then

while IFS= read -r crd; do

  [[ -z "${crd}" ]] && continue

  echo "Deleting ${crd}"

  kubectl patch "${crd}" \
    --type=json \
    -p='[{"op":"remove","path":"/metadata/finalizers"}]' \
    >/dev/null 2>&1 || true

  kubectl delete "${crd}" --wait=false || true

done <<< "${CRDS}"

fi

sleep 10

banner "6. Removing Rancher namespaces"

NAMESPACES=$(kubectl get ns -o name 2>/dev/null | grep -E '(cattle|fleet|local|p-|user-)' || true)
delete_resource_list_nowait "${NAMESPACES}"

sleep 15

banner "7. Force-finalizing stuck namespaces"

TERMINATING=$(kubectl get ns --no-headers 2>/dev/null | awk '$2=="Terminating"{print $1}')

if [[ -n "${TERMINATING}" ]]; then

while IFS= read -r ns; do

  [[ -z "${ns}" ]] && continue

  printf 'Force-finalizing %s\n' "${ns}"

  kubectl get ns "${ns}" -o json \
    | jq 'del(.spec.finalizers)' \
    | kubectl replace \
        --raw "/api/v1/namespaces/${ns}/finalize" \
        -f - \
    >/dev/null 2>&1 || true

done <<< "${TERMINATING}"

fi

banner "8. Removing Rancher ClusterRoles"

ROLES=$(kubectl get clusterroles -o name 2>/dev/null | grep -Ei '(rancher|fleet|cattle)' || true)

if [[ -n "${ROLES}" ]]; then
delete_resource_list "${ROLES}"
fi

banner "9. Removing Rancher ClusterRoleBindings"

BINDINGS=$(kubectl get clusterrolebindings -o name 2>/dev/null | grep -Ei '(rancher|fleet|cattle)' || true)

if [[ -n "${BINDINGS}" ]]; then
delete_resource_list "${BINDINGS}"
fi

banner "10. Verification"

echo
echo "[Namespaces]"
kubectl get ns | grep -E '(cattle|fleet|local|p-|user-)' || true

echo
echo "[CRDs]"
kubectl get crd | grep -Ei '(cattle|fleet)' || true

echo
echo "[APIServices]"
kubectl get apiservices | grep cattle || true

echo
echo "[Validating webhooks]"
kubectl get validatingwebhookconfigurations | grep rancher || true

echo
echo "[Mutating webhooks]"
kubectl get mutatingwebhookconfigurations | grep rancher || true

echo
echo "[Helm releases]"
helm list -A | grep -Ei '(rancher|fleet)' || true

echo
echo "[ClusterRoles]"
kubectl get clusterroles | grep -Ei '(rancher|fleet|cattle)' || true

echo
echo "[ClusterRoleBindings]"
kubectl get clusterrolebindings | grep -Ei '(rancher|fleet|cattle)' || true

echo
echo "[API resources]"
kubectl api-resources | grep cattle || true
kubectl api-resources | grep fleet || true

echo
echo "DONE"
