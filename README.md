# vivo-firewall

Atualiza automaticamente no roteador Vivo o endereço IPv6 de uma regra de
encaminhamento/liberação de porta.

## Motivação

Em conexões da Vivo, o IPv6 global atribuído ao equipamento pode mudar. A
interface de firewall de alguns roteadores da operadora não aceita curingas ou
prefixos para esse campo: ela aceita somente um endereço IPv6 global exato.
Isso torna necessário editar manualmente a regra sempre que o endereço muda —
e a interface de gerenciamento do roteador é especialmente ruim para esse
trabalho repetitivo.

Este script consulta o IPv6 global atual da máquina, compara-o com o último
endereço aplicado e, caso tenha mudado, autentica no roteador e cria ou edita a
regra para a porta informada. Ele foi pensado para ser executado pelo `cron` a
cada minuto.

## Requisitos

- Linux com IPv6 configurado na máquina que executará o script;
- acesso HTTP à interface do roteador Vivo;
- `bash`, `curl`, `ip` (iproute2), `awk`, `sed`, `grep`, `md5sum`, `base64` e
  `mktemp`;
- credenciais administrativas do roteador.

> O script foi desenvolvido a partir da interface HTTP deste roteador. Uma
> atualização de firmware ou outro modelo pode mudar os endpoints ou os campos
> usados e exigir ajustes.

## Uso

Clone ou copie o repositório para uma máquina da rede local que possua o IPv6
que deve ser liberado. Em seguida, torne o script executável, caso necessário:

```bash
chmod +x update.sh
```

Execute-o definindo ao menos a senha do roteador e a porta local a liberar:

```bash
ROUTER_PASSWORD='sua-senha' TARGET_PORT=25565 ./update.sh
```

Na primeira execução, o script cria a regra IPv6 para a porta. Nas execuções
seguintes, ele somente acessa o roteador se detectar que o IPv6 mudou.

### Variáveis de ambiente

| Variável | Obrigatória | Padrão | Descrição |
| --- | --- | --- | --- |
| `ROUTER_PASSWORD` | Sim | — | Senha do usuário administrativo do roteador. |
| `TARGET_PORT` | Sim | — | Porta local a liberar, entre 1 e 65535. |
| `ROUTER_IP` | Não | `192.168.15.1` | Endereço IP do roteador. |
| `ROUTER_USER` | Não | `admin` | Usuário administrativo do roteador. |
| `RULE_NAME` | Não | `Regra` | Nome exibido para a regra no roteador. |
| `IPV6_STATE_FILE` | Não | `/tmp/vivo-firewall-last-ipv6` | Arquivo que guarda o último IPv6 atualizado com sucesso. |

Se a mesma máquina mantém regras para mais de uma porta, use um arquivo de
estado distinto para cada uma:

```bash
ROUTER_PASSWORD='sua-senha' TARGET_PORT=25565 \
IPV6_STATE_FILE=/tmp/vivo-firewall-25565-ipv6 ./update.sh
```

O arquivo de estado só é atualizado depois que o roteador aceita a solicitação.
Assim, se houver erro de rede ou autenticação, o próximo ciclo tentará atualizar
novamente.

## Agendamento com cron

Evite deixar a senha diretamente no `crontab`, pois ela pode ficar visível para
outros processos ou usuários conforme a configuração do sistema. Crie, por
exemplo, um arquivo de configuração que seja legível apenas pelo usuário que
executará o cron:

```bash
mkdir -p ~/.config/vivo-firewall
chmod 700 ~/.config/vivo-firewall
```

Crie `~/.config/vivo-firewall/env` com este conteúdo (substitua os valores):

```bash
ROUTER_PASSWORD='sua-senha'
TARGET_PORT=25565
# Opcional:
# ROUTER_IP=192.168.15.1
# ROUTER_USER=admin
# RULE_NAME='Servidor'
```

Proteja o arquivo:

```bash
chmod 600 ~/.config/vivo-firewall/env
```

Abra o crontab com `crontab -e` e acrescente a linha abaixo, ajustando
`/caminho/para/vivo-firewall` para o diretório deste repositório:

```cron
* * * * * /usr/bin/env bash -c 'set -a; . /home/seu-usuario/.config/vivo-firewall/env; set +a; /caminho/para/vivo-firewall/update.sh' >> /tmp/vivo-firewall.log 2>&1
```

O `cron` executará o script uma vez por minuto. Quando o IPv6 não tiver mudado,
o log registrará que não há nada a fazer e nenhuma requisição será feita ao
roteador. Consulte o log com:

```bash
tail -f /tmp/vivo-firewall.log
```

Para testar a mesma configuração antes de aguardar o cron, carregue o arquivo
e execute o script manualmente:

```bash
set -a
. ~/.config/vivo-firewall/env
set +a
./update.sh
```

## Observações

- O script seleciona o primeiro IPv6 global que não seja temporário nem
  depreciado, retornado por `ip -6 addr show scope global`.
- A regra é identificada pela porta local (`TARGET_PORT`). Não mantenha mais de
  uma regra IPv6 para a mesma porta no roteador.
- A interface e o protocolo de autenticação do roteador podem expor detalhes
  sensíveis na saída do script. Restrinja o acesso ao arquivo de log e não o
  publique.
