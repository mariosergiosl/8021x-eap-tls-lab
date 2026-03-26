#!/usr/bin/env python3
"""
sign_client_cert_tpm.py — Assinatura de certificado cliente TPM

Contexto:
    O wpa_supplicant usa PKCS#11 via openssl-engine-libp11, que usa o tpm2-pkcs11
    para acessar a chave no TPM. O CSR é gerado via provider pkcs11 do OpenSSL 3
    e produz assinaturas ECDSA compatíveis — verificação passa normalmente.

    Este script é necessário apenas se o openssl x509 -req recusar o CSR por
    incompatibilidade de assinatura (cenário tpm2tss engine). Para CSRs gerados
    via provider pkcs11 (stack atual), o openssl x509 -req normal funciona.

    Mantido aqui como referência e fallback.

Uso:
    python3 sign_client_cert_tpm.py \\
        --csr  /opt/8021x-eap-tls-lab/certs/client-tpm.csr \\
        --ca   /opt/8021x-eap-tls-lab/certs/ca-lab.crt \\
        --cakey /opt/8021x-eap-tls-lab/private/ca-lab.key \\
        --out  /opt/8021x-eap-tls-lab/certs/client-tpm.crt

Dependências:
    pip3 install cryptography  (já disponível no SLES 16 / openSUSE Leap 15.6)

Autor: Gerado durante o lab 802.1X EAP-TLS TPM — 2026-03-25
"""

import argparse
import datetime
import sys

try:
    from cryptography import x509
    from cryptography.hazmat.primitives import hashes, serialization
except ImportError:
    print("Erro: biblioteca 'cryptography' não encontrada.")
    print("Instale com: pip3 install cryptography --break-system-packages")
    sys.exit(1)


def parse_args():
    parser = argparse.ArgumentParser(
        description="Assina um certificado cliente TPM ignorando verificação de autoassinatura do CSR."
    )
    parser.add_argument("--csr",   required=True, help="Caminho do arquivo CSR")
    parser.add_argument("--ca",    required=True, help="Caminho do certificado CA")
    parser.add_argument("--cakey", required=True, help="Caminho da chave privada da CA")
    parser.add_argument("--out",   required=True, help="Caminho do certificado de saída")
    parser.add_argument("--days",  type=int, default=365, help="Validade em dias (default: 365)")
    return parser.parse_args()


def main():
    args = parse_args()

    # Carrega o CSR sem verificar a autoassinatura
    with open(args.csr, "rb") as f:
        csr = x509.load_pem_x509_csr(f.read())

    # Carrega o certificado CA
    with open(args.ca, "rb") as f:
        ca_cert = x509.load_pem_x509_certificate(f.read())

    # Carrega a chave privada da CA
    with open(args.cakey, "rb") as f:
        ca_key = serialization.load_pem_private_key(f.read(), password=None)

    # Constrói o certificado
    now = datetime.datetime.utcnow()
    cert = (
        x509.CertificateBuilder()
        .subject_name(csr.subject)
        .issuer_name(ca_cert.subject)
        .public_key(csr.public_key())
        .serial_number(x509.random_serial_number())
        .not_valid_before(now)
        .not_valid_after(now + datetime.timedelta(days=args.days))
        .sign(ca_key, hashes.SHA256())
    )

    # Salva o certificado
    with open(args.out, "wb") as f:
        f.write(cert.public_bytes(serialization.Encoding.PEM))

    print(f"Certificado gerado com sucesso: {args.out}")
    print(f"  Subject : {csr.subject.rfc4514_string()}")
    print(f"  Válido  : {args.days} dias")


if __name__ == "__main__":
    main()
