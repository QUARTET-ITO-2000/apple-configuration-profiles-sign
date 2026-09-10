#!/bin/sh

pkcs12_files="$1"
apple_configuration_files_unsigned="$2"

certificate_files="cert.pem"
#ca_bundle_files="ca-bundle.cer"
ca_bundle_files_x509="ca-bundle.pem"
private_key_files="private.key"
apple_configuration_files_signed="signed.mobileconfig"

openssl pkcs12 \
    -in ${pkcs12_files} > -clcerts -legacy -nokeys -out ${certificate_files} &&
openssl pkcs12 \
    -in ${pkcs12_files} \
    -cacerts -legacy -nokeys -chain | sed \
    -ne '/-BEGIN CERTIFICATE-/,/-END CERTIFICATE-/p' > ${ca_bundle_files_x509} &&
#openssl x509 
#    -inform der 
#    -in ${ca_bundle_files} 
#    -out ${ca_bundle_files_x509} &&
openssl pkcs12 \
    -in ${pkcs12_files} \
    -nocerts -legacy -nodes \
    -out ${private_key_files} &&
openssl smime \
    -sign -in ${apple_configuration_files_unsigned} \
    -out ${apple_configuration_files_signed} \
    -signer ${certificate_files} \
    -inkey ${private_key_files} \
    -certfile ${ca_bundle_files_x509} \
    -outform der -nodetach

rm ${certificate_files}
rm ${ca_bundle_files_x509}
rm ${private_key_files}
