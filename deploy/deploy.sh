#!/usr/bin/env bash

# This script captures the steps required to successfully
# deploy the plugin driver.  This should be considered
# authoritative and all updates for this process should be
# done here and referenced elsewhere.

# The script assumes that oc is available on the OS path
# where it is executed.

# The following environment variables can be used to swap the images that are deployed:
#
# - NODE_REGISTRAR_IMAGE - this is the node driver registrar. Defaults to quay.io/openshift/origin-csi-node-driver-registrar:4.10.0
# - DRIVER_IMAGE - this is the CSI driver image. Defaults to quay.io/openshift/origin-csi-driver-projected-resource:4.10.0

set -eu
set -o pipefail

# customize images used by registrar and csi-driver containers
NODE_REGISTRAR_IMAGE="${NODE_REGISTRAR_IMAGE:-}"
DRIVER_IMAGE="${DRIVER_IMAGE:-}"

# BASE_DIR will default to deploy
BASE_DIR="deploy"
DEPLOY_DIR="_output/deploy"

# path to kutomize file, should be insite the temporary directory created for the rollout
KUSTOMIZATION_FILE="${DEPLOY_DIR}/kustomization.yaml"

# target namespace where resources are deployed
NAMESPACE="openshift-cluster-csi-drivers"

function run () {
    echo "$@" >&2
    "$@"
}

# initialize a kustomization.yaml file, listing all other yaml files as resources.
function kustomize_init () {
    cat <<EOS > ${KUSTOMIZATION_FILE}
---
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
EOS

  for f in $(find "${DEPLOY_DIR}"/*.yaml |grep -v 'kustomization' |sort); do
    f=$(basename "${f}")
    echo "## ${f}"
    echo "  - ${f}" >> ${KUSTOMIZATION_FILE}
  done

  echo "images:" >> ${KUSTOMIZATION_FILE}
}

# creates a new entry with informed name and target image. The target image is split on URL and tag.
function kustomize_set_image () {
  local NAME=${1}
  local TARGET=${2}

  # splitting target image in URL and tag
  local URL=${TARGET%:*}

  # tag must be in the last part of the image url, after the hostname
  # hostname might contain semicolon to describe port, splitting there would be wrong
  local IMAGE=${TARGET##*/}
  local TAG=${IMAGE##*:}

  # means there was no semicolon in the image
  # in this case we should hold original value in the URL, since there was nothing to split upon
  if [ "$IMAGE" = "$TAG" ]; then
    URL=$TARGET
    TAG="latest"
  fi

  cat <<EOS >> ${KUSTOMIZATION_FILE}
  - name: ${NAME}
    newName: ${URL}
    newTag: ${TAG}
EOS
}

# uses `oc wait` to wait for CSI driver pod to reach condition ready.
function wait_for_pod () {
  oc --namespace="${NAMESPACE}" wait pod \
    --for="condition=Ready=true" \
    --selector="app=shared-resource-csi-driver-node" \
    --timeout="5m"
}

echo "# Creating deploy directory at '${DEPLOY_DIR}'"

rm -rf "${DEPLOY_DIR}" || true
mkdir -p "${DEPLOY_DIR}"

cp -r -v "${BASE_DIR}"/* "${DEPLOY_DIR}"

echo "# Customizing resources..."

# initializing kustomize and adding the all resource files it should use
kustomize_init

if [ -n "${NODE_REGISTRAR_IMAGE}" ] ; then
  echo "# Patching node-registrar image to use '${NODE_REGISTRAR_IMAGE}'"
  kustomize_set_image "quay.io/openshift/origin-csi-node-driver-registrar" "${NODE_REGISTRAR_IMAGE}"
fi

if [ -n "${DRIVER_IMAGE}" ] ; then
  echo "# Patching node-csi-driver image to use '${DRIVER_IMAGE}'"
  kustomize_set_image "quay.io/openshift/origin-csi-driver-shared-resource" "${DRIVER_IMAGE}"
fi

# deploy hostpath plugin and registrar sidecar
echo "# Deploying csi driver components on namespace '${NAMESPACE}'"
run oc apply --namespace="${NAMESPACE}" --kustomize ${DEPLOY_DIR}/

# waiting for all pods to reach condition ready
echo "# Waiting for pods to be ready..."
wait_for_pod || sleep 15 && wait_for_pod
