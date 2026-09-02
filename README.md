# Kubernetes Self Hosted with Kubeadm

## Join Node
Create token, discovery-token-ca-cert-hash, and control-plane certificate-key. Please run all of this command in master node:
- token
```
sudo kubeadm token create
```
- hash
```
sudo openssl x509 -pubkey -in /etc/kubernetes/pki/ca.crt \
    | openssl rsa -pubin -outform der 2>/dev/null \
    | openssl dgst -sha256 -hex \
    | awk '{print "sha256:" $2}'
```
- certificate-key
```
sudo kubeadm init phase upload-certs --upload-certs 2>&1 \
    | awk '/Using certificate key:/{getline; print; exit}'
```

## Joining Master Node
- Run this command in new master node
```
sudo kubeadm join <control-plane-endpoint> \
    --token <token> \
    --discovery-token-ca-cert-hash <hash> \
    --control-plane \
    --certificate-key <certificate-key>
```

## Joining Worker Node
- Run this command in new master node
```
sudo kubeadm join <control-plane-endpoint> \
    --token <token> \
    --discovery-token-ca-cert-hash <hash>
```