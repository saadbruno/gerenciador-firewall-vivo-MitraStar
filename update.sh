#!/usr/bin/env bash

ROUTER="http://${ROUTER_IP:-192.168.15.1}"
ROUTER_USER="${ROUTER_USER:-admin}"

# Exact local port of the IPv6 rule to update or create.
RULE_NAME="${RULE_NAME:-Regra}"

if [[ ! -v ROUTER_PASSWORD ]]; then
    echo "ERRO: Falta a variável ROUTER_PASSWORD";
    exit 1
fi  

if [[ ! -v TARGET_PORT ]]; then
    echo "ERRO: Falta a variável TARGET_PORT";
    exit 1
fi  

if [[ ! "$TARGET_PORT" =~ ^[0-9]{1,5}$ ]] || (( 10#$TARGET_PORT < 1 || 10#$TARGET_PORT > 65535 )); then
    echo "ERRO: TARGET_PORT deve ser uma porta entre 1 e 65535."
    exit 1
fi
TARGET_PORT=$((10#$TARGET_PORT))

COOKIE_JAR="/tmp/router-cookies.txt"
rm -f "$COOKIE_JAR"

echo "1. Pegando página de login..."

LOGIN_HTML=$(curl -sS -L \
    -c "$COOKIE_JAR" \
    -b "$COOKIE_JAR" \
    "$ROUTER/login_frame.html")

echo "Tamanho da página de login: ${#LOGIN_HTML} bytes"

echo
echo "Procurando SID..."

printf '%s\n' "$LOGIN_HTML" | grep -i 'var sid' || {
    echo "ERRO: SID não foi encontrado."
    echo
    echo "Primeiras 30 linhas retornadas pelo roteador:"
    printf '%s\n' "$LOGIN_HTML" | head -30
    exit 1
}

SID=$(printf '%s\n' "$LOGIN_HTML" |
    sed -n 's/.*var sid *= *"\([^"]*\)".*/\1/p' |
    head -1)

echo "SID = $SID"

echo
echo "2. Criando chave de login..."

PASSWORD_HASH=$(printf '%s' "$SID:$ROUTER_PASSWORD" |
    md5sum |
    awk '{print $1}')

LOGIN_KEY=$(printf '%s' "$ROUTER_USER:$PASSWORD_HASH" |
    base64 -w0)

echo "MD5 = $PASSWORD_HASH"
echo "LOGIN_KEY = $LOGIN_KEY"

echo
echo "3. Fazendo login..."

LOGIN_RESPONSE=$(curl -sS -L \
    -c "$COOKIE_JAR" \
    -b "$COOKIE_JAR" \
    -e "$ROUTER/login_frame.html" \
    --data-urlencode "sessionKey=$LOGIN_KEY" \
    --data-urlencode "user=$ROUTER_USER" \
    --data-urlencode "pass=" \
    "$ROUTER/login-login.cgi")

echo "Tamanho da resposta de login: ${#LOGIN_RESPONSE} bytes"

echo
echo "Cookies:"
cat "$COOKIE_JAR"

echo
echo "4. Obtendo página do firewall..."

FIREWALL_HTML=$(curl -sS -L \
    -c "$COOKIE_JAR" \
    -b "$COOKIE_JAR" \
    "$ROUTER/webs/settings-firewall.html")

echo "Tamanho da página do firewall: ${#FIREWALL_HTML} bytes"

echo
echo "Procurando sessionKey..."

printf '%s\n' "$FIREWALL_HTML" | grep -i 'sessionKey' | head -10

SESSION_KEY=$(printf '%s\n' "$FIREWALL_HTML" |
    sed -n "s/.*var sessionKey *= *'\([0-9]*\)'.*/\1/p" |
    head -1)

echo
echo "Chave de sessão do firewall extraída: [$SESSION_KEY]"

if [ -z "$SESSION_KEY" ]; then
    echo
    echo "ERRO: Não foi possível extrair a sessionKey autenticada."
    echo
    echo "Verificando se fomos redirecionados para o login..."
    printf '%s\n' "$FIREWALL_HTML" |
        grep -i -E 'não está Autenticado|login-login|id="login"|showLoginErr' |
        head -20

    exit 1
fi

echo
echo "=== Logado com sucesso na página do Firewall! ==="
echo
echo "5. Iniciando atualização de portas"
echo

# The page uses fields 2, 7 and 8 (zero-based) for local port, order
# and ruleIndex. Keep empty slash-separated fields when parsing.
GUI_RULES=$(printf '%s\n' "$FIREWALL_HTML" |
    sed -n "s/^[[:space:]]*var firewallForwardGuiRule[[:space:]]*=[[:space:]]*'\([^']*\)'[[:space:]]*;.*/found:\1/p")

if [[ "$GUI_RULES" != found:* || "$GUI_RULES" == *$'\n'* ]]; then
    echo "ERRO: Não foi possível extrair as regras do firewall."
    exit 1
fi
# An explicitly empty list is valid; a missing declaration is not.
GUI_RULES=${GUI_RULES#found:}

RULE_ORDER=$(printf '%s\n' "$FIREWALL_HTML" |
    sed -n "s/^[[:space:]]*var firewallRuleOrder[[:space:]]*=[[:space:]]*'\([0-9]*\)'[[:space:]]*;.*/\1/p")
if [[ ! "$RULE_ORDER" =~ ^[0-9]+$ ]]; then
    echo "ERRO: Não foi possível extrair a ordem das regras do firewall."
    exit 1
fi

RULE_METADATA=$(printf '%s\n' "$GUI_RULES" |
    awk -v port="$TARGET_PORT" '
        BEGIN { RS = "|"; FS = "/" }
        /^[[:space:]]*$/ { next }
        NF != 13 || $8 !~ /^[0-9]+$/ || $9 !~ /^[0-9]+$/ {
            invalid = 1
            next
        }
        # Require an exact local-port match and an existing IPv6 address.
        ("port:" $3) == ("port:" port) && $4 ~ /:/ {
            matches++
            if ($5 !~ /^(acpt|rjct)(Local|Remote|Both)$/)
                invalid = 1
            metadata = $9 " " $8 " " $5
        }
        END {
            if (matches > 1 || invalid) {
                printf "ERROR: Invalid firewall rules or ambiguous IPv6 rules for local port %s (%d matches).\n", port, matches > "/dev/stderr"
                exit 1
            }
            if (matches == 1)
                print metadata
        }
    ') || exit 1

EDIT_ARGS=()
if [ -n "$RULE_METADATA" ]; then
    RULE_ACTION=edit
    RULE_ACTION_LABEL="editar"
    read -r RULE_INDEX EDIT_ORDER OLD_ACTION <<< "$RULE_METADATA"
    EDIT_ARGS=(
        --data-urlencode "editOrder=$EDIT_ORDER"
        --data-urlencode "oldActionGVT=$OLD_ACTION"
    )
    echo "Porta local selecionada $TARGET_PORT: índice da regra=$RULE_INDEX, ordem de edição=$EDIT_ORDER"
else
    RULE_ACTION=add
    RULE_ACTION_LABEL="criar"
    RULE_INDEX=$(printf '%s\n' "$FIREWALL_HTML" |
        sed -n "s/^[[:space:]]*var firewallRuleIndex[[:space:]]*=[[:space:]]*'\([0-9]*\)'[[:space:]]*;.*/\1/p")
    if [[ ! "$RULE_INDEX" =~ ^[0-9]+$ ]]; then
        echo "ERRO: Não foi possível extrair o próximo índice da regra do firewall."
        exit 1
    fi
    echo "Nenhuma regra IPv6 para a porta local $TARGET_PORT; criando índice da regra=$RULE_INDEX, ordem=$RULE_ORDER"
fi


IPV6=$(
    ip -6 addr show scope global |
    awk '/inet6/ && !/temporary/ && !/deprecated/ {
        split($2,a,"/");
        print a[1];
        exit
    }'
)

echo "IPv6 atual: $IPV6"

echo "Enviando solicitação para $RULE_ACTION_LABEL a regra do firewall..."

RESPONSE=$(curl -sS -G \
    -c "$COOKIE_JAR" \
    -b "$COOKIE_JAR" \
    "$ROUTER/webs/firewall-181Gvt.cmd" \
    -e "$ROUTER/webs/settings-firewall.html" \
    --data-urlencode "action=$RULE_ACTION" \
    --data-urlencode 'ruleEnbl=1' \
    --data-urlencode "ruleIndex=$RULE_INDEX" \
    "${EDIT_ARGS[@]}" \
    --data-urlencode "order=$RULE_ORDER" \
    --data-urlencode "ruleName=$RULE_NAME" \
    --data-urlencode 'protocol=TCPorUDP' \
    --data-urlencode "srcStartPort=$TARGET_PORT" \
    --data-urlencode "srcAddr=$IPV6" \
    --data-urlencode 'actionType=Accept' \
    --data-urlencode 'defaultAction=Reject' \
    --data-urlencode 'icmpStatus=Accept' \
    --data-urlencode 'IPVersion=6' \
    --data-urlencode 'icmpType=any' \
    --data-urlencode 'icmpV6Type=destination-unreachable' \
    --data-urlencode 'actionGVT=acptBoth' \
    --data-urlencode "sessionKey=$SESSION_KEY"
) || exit 1

if grep -q 'Invalid Session Key' <<< "$RESPONSE"; then
    echo "ERRO: O roteador rejeitou a chave de sessão."
    exit 1
fi

echo "Solicitação para $RULE_ACTION_LABEL a regra enviada."
