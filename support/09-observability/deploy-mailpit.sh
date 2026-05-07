#!/bin/bash
# Deploy Mailpit - lightweight mail server for alert notification demo
cat <<'EOF' | oc apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: mailpit
  namespace: alert-demo
spec:
  replicas: 1
  selector:
    matchLabels:
      app: mailpit
  template:
    metadata:
      labels:
        app: mailpit
    spec:
      containers:
      - name: mailpit
        image: quay.io/openshift-workshop-applications/mailpit:v1.29.7
        ports:
        - containerPort: 8025
          name: web
        - containerPort: 1025
          name: smtp
---
apiVersion: v1
kind: Service
metadata:
  name: mailpit
  namespace: alert-demo
spec:
  selector:
    app: mailpit
  ports:
  - name: web
    port: 8025
    targetPort: 8025
  - name: smtp
    port: 1025
    targetPort: 1025
---
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: mailpit
  namespace: alert-demo
spec:
  to:
    kind: Service
    name: mailpit
  port:
    targetPort: web
  tls:
    termination: edge
EOF
oc rollout status deployment/mailpit -n alert-demo --timeout=60s
echo ""
echo "Mailpit inbox: https://$(oc get route mailpit -n alert-demo -o jsonpath='{.spec.host}')"
