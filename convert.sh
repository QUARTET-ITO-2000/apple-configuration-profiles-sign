#!/bin/sh
#
# Sign an unsigned Apple configuration profile (.mobileconfig) with the
# S/MIME certificate held in a PKCS#12 (.p12 / .pfx) file.
#
#   usage: convert.sh <input.p12> <unsigned.mobileconfig> [output.mobileconfig]
#
# Output defaults to ./signed.mobileconfig (DER-encoded PKCS#7, as Apple
# requires). Nothing is written outside the output file and a temporary
# directory that is removed even on failure.

set -eu
umask 077

prog=${0##*/}

if [ "$#" -lt 2 ] || [ "$#" -gt 3 ]; then
	printf 'usage: %s <input.p12> <unsigned.mobileconfig> [output.mobileconfig]\n' "$prog" >&2
	exit 64
fi

pkcs12_file=$1
unsigned_file=$2
signed_file=${3:-signed.mobileconfig}

for f in "$pkcs12_file" "$unsigned_file"; do
	[ -f "$f" ] || { printf '%s: no such file: %s\n' "$prog" "$f" >&2; exit 66; }
done
command -v openssl >/dev/null 2>&1 || { printf '%s: openssl not found in PATH\n' "$prog" >&2; exit 69; }

# OpenSSL 3.x needs -legacy to read older PKCS#12 files (RC2/3DES).
# LibreSSL (macOS /usr/bin/openssl) rejects the option, so detect it once.
legacy_flag=
if openssl pkcs12 -help 2>&1 | grep -q -- '-legacy'; then
	legacy_flag=-legacy
fi

workdir=$(mktemp -d "${TMPDIR:-/tmp}/signprofile.XXXXXX")
staging_file=${signed_file}.tmp$$
trap 'rm -rf "$workdir"; rm -f "$staging_file"' EXIT HUP INT TERM

cert_file=$workdir/cert.pem
chain_file=$workdir/ca-bundle.pem
key_file=$workdir/private.key

# Read the PKCS#12 passphrase once and feed it to each openssl call on stdin,
# so it never lands on disk or in the process argument list.
if [ -t 0 ]; then
	printf 'PKCS#12 import password: ' >&2
	stty -echo
	IFS= read -r p12_pass || true
	stty echo
	printf '\n' >&2
else
	IFS= read -r p12_pass || true
fi

# 1. leaf (signer) certificate
printf '%s' "$p12_pass" | openssl pkcs12 -in "$pkcs12_file" $legacy_flag \
	-passin stdin -clcerts -nokeys -out "$cert_file"

# 2. intermediate / CA certificates, already PEM
printf '%s' "$p12_pass" | openssl pkcs12 -in "$pkcs12_file" $legacy_flag \
	-passin stdin -cacerts -nokeys -out "$chain_file"

# 3. private key (unencrypted, but inside a 0700 temp dir)
printf '%s' "$p12_pass" | openssl pkcs12 -in "$pkcs12_file" $legacy_flag \
	-passin stdin -nocerts -nodes -out "$key_file"

if [ ! -s "$cert_file" ]; then
	printf '%s: no signing certificate found in %s\n' "$prog" "$pkcs12_file" >&2
	exit 65
fi

# 4. sign; only attach a CA bundle when the PKCS#12 actually carried one
set -- -sign -in "$unsigned_file" -out "$staging_file" \
	-signer "$cert_file" -inkey "$key_file" -outform der -nodetach
if [ -s "$chain_file" ]; then
	set -- "$@" -certfile "$chain_file"
else
	printf '%s: warning: no CA certificates in %s; signing without a chain\n' \
		"$prog" "$pkcs12_file" >&2
fi
openssl smime "$@"

# 5. verify before publishing the result
if ! openssl smime -verify -inform der -noverify -in "$staging_file" -out /dev/null 2>/dev/null; then
	printf '%s: signature verification failed\n' "$prog" >&2
	exit 70
fi

mv "$staging_file" "$signed_file"
printf '%s: wrote %s\n' "$prog" "$signed_file" >&2
openssl x509 -in "$cert_file" -noout -subject -enddate | sed 's/^/  /' >&2
