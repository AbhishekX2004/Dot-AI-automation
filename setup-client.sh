#!/bin/bash
set -e

echo "Delete old client if exist"
kind delete cluster --name client-1 || true

echo "Spinning Up Fresh Client Cluster"
kind create cluster --name client-1 --image kindest/node:v1.29.2

echo "Populating Client Resources"
kubectl config use-context kind-client-1

kubectl create namespace client-frontend
kubectl create namespace client-backend
kubectl create namespace chaos-testing

echo "Deploying NGINX to client-frontend..."
kubectl create deployment client-web-app --image=nginx:alpine -n client-frontend
kubectl expose deployment client-web-app --port=80 --target-port=80 -n client-frontend

echo "Deploying Redis to client-backend..."
kubectl create deployment client-redis-cache --image=redis:alpine -n client-backend

echo "Deploying a broken app to chaos-testing (for the AI to fix later)"
kubectl create deployment failing-api --image=node:super-broken-tag-999 -n chaos-testing

echo "Waiting for Resources to Boot"
kubectl wait --for=condition=available deployment/client-web-app -n client-frontend --timeout=90s
kubectl wait --for=condition=available deployment/client-redis-cache -n client-backend --timeout=90s

echo "Client Cluster Ready!"
echo "Client Cluster:"
kubectl get pods -A | grep -E "client-|chaos-"