#!/bin/bash
#===============================================================================
# FILE: tpm_provision.sh
#
# DESCRIPTION:
#   Provisionamento completo do TPM 2.0 para autenticação 802.1X EAP-TLS
#   via interface PKCS#11. Gera a chave ECDSA dentro do TPM, cria o CSR
#   e prepara o ambiente para o wpa_supplicant.
#
#   Stack utilizado (SLES 16 / OpenSSL 3.5):
#     - tpm2-pkcs11  : expõe o TPM como token PKCS#11
#     - pkcs11-provider : provider OpenSSL 3 para geração do CSR
#     - openssl-engine-libp11 : engine legado usado pelo wpa_supplicant
#     - tpm2.0-abrmd : resource manager do TPM (obrigatório)
#
# USAGE:
#   tpm_provision.sh [OPTIONS]
#
# OPTIONS:
#   -l, --label LABEL       Label do token TPM (default: endpoint-tpm)
#   -o, --so-pin PIN        SO PIN do token (default: 12345678)
#   -p, --user-pin PIN      User PIN do token (default: 1234)
#   -k, --key-label LABEL   Label da chave (default: endpoint-client-key)
#   -i, --identity ID       Identidade EAP (default: endpoint-client.lab.local)
#   -s, --store DIR         Diretório do store PKCS11 (default: /etc/tpm2-pkcs11)
#   -d, --dir DIR           Diretório de trabalho wpa (default: /etc/wpa_supplicant/tpm)
#   -h, --help              Exibe esta ajuda
#
# OUTPUTS:
#   /etc/wpa_supplicant/tpm/client-tpm.csr  <- enviar para a CA assinar
#
# AUTHOR: Mario Luz
# CREATED: 2026-03-25
#===============================================================================

set -euo pipefail

# --- Defaults ---
TOKEN_LABEL="endpoint-tpm"
SO_PIN="12345678"
USER_PIN="1234"
KEY_LABEL="endpoint-client-key"
EAP_IDENTITY="endpoint-client.lab.local"
PKCS11_STORE="/etc/tpm2-pkcs11"
WPA_TPM_DIR="/etc/wpa_supplicant/tpm"
PKCS11_MODULE="/usr/local/lib/libtpm2_pkcs11.so"

# --- Argument parsing ---
while [[ $# -gt 0 ]]; do
  case $1 in
    -l|--label)       TOKEN_LABEL="$2"; shift 2 ;;
    -o|--so-pin)      SO_PIN="$2"; shift 2 ;;
    -p|--user-pin)    USER_PIN="$2"; shift 2 ;;
    -k|--key-label)   KEY_LABEL="$2"; shift 2 ;;
    -i|--identity)    EAP_IDENTITY="$2"; shift 2 ;;
    -s|--store)       PKCS11_STORE="$2"; shift 2 ;;
    -d|--dir)         WPA_TPM_DIR="$2"; shift 2 ;;
    -h|--help)
      sed -n '/^# DESCRIPTION/,/^#=\+$/p' "$0" | sed 's/^# \?//'
      exit 0 ;;
    *) echo "Opção desconhecida: $1"; exit 1 ;;
  esac
done

# --- Verificação de privilégios ---
if [[ "${EUID}" -ne 0 ]]; then
  echo "Erro: este script deve ser executado como root."
  exit 1
fi

# --- Verificação de dependências ---
for cmd in pkcs11-tool openssl tpm2_getcap tpm2_flushcontext systemctl; do
  if ! command -v "$cmd" &>/dev/null; then
    echo "Erro: comando '$cmd' não encontrado. Verifique os pré-requisitos."
    exit 1
  fi
done

if [[ ! -f "${PKCS11_MODULE}" ]]; then
  echo "Erro: módulo PKCS#11 não encontrado em ${PKCS11_MODULE}"
  echo "Execute a compilação do tpm2-pkcs11 conforme documentado no README."
  exit 1
fi

# --- Verificação do tpm2-abrmd ---
if ! systemctl is-active --quiet tpm2-abrmd.service; then
  echo "Iniciando tpm2-abrmd..."
  systemctl start tpm2-abrmd.service
fi

export TPM2_PKCS11_STORE="${PKCS11_STORE}"

echo "============================================================"
echo "  Provisionamento TPM 2.0 — 802.1X EAP-TLS"
echo "============================================================"
echo "  Token label  : ${TOKEN_LABEL}"
echo "  Key label    : ${KEY_LABEL}"
echo "  EAP identity : ${EAP_IDENTITY}"
echo "  PKCS11 store : ${PKCS11_STORE}"
echo "  WPA TPM dir  : ${WPA_TPM_DIR}"
echo "============================================================"

# --- PASSO 1: Prepara diretórios ---
echo ""
echo "[1/5] Preparando diretórios..."
mkdir -p "${PKCS11_STORE}"
mkdir -p "${WPA_TPM_DIR}"

# Limpa contextos TPM pendentes
tpm2_flushcontext -t 2>/dev/null || true
tpm2_flushcontext -s 2>/dev/null || true
tpm2_flushcontext -l 2>/dev/null || true

# --- PASSO 2: Inicializa o token ---
echo ""
echo "[2/5] Inicializando token TPM..."

# Verifica se o token já existe
EXISTING_TOKEN=$(pkcs11-tool --module "${PKCS11_MODULE}" \
  --list-token-slots 2>/dev/null | grep "token label" | grep "${TOKEN_LABEL}" || true)

if [[ -n "${EXISTING_TOKEN}" ]]; then
  echo "Token '${TOKEN_LABEL}' já existe. Pulando inicialização."
else
  pkcs11-tool --module "${PKCS11_MODULE}" \
    --init-token \
    --label "${TOKEN_LABEL}" \
    --so-pin "${SO_PIN}"

  pkcs11-tool --module "${PKCS11_MODULE}" \
    --token-label "${TOKEN_LABEL}" \
    --init-pin \
    --so-pin "${SO_PIN}" \
    --pin "${USER_PIN}"

  echo "Token inicializado com sucesso."
fi

# --- PASSO 3: Gera chave ECDSA no TPM ---
echo ""
echo "[3/5] Gerando chave ECDSA P-256 no TPM..."

EXISTING_KEY=$(pkcs11-tool --module "${PKCS11_MODULE}" \
  --token-label "${TOKEN_LABEL}" \
  --login --pin "${USER_PIN}" \
  --list-objects 2>/dev/null | grep "label:" | grep "${KEY_LABEL}" || true)

if [[ -n "${EXISTING_KEY}" ]]; then
  echo "Chave '${KEY_LABEL}' já existe no token. Pulando geração."
else
  pkcs11-tool --module "${PKCS11_MODULE}" \
    --token-label "${TOKEN_LABEL}" \
    --login --pin "${USER_PIN}" \
    --keypairgen \
    --key-type EC:prime256v1 \
    --label "${KEY_LABEL}" \
    --usage-sign

  echo "Chave ECDSA gerada com sucesso no TPM."
fi

# --- PASSO 4: Gera o CSR ---
echo ""
echo "[4/5] Gerando CSR via provider PKCS#11 (OpenSSL 3 nativo)..."

PKCS11_URI="pkcs11:token=${TOKEN_LABEL};object=${KEY_LABEL};type=private;pin-value=${USER_PIN}"
CSR_FILE="${WPA_TPM_DIR}/client-tpm.csr"

openssl req -new \
  -provider pkcs11 -provider default \
  -key "${PKCS11_URI}" \
  -sha256 \
  -out "${CSR_FILE}" \
  -subj "/C=BR/ST=DF/L=Brasilia/O=LabSecurity/CN=${EAP_IDENTITY}"

# Verifica a assinatura do CSR
openssl req -in "${CSR_FILE}" -noout -verify
echo "CSR gerado e verificado: ${CSR_FILE}"

# --- PASSO 5: Resumo ---
echo ""
echo "[5/5] Provisionamento concluído."
echo ""
echo "Próximos passos:"
echo "  1. Transferir o CSR para a CA (gwlocal):"
echo "     scp ${CSR_FILE} root@<CA_IP>:/opt/8021x-eap-tls-lab/certs/"
echo ""
echo "  2. Assinar o certificado na CA:"
echo "     openssl x509 -req \\"
echo "       -in /opt/8021x-eap-tls-lab/certs/client-tpm.csr \\"
echo "       -CA /opt/8021x-eap-tls-lab/certs/ca-lab.crt \\"
echo "       -CAkey /opt/8021x-eap-tls-lab/private/ca-lab.key \\"
echo "       -CAcreateserial \\"
echo "       -out /opt/8021x-eap-tls-lab/certs/client-tpm.crt \\"
echo "       -days 365 -sha256"
echo ""
echo "  3. Transferir o certificado de volta:"
echo "     scp root@<CA_IP>:/opt/8021x-eap-tls-lab/certs/client-tpm.crt \\"
echo "       ${WPA_TPM_DIR}/"
echo ""
echo "  4. Copiar a CA para o diretório wpa (se ainda não estiver lá):"
echo "     cp /opt/8021x-eap-tls-lab/certs/ca-lab.crt /etc/wpa_supplicant/"
echo ""
echo "  5. Executar o wpa_supplicant:"
echo "     export TPM2_PKCS11_STORE=${PKCS11_STORE}"
echo "     wpa_supplicant -D wired -i enp0s3 \\"
echo "       -c /etc/wpa_supplicant/wpa_supplicant_tpm.conf"
