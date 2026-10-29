#!/usr/bin/env bash
# genere une CA interne + un certificat serveur pour registry.local
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p certs
cd certs

# CA
openssl genrsa -out ca.key 4096
openssl req -x509 -new -nodes -key ca.key -sha256 -days 3650 \
  -subj "/C=FR/O=Shop SAS/CN=Shop SAS Internal CA" -out ca.crt

# certificat serveur avec les SAN
cat > registry.ext <<EOF
basicConstraints=CA:FALSE
keyUsage=digitalSignature,keyEncipherment
extendedKeyUsage=serverAuth
subjectAltName=DNS:registry.local,DNS:registry,DNS:localhost,IP:127.0.0.1
EOF

openssl genrsa -out registry.key 2048
openssl req -new -key registry.key -subj "/C=FR/O=Shop SAS/CN=registry.local" -out registry.csr
openssl x509 -req -in registry.csr -CA ca.crt -CAkey ca.key -CAcreateserial \
  -days 825 -sha256 -extfile registry.ext -out registry.crt

rm -f registry.csr registry.ext
chmod 600 ca.key

openssl x509 -in registry.crt -noout -text | grep -A1 "Subject Alternative Name"

echo
echo "Cote client docker (en root) :"
echo "  mkdir -p /etc/docker/certs.d/registry.local:5000"
echo "  cp $(pwd)/ca.crt /etc/docker/certs.d/registry.local:5000/ca.crt"
echo "  echo '127.0.0.1 registry.local' >> /etc/hosts"
