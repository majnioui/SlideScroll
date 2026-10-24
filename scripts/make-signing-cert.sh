#!/bin/sh
# Make a free, self-signed code-signing certificate for SlideScroll releases.
#
#   scripts/make-signing-cert.sh ["Certificate name"]
#
# macOS ties the Accessibility permission to an app's signature. Ad-hoc builds
# get a new one every time, so each update needs the permission again. Signed
# with the same certificate every time, updates keep it. This isn't a Developer
# ID: macOS still asks users to confirm the first launch of a downloaded disk
# image, but nothing else changes for them.
#
# It writes the certificate to a folder you choose and prints the GitHub
# secrets the release workflow reads. Keep the .p12 and its password private:
# anyone with them can sign builds that macOS treats as SlideScroll.
set -eu

name="${1:-SlideScroll Self-Signed}"
out="${OUT_DIR:-$HOME/Desktop/slidescroll-signing}"
mkdir -p "$out"
chmod 700 "$out"

cat > "$out/cert.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $name
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
EOF

openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$out/cert.cnf" \
    -keyout "$out/key.pem" -out "$out/cert.pem" 2>/dev/null
password=$(openssl rand -hex 16)
# The older encryption is the one macOS's `security import` reads.
openssl pkcs12 -export -inkey "$out/key.pem" -in "$out/cert.pem" -name "$name" \
    -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1 \
    -passout "pass:$password" -out "$out/signing.p12"
printf '%s' "$password" > "$out/password.txt"
base64 < "$out/signing.p12" | tr -d '\n' > "$out/signing.p12.base64"
rm -f "$out/key.pem" "$out/cert.cnf"

cat <<EOF

Made "$name" in $out.

Add these as repository secrets (GitHub, Settings, Secrets and variables, Actions):

  MACOS_CERTIFICATE           the contents of $out/signing.p12.base64
  MACOS_CERTIFICATE_PASSWORD  the contents of $out/password.txt
  MACOS_SIGN_IDENTITY         $name

or with the GitHub CLI, from this repository:

  gh secret set MACOS_CERTIFICATE < "$out/signing.p12.base64"
  gh secret set MACOS_CERTIFICATE_PASSWORD < "$out/password.txt"
  gh secret set MACOS_SIGN_IDENTITY --body "$name"

The next release is signed with it. Users allow Accessibility once more for
that release, and then keep it across updates.

To sign local builds the same way, import it and trust it for code signing:

  security import "$out/signing.p12" -P "\$(cat "$out/password.txt")" -T /usr/bin/codesign
  security add-trusted-cert -r trustRoot -p codeSign "$out/cert.pem"
  SIGN_IDENTITY="$name" scripts/bundle.sh
EOF
