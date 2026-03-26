# Laboratório de Autenticação 802.1X EAP-TLS

Este repositório documenta a infraestrutura, configurações e o processo de resolução de problemas para estabelecer autenticação 802.1X com EAP-TLS em redes cabeadas, cobrindo dois cenários:

- **Cenário A** — Chave privada em arquivo (sem TPM), para referência e comparação.
- **Cenário B** — Chave privada protegida por TPM 2.0 via PKCS#11, solução validada para SLES 16 / OpenSSL 3.5.

> **Status:** Ambos os cenários foram validados e estão funcionais neste lab. Este repositório é considerado estável. Novos experimentos (SP7, patch wpa_supplicant, IBM TSS engine) serão conduzidos em repositório separado.

---

## Arquitetura e Topologia

O laboratório simula um ambiente corporativo simplificado sem FreeRADIUS, onde o servidor `gwlocal` atua simultaneamente como Autenticador (IEEE 802.1X) e Servidor EAP interno via `hostapd`.

| Ativo | Função | Sistema Operacional | Interface | IP |
|---|---|---|---|---|
| **gwlocal** | Autenticador + Servidor EAP-TLS (`hostapd`) | openSUSE Leap 15.6 | eth3 | 192.168.56.200/24 |
| **sles16** | Supplicant (`wpa_supplicant`) | SUSE Linux Enterprise 16 | enp0s3 | 192.168.56.162/24 |

Ambiente de virtualização: VirtualBox no Windows 11. A comunicação L2 entre as VMs é feita via rede interna do VirtualBox.

---

## Estrutura do Repositório

```
8021x-eap-tls-lab/
├── conf/
│   ├── hostapd.conf              # Configuração do autenticador (servidor)
│   └── hostapd.eap_user          # Política EAP do servidor
├── client/
│   └── wpa_supplicant.conf       # Cenário A: supplicant sem TPM
├── tpm/
│   ├── conf/
│   │   └── wpa_supplicant_tpm.conf  # Cenário B: supplicant com TPM via PKCS#11
│   └── scripts/
│       ├── tpm_provision.sh         # Provisionamento automático do token TPM
│       └── sign_client_cert_tpm.py  # Assinatura de certificado (fallback Python)
├── hostapd_run.bash              # Script de execução do hostapd
├── update_git.bash               # Script de atualização do repositório
└── README.md
```

> **Nota:** Os diretórios `certs/` e `private/` existem apenas localmente e são ignorados pelo `.gitignore`. Material criptográfico nunca deve ser versionado.

---

## Cenário A — EAP-TLS com Chave em Arquivo (Sem TPM)

### PKI — Geração centralizada na gwlocal

```bash
# Autoridade Certificadora (Root CA)
openssl genrsa -out private/ca-lab.key 4096
openssl req -new -x509 -days 3650 \
  -key private/ca-lab.key \
  -out certs/ca-lab.crt \
  -subj "/C=BR/ST=DF/L=Brasilia/O=LabSecurity/CN=LabRootCA"

# Certificado do servidor (hostapd)
openssl genrsa -out private/server.key 2048
openssl req -new -key private/server.key \
  -out certs/server.csr \
  -subj "/C=BR/ST=DF/L=Brasilia/O=LabSecurity/CN=gwcloud.lab.local"
openssl x509 -req \
  -in certs/server.csr \
  -CA certs/ca-lab.crt -CAkey private/ca-lab.key -CAcreateserial \
  -out certs/server.crt -days 365 -sha256

# Certificado do cliente
openssl genrsa -out private/client.key 2048
openssl req -new -key private/client.key \
  -out certs/client.csr \
  -subj "/C=BR/ST=DF/L=Brasilia/O=LabSecurity/CN=endpoint-client.lab.local"
openssl x509 -req \
  -in certs/client.csr \
  -CA certs/ca-lab.crt -CAkey private/ca-lab.key -CAcreateserial \
  -out certs/client.crt -days 365 -sha256

# Transferência para o cliente
scp certs/ca-lab.crt certs/client.crt private/client.key \
  root@192.168.56.162:/etc/wpa_supplicant/
```

### Servidor — gwlocal

```bash
# Copia os certificados para os caminhos do hostapd
cp certs/ca-lab.crt /etc/ssl/certs/
cp certs/server.crt /etc/ssl/certs/
cp private/server.key /etc/ssl/private/
cp private/ca-lab.key /etc/ssl/private/
cp conf/hostapd.conf /etc/hostapd/
cp conf/hostapd.eap_user /etc/hostapd/

# Inicia o hostapd
./hostapd_run.bash
```

### Cliente — sles16

```bash
wpa_supplicant -D wired -i enp0s3 \
  -c /etc/wpa_supplicant/wpa_supplicant.conf -d
```

O arquivo `client/wpa_supplicant.conf` contém a configuração de referência para este cenário.

---

## Cenário B — EAP-TLS com Chave Protegida por TPM 2.0

### Por que PKCS#11 e não tpm2tss engine?

Durante o desenvolvimento deste lab, várias abordagens foram tentadas para integrar o TPM ao `wpa_supplicant` no SLES 16 (OpenSSL 3.5). O resultado foi que o `tpm2-tss-engine` (engine OpenSSL 1.x) é **incompatível com OpenSSL 3.5** — as assinaturas RSA produzidas pelo engine são rejeitadas pelo verificador do servidor. A incompatibilidade foi confirmada por teste direto:

```bash
# Teste que confirmou a incompatibilidade:
OPENSSL_CONF=/dev/null openssl dgst -engine tpm2tss -keyform engine \
  -sign tpm2-client.key -sha256 -out test.sig test.txt
openssl dgst -verify <(openssl x509 -in client-tpm.crt -pubkey -noout) \
  -sha256 -signature test.sig test.txt
# Resultado: Verification failure
```

O próprio projeto `tpm2-tss-engine` indica em seu README: *"If you are looking for a provider following the OpenSSL 3.0 provider API instead of the engine API, please head over to tpm2-openssl"*. O caminho correto para SLES 16 é a interface PKCS#11, documentada nesta seção.

Para a discussão completa de todas as tentativas e erros, veja a seção **Troubleshooting**.

### Stack de componentes (SLES 16)

| Componente | Função | Disponibilidade |
|---|---|---|
| `tpm2-openssl` | Provider OpenSSL 3 nativo para TPM 2.0 | RPM SLES 16 |
| `tpm2-pkcs11` | Expõe o TPM como token PKCS#11 | **Compilar da fonte** |
| `openssl-engine-libp11` | Engine legado que o `wpa_supplicant` usa para URIs `pkcs11:` | RPM SLES 16 |
| `pkcs11-provider` | Provider OpenSSL 3 para PKCS#11 (geração do CSR) | RPM SLES 16 |
| `tpm2.0-abrmd` | Resource Manager do TPM (obrigatório para TLS) | RPM SLES 16 |
| `opensc` | Ferramentas PKCS#11 (`pkcs11-tool`) | RPM SLES 16 |

### Instalação de pacotes

```bash
zypper install -y \
  tpm2-openssl tpm2-tss-engine tpm2.0-abrmd tpm2.0-tools \
  opensc pkcs11-provider openssl-engine-libp11 libp11-3 \
  python3-devel libyaml-devel cmake autoconf automake libtool \
  sqlite3-devel tpm2-0-tss-devel p11-kit-devel git

systemctl enable --now tpm2-abrmd.service
```

### Compilação do tpm2-pkcs11

O `tpm2-pkcs11` não está disponível no repositório SLES 16 e deve ser compilado da fonte. A flag `--disable-ptool-checks` dispensa a dependência Python (`tpm2_pytss`) que não compila com GCC 15 + Python 3.13 do SLES 16.

```bash
cd /usr/local/src
git clone https://github.com/tpm2-software/tpm2-pkcs11.git
cd tpm2-pkcs11

./bootstrap
./configure \
  --with-storedir=/etc/tpm2-pkcs11 \
  --disable-ptool-checks \
  --with-fapi=no

make -j$(nproc)
make install

# Registra a biblioteca
echo '/usr/local/lib' > /etc/ld.so.conf.d/tpm2-pkcs11.conf
ldconfig

# Registra o módulo no p11-kit
cat > /usr/share/p11-kit/modules/tpm2-pkcs11.module << 'EOF'
module: /usr/local/lib/libtpm2_pkcs11.so
managed: yes
log-calls: no
EOF
```

### Provisionamento do token TPM

O script `tpm/scripts/tpm_provision.sh` automatiza todo o processo. Passos manuais para referência:

```bash
export TPM2_PKCS11_STORE=/etc/tpm2-pkcs11
mkdir -p /etc/tpm2-pkcs11 /etc/wpa_supplicant/tpm

# Inicializa o token
pkcs11-tool --module /usr/local/lib/libtpm2_pkcs11.so \
  --init-token --label "endpoint-tpm" --so-pin "12345678"

pkcs11-tool --module /usr/local/lib/libtpm2_pkcs11.so \
  --token-label "endpoint-tpm" --init-pin \
  --so-pin "12345678" --pin "1234"

# Gera chave ECDSA P-256 dentro do TPM
pkcs11-tool --module /usr/local/lib/libtpm2_pkcs11.so \
  --token-label "endpoint-tpm" --login --pin "1234" \
  --keypairgen --key-type EC:prime256v1 \
  --label "endpoint-client-key" --usage-sign

# Gera o CSR via provider PKCS#11 (OpenSSL 3 nativo)
openssl req -new \
  -provider pkcs11 -provider default \
  -key "pkcs11:token=endpoint-tpm;object=endpoint-client-key;type=private;pin-value=1234" \
  -sha256 \
  -out /etc/wpa_supplicant/tpm/client-tpm.csr \
  -subj "/C=BR/ST=DF/L=Brasilia/O=LabSecurity/CN=endpoint-client.lab.local"

# Verifica o CSR
openssl req -in /etc/wpa_supplicant/tpm/client-tpm.csr -noout -verify
# Saída esperada: Certificate request self-signature verify OK
```

### Assinatura do certificado na CA (gwlocal)

```bash
# Recebe o CSR do cliente
scp root@192.168.56.162:/etc/wpa_supplicant/tpm/client-tpm.csr \
  /opt/8021x-eap-tls-lab/certs/

# Assina normalmente — CSR gerado via pkcs11 provider é aceito sem bypass
openssl x509 -req \
  -in /opt/8021x-eap-tls-lab/certs/client-tpm.csr \
  -CA /opt/8021x-eap-tls-lab/certs/ca-lab.crt \
  -CAkey /opt/8021x-eap-tls-lab/private/ca-lab.key \
  -CAcreateserial \
  -out /opt/8021x-eap-tls-lab/certs/client-tpm.crt \
  -days 365 -sha256

# Devolve ao cliente
scp /opt/8021x-eap-tls-lab/certs/client-tpm.crt \
  root@192.168.56.162:/etc/wpa_supplicant/tpm/
```

### Execução do cliente com TPM

```bash
export TPM2_PKCS11_STORE=/etc/tpm2-pkcs11

wpa_supplicant -D wired -i enp0s3 \
  -c /etc/wpa_supplicant/wpa_supplicant_tpm.conf
```

O arquivo `tpm/conf/wpa_supplicant_tpm.conf` contém a configuração completa com comentários.

### Verificação de sucesso

**Log do cliente (sles16):**
```
enp0s3: CTRL-EVENT-EAP-SUCCESS EAP authentication completed successfully
enp0s3: CTRL-EVENT-CONNECTED - Connection to 01:80:c2:00:00:03 completed
```

**Log do servidor (gwlocal):**
```
eth3: CTRL-EVENT-EAP-SUCCESS 08:00:27:82:09:86
eth3: AP-STA-CONNECTED 08:00:27:82:09:86
eth3: STA 08:00:27:82:09:86 IEEE 802.1X: authenticated
```

---

## Troubleshooting — Erros Encontrados e Soluções

Esta seção documenta todos os erros encontrados durante o desenvolvimento, em ordem cronológica de ocorrência, incluindo as tentativas que não funcionaram. O objetivo é servir como referência para quem enfrentar o mesmo caminho.

### T01 — EACCES (Permission Denied) no hostapd

**Sintoma:** O daemon falhava ao iniciar reportando `Failed to open output file descriptor` e `Could not open configuration file`, mesmo como `root`.

**Causa:** AppArmor no openSUSE Leap bloqueando acesso a diretórios fora do padrão FHS (`/opt/`). O hostapd também realiza privilege separation internamente.

**Solução:**
1. Mover todos os arquivos para os caminhos FHS padrão (`/etc/hostapd/`, `/etc/ssl/`, `/var/log/`).
2. Desativar o AppArmor globalmente via parâmetro de kernel (`security=apparmor` removido de `/etc/default/grub`, seguido de `grub2-mkconfig`).

**Nota:** Tentativas de desativar apenas o perfil do hostapd (`apparmor_parser -R`, `aa-disable`) não foram suficientes.

---

### T02 — Timeout EAPOL (txStart repetido sem resposta)

**Sintoma:** O cliente transmitia quadros `EAPOL-Start` repetidamente sem resposta do servidor.

**Causa:** O processo `hostapd` havia sido interrompido (SIGINT). O switch virtual do VirtualBox encaminhava os quadros L2 corretamente, mas o SO descartava por ausência de socket em escuta.

**Solução:** Reinicializar o `hostapd` antes de executar o cliente. Usar a flag `-B` para execução em background.

---

### T03 — Failed to load private key 'tpm2:handle:0x81010001'

**Sintoma:**
```
error:80000002:system library::No such file or directory
error:10000080:BIO routines::no such file
TLS: Failed to load private key 'tpm2:handle:0x81010001'
```

**Causa:** O `wpa_supplicant` chama `SSL_use_PrivateKey_file()` que tenta abrir a string como caminho de arquivo no filesystem. A URI `tpm2:handle:` não é reconhecida por este caminho de código — não usa `OSSL_STORE_open()` do provider.

**Solução:** Não usar URI `tpm2:handle:` diretamente no `private_key`. Usar arquivo TSS2 PEM ou URI PKCS#11.

---

### T04 — ENGINE: engine tpm2 not available / DSO not found

**Sintoma:**
```
error:12800067:DSO support routines::could not load the shared library
filename(/usr/lib64/engines-3/tpm2.so): No such file or directory
```

**Causa:** O RPM `tpm2-tss-engine` instala o engine como `tpm2tss.so`, mas o `wpa_supplicant` detecta o cabeçalho `BEGIN TSS2 PRIVATE KEY` no arquivo PEM e busca por `tpm2.so`.

**Diagnóstico:**
```bash
rpm -ql tpm2-tss-engine | grep '\.so'
# /usr/lib64/engines-3/libtpm2tss.so
# /usr/lib64/engines-3/tpm2tss.so  ← nome real
```

**Tentativa:** Criar symlink `tpm2.so → tpm2tss.so`. O engine passa a carregar, mas gera o erro T05.

---

### T05 — rsa routines::bad signature (servidor rejeita o CertificateVerify)

**Sintoma no hostapd:**
```
SSL: SSL3 alert: write (local SSL3 detected an error):fatal:decrypt error
OpenSSL: openssl_handshake - SSL_connect error:0A00007B:SSL routines::bad signature
```

**Causa:** O engine `tpm2tss` (API OpenSSL 1.x) produz assinaturas RSA com formato incompatível com o verificador OpenSSL 3.5 do servidor. Incompatibilidade de ABI confirmada por teste direto:

```bash
echo "test" > /tmp/test.txt
OPENSSL_CONF=/dev/null openssl dgst -engine tpm2tss -keyform engine \
  -sign tpm2-client.key -sha256 -out /tmp/test.sig /tmp/test.txt

openssl dgst \
  -verify <(openssl x509 -in client-tpm.crt -pubkey -noout) \
  -sha256 -signature /tmp/test.sig /tmp/test.txt
# Resultado: Verification failure
```

**Tentativa com ECDSA:** A troca para curva P-256 (`tpm2tss-genkey -a ecdsa -c nist_p256`) não resolveu — a incompatibilidade é na camada de ABI da API de engines, independente do algoritmo.

**Conclusão:** O `tpm2-tss-engine` não é compatível com OpenSSL 3.5 para assinatura TLS. O próprio projeto recomenda migrar para `tpm2-openssl` (provider) para OpenSSL 3.x.

---

### T06 — Certificate request self-signature did not match (CA rejeita o CSR)

**Sintoma:**
```
Certificate request self-signature did not match the contents
error:02000068:rsa routines:ossl_rsa_verify:bad signature
```

**Causa:** O `openssl x509 -req` no OpenSSL 3 verifica a autoassinatura do CSR por padrão. O engine `tpm2tss` produz assinaturas que o verificador OpenSSL 3 rejeita — mesmo problema do T05, manifestado na CA.

**Tentativas:**
- `openssl x509 -req -force_pubkey` — não bypassa a verificação no OpenSSL 3.1.x (só funciona a partir do 3.3).
- Script Python com `cryptography` lib — carrega o CSR sem verificar autoassinatura e assina com a CA normalmente. **Funcionou como workaround**, mas foi descartado quando migramos para PKCS#11 (onde o CSR passa na verificação normalmente).

---

### T07 — ENGINE: cannot set pin / invalid cmd name

**Sintoma:**
```
ENGINE: cannot set pin [error:13000089:engine routines::invalid cmd name]
```

**Causa:** O engine `tpm2tss` não implementa o comando `PIN` da interface de engines OpenSSL. Esse comando é específico de engines PKCS#11 (`libp11`). O parâmetro `pin=""` no `wpa_supplicant.conf` provoca este erro.

**Solução:** Remover o parâmetro `pin=` quando usando `engine_id="tpm2tss"`.

---

### T08 — error:43000071:tpm2-tss-engine::User interaction

**Sintoma:**
```
ENGINE: cannot load private key with id '...' [error:43000071:tpm2-tss-engine::User interaction]
```

**Causa:** Quando a chave TPM foi provisionada via `tpm2tss-genkey -p 0x81010001` (apontando para handle persistente), o engine não consegue autenticar sem callback de UI. O `wpa_supplicant` passa `UI_METHOD = NULL`, causando abort.

**Solução:** Usar `tpm2tss-genkey` sem o parâmetro `-p` (blob embutido no PEM, não referência a handle). Porém esta abordagem também falha em T05.

---

### T09 — tpm2_pytss build failure / pycparser nullptr_t

**Sintoma:**
```
pycparser.c_parser.ParseError: /usr/lib64/gcc/x86_64-suse-linux/15/include/stddef.h:465:31: before: nullptr_t
```

**Causa:** O `pycparser` 2.22/3.0 não reconhece `nullptr_t` introduzido no C23, usado nos headers do GCC 15 do SLES 16. O `tpm2_pytss` é dependência das ferramentas Python do `tpm2-pkcs11` (`tpm2_ptool`).

**Solução:** Compilar o `tpm2-pkcs11` com `--disable-ptool-checks --with-fapi=no`, dispensando o `tpm2_ptool` e a dependência Python. O `.so` da biblioteca PKCS#11 compila sem esta dependência.

---

### T10 — ENGINE: engine pkcs11 not available (após migrar para PKCS#11)

**Sintoma:**
```
SSL: Initializing TLS engine pkcs11
ENGINE: engine pkcs11 not available [error:12800067:DSO support routines::could not load the shared library]
```

**Causa:** O `wpa_supplicant` detecta o prefixo `pkcs11:` na URI e tenta carregar o engine legado `pkcs11` via libp11, que não estava instalado.

**Solução:** Instalar `openssl-engine-libp11` e `libp11-3`.

```bash
zypper install -y openssl-engine-libp11 libp11-3
# Verificação:
openssl engine pkcs11 -t
# Saída esperada: (pkcs11) pkcs11 engine / [ available ]
```

---

## Por que PKCS#11 é o caminho correto para SLES 16

O diagrama abaixo resume o fluxo de chamadas e onde cada abordagem falhou:

```
wpa_supplicant
    │
    ├─ detecta "BEGIN TSS2 PRIVATE KEY" ──► força engine "tpm2"
    │                                           │
    │                                           ├─ tpm2tss.so (OpenSSL 1.x ABI)
    │                                           │   └─ assina RSA/ECDSA
    │                                           │       └─ FALHA: bad signature
    │                                           │          no verificador OpenSSL 3.5
    │
    └─ detecta "pkcs11:" na URI ──────────► engine "pkcs11" (libp11)
                                                │
                                                └─ libtpm2_pkcs11.so
                                                    │
                                                    └─ TPM 2.0 (via tpm2-abrmd)
                                                        └─ ECDSA P-256
                                                            └─ ✓ SUCESSO
```

A interface PKCS#11 é o caminho suportado pela comunidade `tpm2-software` para `wpa_supplicant` + TPM 2.0, conforme documentado em https://github.com/tpm2-software/tpm2-pkcs11/blob/master/docs/EAP-TLS.md.

---

## Trabalhos Futuros (Repositório Separado)

Os seguintes temas serão explorados em laboratório dedicado:

- **IBM TSS engine (`SUSE::Security`)** — alternativa para SLES 15 SP6/SP7, nome do pacote a confirmar. Não testado no SLES 16.
- **Patch no wpa_supplicant** — modificação do código-fonte para redirecionar a detecção TSS2 para `OSSL_STORE_open()` em vez do engine legado. Há um bug aberto upstream sobre este comportamento.
- **NetworkManager integration** — uso do `libnm` para configurar a autenticação 802.1X via NetworkManager, eliminando dependência direta do `wpa_supplicant`. Referência: repositório `PerryWerneck/tpmtest`.
- **Script de enrollment em escala** — automação para provisionamento de 30k+ endpoints, empacotamento RPM do `tpm2-pkcs11`.

---

## Referências

| Recurso | URL |
|---|---|
| tpm2-pkcs11 — EAP-TLS oficial | https://github.com/tpm2-software/tpm2-pkcs11/blob/master/docs/EAP-TLS.md |
| tpm2-openssl — Provider OpenSSL 3 | https://github.com/tpm2-software/tpm2-openssl |
| tpm2-tss-engine — Engine legado (OpenSSL 1.x) | https://github.com/tpm2-software/tpm2-tss-engine |
| PerryWerneck/tpmtest — referência de integração NM | https://github.com/PerryWerneck/tpmtest |
| hostapd — Documentação oficial | https://w1.fi/hostapd/ |
| wpa_supplicant — Documentação oficial | https://w1.fi/wpa_supplicant/ |
