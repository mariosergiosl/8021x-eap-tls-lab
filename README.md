# Laboratório de Autenticação 802.1X EAP-TLS (Baseado em Software)

Este repositório documenta a infraestrutura, configurações e comandos utilizados para estabelecer um ambiente de autenticação 802.1X com EAP-TLS em redes cabeadas.

## Arquitetura e Topologia

O laboratório simula um ambiente corporativo simplificado (sem FreeRADIUS), onde o switch de borda atua simultaneamente como Autenticador e Servidor de Autenticação.

| Ativo | Função | Sistema Operacional | Interface | IP / Rede |
|---|---|---|---|---|
| **gwlocal** | Autenticador e Servidor EAP-TLS (`hostapd`) | openSUSE Leap 15.6 | eth3 | 192.168.56.200/24 |
| **client** | Supplicant (`wpa_supplicant`) | SUSE Linux Enterprise 15 | enp0s3 | DHCP / 192.168.56.162 |

## 1. Geração da Infraestrutura de Chaves Públicas (PKI)

No cenário de laboratório baseado em software, todas as chaves e certificados foram gerados centralizadamente no servidor `gwlocal` utilizando OpenSSL, e os artefatos do cliente foram transferidos via SCP.

**Nota:** Material criptográfico (`*.key`, `*.crt`, `*.csr`) é ignorado pelo `.gitignore` e não deve ser versionado.

### 1.1 Autoridade Certificadora (Root CA)
\`\`\`bash
openssl genrsa -out private/ca-lab.key 4096
openssl req -new -x509 -days 3650 -key private/ca-lab.key -out certs/ca-lab.crt -subj "/C=BR/ST=DF/L=Brasilia/O=LabSecurity/CN=LabRootCA"
\`\`\`

### 1.2 Servidor (hostapd)
\`\`\`bash
openssl genrsa -out private/server.key 2048
openssl req -new -key private/server.key -out certs/server.csr -subj "/C=BR/ST=DF/L=Brasilia/O=LabSecurity/CN=gwcloud.lab.local"
openssl x509 -req -in certs/server.csr -CA certs/ca-lab.crt -CAkey private/ca-lab.key -CAcreateserial -out certs/server.crt -days 365 -sha256
\`\`\`

### 1.3 Cliente (wpa_supplicant)
\`\`\`bash
openssl genrsa -out private/client.key 2048
openssl req -new -key private/client.key -out certs/client.csr -subj "/C=BR/ST=DF/L=Brasilia/O=LabSecurity/CN=endpoint-client.lab.local"
openssl x509 -req -in certs/client.csr -CA certs/ca-lab.crt -CAkey private/ca-lab.key -CAcreateserial -out certs/client.crt -days 365 -sha256
\`\`\`


## 2. Configurações do Servidor (gwlocal)

Os arquivos do servidor estão versionados no diretório `conf/` e o script de inicialização na raiz do repositório.

### 2.1 hostapd.conf
Define a interface `eth3`, ativa o autenticador IEEE 802.1X interno e aponta para a PKI em `/etc/ssl/`.

### 2.2 hostapd.eap_user
Autoriza conexões via método EAP-TLS.

### 2.3 Execução
O script executa o daemon em segundo plano com geração de log detalhado no `/var/log/hostapd.log`:
```bash
/opt/8021x-eap-tls-lab/hostapd_run.bash
```

## 3. Configuração do Cliente (endpoint-client)
Os arquivos base estão localizados no diretório client/ deste repositório e foram transferidos para a VM destino.

### 3.1 wpa_supplicant.conf
Define a rede cabeada (driver wired), identidade EAP (endpoint-client.lab.local), e caminhos dos certificados locais no cliente.

### 3.2 Execução
Inicialização com elevação de verbosidade (debug) para análise do handshake:

```bash
wpa_supplicant -c /etc/wpa_supplicant/wpa_supplicant.conf -i enp0s3 -D wired -d
```





## 4. Troubleshooting e Erros Mapeados

Durante a execução deste laboratório, as seguintes falhas foram identificadas e corrigidas:

### 4.1 Erro: EACCES (Permission Denied) no hostapd
**Sintoma:** O daemon falhava ao iniciar, reportando `Failed to open output file descriptor` e `Could not open configuration file`, mesmo executado como `root`.
**Causa:** Bloqueio imposto pelo Mandatory Access Control (AppArmor) no openSUSE Leap, impedindo leitura/escrita em diretórios fora do padrão (`/opt/`). Adicionalmente, o binário realiza *privilege separation*.
**Solução Aplicada:**
1. Retorno dos arquivos para os caminhos FHS padrão (`/etc/hostapd/`, `/etc/ssl/`, `/var/log/`).
2. Desativação global do módulo AppArmor via parâmetro do kernel no GRUB.
**Nota sobre AppArmor:** Tentativas isoladas de desativar apenas o perfil do hostapd (`apparmor_parser -R` e `aa-disable`) foram documentadas, mas configuradas como não testadas isoladamente com sucesso, exigindo o bypass global no boot (`security=apparmor` removido do `/etc/default/grub`).

### 4.2 Erro: Timeout no wpa_supplicant (EAPOL txStart)
**Sintoma:** O cliente transmitia quadros `EAPOL-Start` repetidamente sem resposta do servidor.
**Causa:** O processo `hostapd` havia sido interrompido (SIGINT) no servidor. O switch virtual (VirtualBox) estava encaminhando os quadros L2 corretamente, mas o sistema operacional descartava por ausência de socket em estado de escuta.
**Solução Aplicada:** Reinicialização do `hostapd` em segundo plano (flag `-B`), assegurando sua persistência na memória durante a execução do cliente.
