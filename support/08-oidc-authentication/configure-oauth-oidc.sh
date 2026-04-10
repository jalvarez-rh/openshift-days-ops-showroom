#!/bin/bash
set -euo pipefail

KEYCLOAK_URL=$(oc get route keycloak -n rhbk -o jsonpath='{.spec.host}')

cat <<EOF | oc apply -f -
apiVersion: config.openshift.io/v1
kind: OAuth
metadata:
  name: cluster
spec:
  identityProviders:
  - name: htpasswd
    mappingMethod: claim
    type: HTPasswd
    htpasswd:
      fileData:
        name: htpasswd
  - name: rhbk
    mappingMethod: claim
    type: OpenID
    openID:
      clientID: openshift
      clientSecret:
        name: rhbk-client-secret
      issuer: https://${KEYCLOAK_URL}/realms/OpenShift
      claims:
        preferredUsername:
        - preferred_username
        name:
        - name
        email:
        - email
        groups:
        - groups
      extraScopes:
      - email
      - profile
EOF
