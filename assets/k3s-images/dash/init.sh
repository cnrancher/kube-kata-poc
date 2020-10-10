#!/bin/sh

kubectl apply -f dashboard.yaml
kubectl apply -f user-token.yaml

kubectl -n kubernetes-dashboard describe secret $(kubectl -n kubernetes-dashboard get secret | grep admin-user | awk '{print $1}')

