#!/bin/bash
# Creates a local self-signed certificate for development
# This allows Screen Recording permissions to persist across rebuilds

CERT_NAME="ShaderGlass Dev"

# Check if certificate already exists
if security find-identity -v -p codesigning | grep -q "$CERT_NAME"; then
    echo "Certificate '$CERT_NAME' already exists."
    exit 0
fi

echo "Creating self-signed development certificate..."
echo "You may be prompted for your keychain password."
echo ""

# Create certificate
cat > /tmp/cert.cfg << EOF
[ req ]
default_bits       = 2048
distinguished_name = req_dn
prompt             = no
[ req_dn ]
CN = $CERT_NAME
[ ext ]
keyUsage = critical, digitalSignature
extendedKeyUsage = codeSigning
EOF

# Generate key and cert
openssl req -x509 -newkey rsa:2048 -keyout /tmp/dev.key -out /tmp/dev.crt \
    -days 3650 -nodes -config /tmp/cert.cfg -extensions ext 2>/dev/null

# Import to keychain
security import /tmp/dev.crt -k ~/Library/Keychains/login.keychain-db -T /usr/bin/codesign
security import /tmp/dev.key -k ~/Library/Keychains/login.keychain-db -T /usr/bin/codesign

# Create identity (combine key + cert)
openssl pkcs12 -export -out /tmp/dev.p12 -inkey /tmp/dev.key -in /tmp/dev.crt -passout pass:

security import /tmp/dev.p12 -k ~/Library/Keychains/login.keychain-db -T /usr/bin/codesign -P ""

# Trust the certificate for code signing
echo ""
echo "Now trusting the certificate for code signing..."
echo "Click 'Always Trust' when prompted."
security add-trusted-cert -d -r trustRoot -k ~/Library/Keychains/login.keychain-db /tmp/dev.crt

# Cleanup
rm -f /tmp/cert.cfg /tmp/dev.key /tmp/dev.crt /tmp/dev.p12

echo ""
echo "Done! Certificate '$CERT_NAME' created."
echo "Now run: make clean && ./dev.sh"
