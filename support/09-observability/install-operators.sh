#!/bin/bash
set -euo pipefail

cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: cluster-logging
  namespace: openshift-logging
spec:
  channel: stable-6.2
  installPlanApproval: Automatic
  name: cluster-logging
  source: redhat-operators
  sourceNamespace: openshift-marketplace
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: cluster-observability-operator
  namespace: openshift-operators
spec:
  channel: stable
  installPlanApproval: Automatic
  name: cluster-observability-operator
  source: redhat-operators
  sourceNamespace: openshift-marketplace
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: tempo-product
  namespace: openshift-operators
spec:
  channel: stable
  installPlanApproval: Automatic
  name: tempo-product
  source: redhat-operators
  sourceNamespace: openshift-marketplace
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: opentelemetry-product
  namespace: openshift-operators
spec:
  channel: stable
  installPlanApproval: Automatic
  name: opentelemetry-product
  source: redhat-operators
  sourceNamespace: openshift-marketplace
EOF
echo "Logging, COO, Tempo, and OpenTelemetry subscriptions created"

echo "Waiting for all 5 operators (this takes about a minute)..."
TIMEOUT=300; ELAPSED=0
while [ $ELAPSED -lt $TIMEOUT ]; do
  READY=0
  oc get csv -n openshift-operators-redhat 2>/dev/null | grep -q "loki.*Succeeded" && READY=$((READY+1))
  oc get csv -n openshift-logging 2>/dev/null | grep -q "cluster-logging.*Succeeded" && READY=$((READY+1))
  oc get csv -n openshift-operators 2>/dev/null | grep -q "observability.*Succeeded" && READY=$((READY+1))
  oc get csv -n openshift-operators 2>/dev/null | grep -q "tempo.*Succeeded" && READY=$((READY+1))
  oc get csv -n openshift-operators 2>/dev/null | grep -q "opentelemetry.*Succeeded" && READY=$((READY+1))
  echo "  ${READY}/5 operators ready"
  [ $READY -eq 5 ] && break
  sleep 15; ELAPSED=$((ELAPSED+15))
done
[ $READY -eq 5 ] && echo "All operators installed" || echo "ERROR: Timed out - check Ecosystem -> Installed Operators"
