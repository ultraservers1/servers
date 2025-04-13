#!/bin/bash

# Verificar se está rodando com sudo
if [ "$EUID" -ne 0 ]; then
    echo -e "\033[31mEste script precisa ser executado com sudo! Use: sudo $0\033[0m"
    exit 1
fi

# Variáveis para cores
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
BLUE="\033[34m"
CYAN="\033[36m"
RESET="\033[0m"
BOLD="\033[1m"

# Variáveis de configuração
DOMINIO="pterodactyl.ultra.local"
MYSQL_USER="pterodactyl"
MYSQL_PASS=$(openssl rand -base64 16 | tr -d '/+=' | head -c 16)
PANEL_DB="panel"
ADMIN_EMAIL="admin@ultra.local"
ADMIN_PASS=$(openssl rand -base64 16 | tr -d '/+=' | head -c 16)
CRED_FILE="/root/pterodactyl_credentials.txt"
LOG_FILE="/root/pterodactyl_install.log"
BACKUP_DIR="/root/pterodactyl_backup_$(date +%F_%H-%M-%S)"

# Função para exibir o logo ULTRA com animação
exibir_logo() {
    clear
    echo -e "${BLUE}"
    for line in \
        "${BOLD}██╗░░░██╗██╗░░░░░████████╗██████╗░░█████╗░" \
        "${BOLD}██║░░░██║██║░░░░░╚══██╔══╝██╔══██╗██╔══██╗" \
        "${BOLD}██║░░░██║██║░░░░░░░░██║░░░██████╔╝███████║" \
        "${BOLD}██║░░░██║██║░░░░░░░░██║░░░██╔═══╝░██╔══██║" \
        "${BOLD}╚██████╔╝███████╗░░░██║░░░██║░░░░░██║░░██║" \
        "${BOLD}░╚═════╝░╚══════╝░░░╚═╝░░░╚═╝░░░░░╚═╝░░╚═╝"; do
        echo -e "$line"
        sleep 0.1
    done
    echo -e "${RESET}"
    sleep 0.5
}

# Função para barra de progresso simulada
progress_bar() {
    local duration=$1
    local task_name=$2
    echo -e "${YELLOW}${task_name}...${RESET}" | tee -a $LOG_FILE
    for ((i=0; i<=20; i+=2)); do
        printf "\r${CYAN}[%-20s] %d%%${RESET}" "$(printf '#%.0s' {1..$i})" $((i*5))
        sleep $(echo "$duration/20" | bc -l)
    done
    echo -e "\r${GREEN}${task_name} concluído!${RESET}" | tee -a $LOG_FILE
}

# Função para verificar pré-requisitos
verificar_prerequisitos() {
    echo -e "${YELLOW}Verificando pré-requisitos...${RESET}" | tee -a $LOG_FILE
    if [ $(df -BG / | tail -1 | awk '{print $4}' | tr -d 'G') -lt 2 ]; then
        echo -e "${RED}Espaço insuficiente! São necessários pelo menos 2 GB livres.${RESET}" | tee -a $LOG_FILE
        exit 1
    fi
    if ! ping -c 1 google.com &>/dev/null; then
        echo -e "${RED}Sem conexão com a internet! Verifique sua rede.${RESET}" | tee -a $LOG_FILE
        exit 1
    fi
    apt -y install htop nmon &>/dev/null
    echo -e "${CYAN}Recursos do servidor:${RESET}" | tee -a $LOG_FILE
    lscpu | grep '^CPU(s):' | tee -a $LOG_FILE
    free -h | grep Mem | awk '{print "Memória: " $2 " total, " $3 " usada"}' | tee -a $LOG_FILE
    echo -e "${GREEN}Pré-requisitos OK!${RESET}" | tee -a $LOG_FILE
}

# Função para limpar arquivos inválidos de repositórios
limpar_repositorios() {
    echo -e "${YELLOW}Limpando arquivos inválidos em /etc/apt/sources.list.d/...${RESET}" | tee -a $LOG_FILE
    find /etc/apt/sources.list.d/ -type f -name '*.old*' -delete 2>/dev/null
    find /etc/apt/sources.list.d/ -type f -name '*.bak' -delete 2>/dev/null
    rm -f /etc/apt/sources.list.d/mariadb.list 2>/dev/null
    apt update 2>/dev/null
    echo -e "${GREEN}Repositórios limpos!${RESET}" | tee -a $LOG_FILE
}

# Função para preparar o apt
preparar_apt() {
    progress_bar 5 "Preparando o sistema de pacotes"
    apt update || { echo -e "${RED}Erro no apt update.${RESET}" | tee -a $LOG_FILE; exit 1; }
    apt --fix-broken install -y
    apt full-upgrade -y
    apt autoremove -y
    limpar_repositorios
    apt update
}

# Função para instalar dependências
instalar_dependencias() {
    progress_bar 30 "Instalando dependências para Ubuntu 20.04"
    apt -y install software-properties-common curl apt-transport-https ca-certificates gnupg
    LC_ALL=C.UTF-8 add-apt-repository -y ppa:ondrej/php
    curl -LsS https://r.mariadb.com/downloads/mariadb_repo_setup | bash
    curl -fsSL https://packages.redis.io/gpg | gpg --dearmor -o /usr/share/keyrings/redis-archive-keyring.gpg
    echo "deb [signed-by=/usr/share/keyrings/redis-archive-keyring.gpg] https://packages.redis.io/deb $(lsb_release -cs) main" > /etc/apt/sources.list.d/redis.list
    apt update
    apt -y install php8.3 php8.3-{common,cli,gd,mysql,mbstring,bcmath,xml,fpm,curl,zip} mariadb-server nginx tar unzip git redis-server python3-certbot-nginx
    curl -sS https://getcomposer.org/installer | php -- --install-dir=/usr/local/bin --filename=composer
}

# Função para configurar o banco de dados
configurar_banco() {
    progress_bar 10 "Configurando banco de dados"
    systemctl enable mariadb
    systemctl start mariadb
    mysql -u root -e "CREATE USER '$MYSQL_USER'@'127.0.0.1' IDENTIFIED BY '$MYSQL_PASS';" || {
        echo -e "${RED}Erro ao criar usuário MySQL.${RESET}" | tee -a $LOG_FILE
        exit 1
    }
    mysql -u root -e "CREATE DATABASE $PANEL_DB;" || {
        echo -e "${RED}Erro ao criar banco de dados.${RESET}" | tee -a $LOG_FILE
        exit 1
    }
    mysql -u root -e "GRANT ALL PRIVILEGES ON $PANEL_DB.* TO '$MYSQL_USER'@'127.0.0.1' WITH GRANT OPTION;"
}

# Função para baixar e instalar o Pterodactyl
instalar_pterodactyl() {
    progress_bar 20 "Instalando Pterodactyl"
    mkdir -p /var/www/pterodactyl
    cd /var/www/pterodactyl
    curl -Lo panel.tar.gz https://github.com/pterodactyl/panel/releases/latest/download/panel.tar.gz
    tar -xzvf panel.tar.gz
    chmod -R 755 storage/* bootstrap/cache/
    cp .env.example .env
    COMPOSER_ALLOW_SUPERUSER=1 composer install --no-dev --optimize-autoloader
    php artisan key:generate --force
}

# Função para configurar o ambiente
configurar_ambiente() {
    progress_bar 15 "Configurando ambiente"
    cd /var/www/pterodactyl
    php artisan p:environment:setup --author="$ADMIN_EMAIL" --url="http://$DOMINIO" --timezone="UTC" --cache="redis" --session="redis" --queue="redis" --no-interaction
    php artisan p:environment:database --host="127.0.0.1" --port="3306" --database="$PANEL_DB" --username="$MYSQL_USER" --password="$MYSQL_PASS" --no-interaction
    php artisan p:environment:mail --driver="mail" --no-interaction
    php artisan migrate --seed --force
}

# Função para criar usuário administrador
criar_usuario_admin() {
    progress_bar 5 "Criando usuário administrador"
    cd /var/www/pterodactyl
    USERNAME=$(echo "$ADMIN_EMAIL" | cut -d '@' -f 1)
    php artisan p:user:make --email="$ADMIN_EMAIL" --username="$USERNAME" --name-first="Admin" --name-last="User" --password="$ADMIN_PASS" --admin=1 --no-interaction
    echo -e "${GREEN}Usuário administrador criado!${RESET}" | tee -a $LOG_FILE
}

# Função para configurar o Nginx
configurar_nginx() {
    progress_bar 5 "Configurando Nginx"
    cat > /etc/nginx/sites-available/pterodactyl <<EOL
server {
    listen 80;
    server_name $DOMINIO;
    root /var/www/pterodactyl/public;
    index index.php index.html index.htm;
    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }
    location ~ \.php\$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:/var/run/php/php8.3-fpm.sock;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        include fastcgi_params;
    }
    location ~ /\.ht {
        deny all;
    }
}
EOL
    ln -sf /etc/nginx/sites-available/pterodactyl /etc/nginx/sites-enabled/
    rm -f /etc/nginx/sites-enabled/default
    nginx -t || { echo -e "${RED}Erro na configuração do Nginx.${RESET}" | tee -a $LOG_FILE; exit 1; }
    systemctl restart nginx
}

# Função para ajustar permissões
ajustar_permissoes() {
    progress_bar 5 "Ajustando permissões"
    chown -R www-data:www-data /var/www/pterodactyl/*
    chmod -R 755 /var/www/pterodactyl
    chmod -R 775 /var/www/pterodactyl/storage /var/www/pterodactyl/bootstrap/cache
}

# Função para configurar filas
configurar_filas() {
    progress_bar 5 "Configurando filas"
    echo "* * * * * php /var/www/pterodactyl/artisan schedule:run >> /dev/null 2>&1" | crontab -
    cat > /etc/systemd/system/pteroq.service <<EOL
[Unit]
Description=Pterodactyl Queue Worker
After=redis-server.service
[Service]
User=www-data
Group=www-data
Restart=always
ExecStart=/usr/bin/php /var/www/pterodactyl/artisan queue:work --queue=high,standard,low --sleep=3 --tries=3
StartLimitInterval=180
StartLimitBurst=30
RestartSec=5s
[Install]
WantedBy=multi-user.target
EOL
    systemctl enable --now redis-server
    systemctl enable --now pteroq.service
}

# Função para salvar credenciais
salvar_credenciais() {
    progress_bar 3 "Salvando credenciais"
    echo "URL: http://$DOMINIO" > $CRED_FILE
    echo "Usuário: $ADMIN_EMAIL" >> $CRED_FILE
    echo "Senha: $ADMIN_PASS" >> $CRED_FILE
    echo "Banco de Dados: $PANEL_DB" >> $CRED_FILE
    echo "Usuário MySQL: $MYSQL_USER" >> $CRED_FILE
    echo "Senha MySQL: $MYSQL_PASS" >> $CRED_FILE
    chmod 600 $CRED_FILE
    echo -e "${GREEN}Credenciais salvas em $CRED_FILE${RESET}" | tee -a $LOG_FILE
}

# Função para configurar HTTPS com Certbot
configurar_https() {
    if [ ! -d "/var/www/pterodactyl" ]; then
        echo -e "${RED}Nenhuma instalação encontrada. Escolha instalar primeiro.${RESET}" | tee -a $LOG_FILE
        return 1
    fi
    progress_bar 10 "Configurando HTTPS com Certbot"
    certbot --nginx -d $DOMINIO --non-interactive --agree-tos --email $ADMIN_EMAIL || {
        echo -e "${YELLOW}HTTPS não configurado (IP local ou domínio inválido). Continuando com HTTP.${RESET}" | tee -a $LOG_FILE
        return 0
    }
    sed -i "s|APP_URL=.*|APP_URL=https://$DOMINIO|" /var/www/pterodactyl/.env
    echo -e "${GREEN}HTTPS configurado com sucesso!${RESET}" | tee -a $LOG_FILE
}

# Função para configurar firewall
configurar_firewall() {
    progress_bar 5 "Configurando firewall"
    apt -y install ufw
    ufw allow 22/tcp
    ufw allow 80/tcp
    ufw allow 443/tcp
    ufw --force enable
    echo -e "${GREEN}Firewall configurado (portas 22, 80, 443 abertas)!${RESET}" | tee -a $LOG_FILE
}

# Função para configurar backup agendado
configurar_backup_agendado() {
    progress_bar 5 "Configurando backup agendado"
    echo "0 2 * * * /bin/bash -c 'mysqldump -u root $PANEL_DB > /root/pterodactyl_backup_\$(date +\%F).sql && tar -czf /root/pterodactyl_files_\$(date +\%F).tar.gz /var/www/pterodactyl 2>/dev/null'" | crontab -
    echo -e "${GREEN}Backup agendado para todo dia às 2h!${RESET}" | tee -a $LOG_FILE
}

# Função para limpar instalação antiga
limpar_instalacao_antiga() {
    progress_bar 10 "Fazendo backup da instalação antiga"
    mkdir -p $BACKUP_DIR
    if [ -d "/var/www/pterodactyl" ]; then
        cp -r /var/www/pterodactyl $BACKUP_DIR/pterodactyl_files 2>/dev/null
    fi
    mysqldump -u root $PANEL_DB > $BACKUP_DIR/panel_backup.sql 2>/dev/null
    echo -e "${YELLOW}Backup salvo em $BACKUP_DIR${RESET}" | tee -a $LOG_FILE
    progress_bar 10 "Limpando instalação antiga"
    rm -rf /var/www/pterodactyl
    mysql -u root -e "DROP DATABASE IF EXISTS $PANEL_DB;" 2>/dev/null
    mysql -u root -e "DROP USER IF EXISTS '$MYSQL_USER'@'127.0.0.1';" 2>/dev/null
    rm -f /etc/nginx/sites-available/pterodactyl /etc/nginx/sites-enabled/pterodactyl
    crontab -r 2>/dev/null
    systemctl disable pteroq.service 2>/dev/null
    rm -f /etc/systemd/system/pteroq.service
    systemctl daemon-reload
}

# Função para alterar o domínio
alterar_dominio() {
    if [ ! -d "/var/www/pterodactyl" ]; then
        echo -e "${RED}Nenhuma instalação encontrada. Escolha instalar primeiro.${RESET}" | tee -a $LOG_FILE
        return 1
    fi
    echo -e "${YELLOW}Digite o novo domínio (ex.: pterodactyl.seudominio.com, ou pressione Enter para manter $DOMINIO):${RESET}"
    read NOVO_DOMINIO
    if [ -n "$NOVO_DOMINIO" ]; then
        DOMINIO="$NOVO_DOMINIO"
        progress_bar 5 "Atualizando domínio para $DOMINIO"
        sed -i "s|APP_URL=.*|APP_URL=http://$DOMINIO|" /var/www/pterodactyl/.env
        cat > /etc/nginx/sites-available/pterodactyl <<EOL
server {
    listen 80;
    server_name $DOMINIO;
    root /var/www/pterodactyl/public;
    index index.php index.html index.htm;
    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }
    location ~ \.php\$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:/var/run/php/php8.3-fpm.sock;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        include fastcgi_params;
    }
    location ~ /\.ht {
        deny all;
    }
}
EOL
        ln -sf /etc/nginx/sites-available/pterodactyl /etc/nginx/sites-enabled/
        nginx -t || { echo -e "${RED}Erro na configuração do Nginx.${RESET}" | tee -a $LOG_FILE; exit 1; }
        systemctl restart nginx
        salvar_credenciais
    else
        echo -e "${GREEN}Domínio mantido: $DOMINIO${RESET}" | tee -a $LOG_FILE
    fi
}

# Função para instalar tudo
instalar_tudo() {
    verificar_prerequisitos
    preparar_apt
    instalar_dependencias
    configurar_banco
    instalar_pterodactyl
    configurar_ambiente
    criar_usuario_admin
    configurar_nginx
    ajustar_permissoes
    configurar_filas
    configurar_firewall
    configurar_backup_agendado
    configurar_https
    salvar_credenciais
    echo -e "${GREEN}Instalação finalizada com sucesso!${RESET}" | tee -a $LOG_FILE
    echo -e "${GREEN}Acesse o painel em: http://$DOMINIO ${RESET}" | tee -a $LOG_FILE
    echo -e "${YELLOW}Credenciais:${RESET}" | tee -a $LOG_FILE
    cat $CRED_FILE | tee -a $LOG_FILE
    echo -e "${CYAN}🎉 Parabéns! Você agora comanda um servidor ULTRA poderoso! 🚀${RESET}" | tee -a $LOG_FILE
}

# Função para limpar e reinstalar
limpar_e_reinstalar() {
    limpar_instalacao_antiga
    instalar_tudo
}

# Função para exibir menu inicial
exibir_menu_inicial() {
    while true; do
        exibir_logo
        echo -e "${CYAN}┌──────────────────────────────────────────────────┐${RESET}"
        echo -e "${CYAN}│ Bem-vindo ao instalador ULTRA Pterodactyl 20.04! │${RESET}"
        echo -e "${CYAN}└──────────────────────────────────────────────────┘${RESET}"
        echo -e "${YELLOW}O que deseja fazer?${RESET}"
        echo -e "  1) Instalar e configurar o Pterodactyl"
        echo -e "  2) Alterar o domínio (host)"
        echo -e "  3) Apagar instalação antiga e reinstalar"
        echo -e "  4) Sair"
        echo -e "${YELLOW}Escolha uma opção:${RESET} \c"
        read OPCAO
        case $OPCAO in
            1)
                instalar_tudo
                exibir_menu_pos_instalacao
                break
                ;;
            2)
                alterar_dominio
                echo -e "${YELLOW}Pressione Enter para continuar...${RESET}"
                read
                ;;
            3)
                limpar_e_reinstalar
                exibir_menu_pos_instalacao
                break
                ;;
            4)
                echo -e "${GREEN}Saindo...${RESET}" | tee -a $LOG_FILE
                exit 0
                ;;
            *)
                echo -e "${RED}Opção inválida!${RESET}"
                echo -e "${YELLOW}Pressione Enter para continuar...${RESET}"
                read
                ;;
        esac
    done
}

# Função para exibir menu após instalação
exibir_menu_pos_instalacao() {
    while true; do
        exibir_logo
        echo -e "${CYAN}┌─────────────────────────────────────────────┐${RESET}"
        echo -e "${CYAN}│ Configuração concluída! O que deseja fazer? │${RESET}"
        echo -e "${CYAN}└─────────────────────────────────────────────┘${RESET}"
        echo -e "${YELLOW}Escolha uma opção:${RESET}"
        echo -e "  1) Alterar o domínio (host)"
        echo -e "  2) Configurar HTTPS com Certbot (se ainda não configurado)"
        echo -e "  3) Configurar backup agendado (se ainda não configurado)"
        echo -e "  4) Verificar recursos do servidor"
        echo -e "  5) Sair"
        echo -e "${YELLOW}Opção:${RESET} \c"
        read OPCAO
        case $OPCAO in
            1)
                alterar_dominio
                echo -e "${YELLOW}Pressione Enter para continuar...${RESET}"
                read
                ;;
            2)
                configurar_https
                echo -e "${YELLOW}Pressione Enter para continuar...${RESET}"
                read
                ;;
            3)
                configurar_backup_agendado
                echo -e "${YELLOW}Pressione Enter para continuar...${RESET}"
                read
                ;;
            4)
                echo -e "${CYAN}Recursos do servidor:${RESET}" | tee -a $LOG_FILE
                lscpu | grep '^CPU(s):' | tee -a $LOG_FILE
                free -h | grep Mem | awk '{print "Memória: " $2 " total, " $3 " usada"}' | tee -a $LOG_FILE
                df -h / | tail -1 | awk '{print "Disco: " $2 " total, " $3 " usado"}' | tee -a $LOG_FILE
                echo -e "${YELLOW}Pressione Enter para continuar...${RESET}"
                read
                ;;
            5)
                echo -e "${GREEN}Saindo...${RESET}" | tee -a $LOG_FILE
                break
                ;;
            *)
                echo -e "${RED}Opção inválida!${RESET}"
                echo -e "${YELLOW}Pressione Enter para continuar...${RESET}"
                read
                ;;
        esac
    done
}

# Iniciar
exibir_menu_inicial
