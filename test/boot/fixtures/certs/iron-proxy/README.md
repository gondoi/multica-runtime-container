# iron-proxy egress-control fixtures (boot seam)
#
# `certs/iron-proxy/ca.crt` is a throwaway self-signed CA used only to prove the
# runtime trusts a proxy CA and builds the combined bundle. Its private key was
# discarded at generation time and is deliberately NOT in the repo: the seam
# never terminates TLS with it, it only needs a *valid* PEM certificate.
#
# Regenerate (100-year validity, then delete the key):
#   openssl req -x509 -newkey rsa:2048 -nodes -keyout /tmp/ca.key -days 36500 \
#     -subj "/CN=multica-runtime boot-seam fixture CA" \
#     -addext "basicConstraints=critical,CA:TRUE" \
#     -addext "keyUsage=critical,keyCertSign" \
#     -out test/boot/fixtures/certs/iron-proxy/ca.crt && rm -f /tmp/ca.key
