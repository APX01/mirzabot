#!/bin/bash

# Global Configuration Path
GLOBAL_CONFIG="/root/mirzabot_global.conf"
INSTALL_LOG="/var/log/mirzabot_install.log"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Check Root
if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}[ERROR] Please run this script as root.${NC}"
   exit 1
fi

# ------------------------------------------------------------------
# Helper Functions
# ------------------------------------------------------------------

log() {
    echo -e "$1"
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" >> "$INSTALL_LOG"
}

check_dependencies() {
    log "${YELLOW}Checking dependencies...${NC}"
    
    # Update packages
    apt-get update -y
    
    # Install required packages
    PACKAGES=(
        software-properties-common
        git
        unzip
        curl
        wget
        jq
        apache2
        mysql-server
        php8.2
        php8.2-fpm
        php8.2-mysql
        php8.2-mbstring
        php8.2-zip
        php8.2-gd
        php8.2-json
        php8.2-curl
        php8.2-soap
        php8.2-ssh2
        libssh2-1-dev
        libssh2-1
        certbot
        python3-certbot-apache
        python3-certbot-dns-cloudflare
        phpmyadmin
    )

    # Add PHP PPA if needed
    if ! command -v php8.2 &> /dev/null; then
        add-apt-repository -y ppa:ondrej/php
        apt-get update -y
    fi

    # Pre-configure phpMyAdmin
    echo 'phpmyadmin phpmyadmin/dbconfig-install boolean true' | debconf-set-selections
    echo 'phpmyadmin phpmyadmin/app-password-confirm password mirzahipass' | debconf-set-selections
    echo 'phpmyadmin phpmyadmin/mysql/admin-pass password mirzahipass' | debconf-set-selections
    echo 'phpmyadmin phpmyadmin/mysql/app-pass password mirzahipass' | debconf-set-selections
    echo 'phpmyadmin phpmyadmin/reconfigure-webserver multiselect apache2' | debconf-set-selections

    for pkg in "${PACKAGES[@]}"; do
        if ! dpkg -s "$pkg" >/dev/null 2>&1; then
            log "${CYAN}Installing $pkg...${NC}"
            DEBIAN_FRONTEND=noninteractive apt-get install -y "$pkg" >> "$INSTALL_LOG" 2>&1
        fi
    done

    # Ensure phpMyAdmin is enabled in Apache
    if [ -f /etc/phpmyadmin/apache.conf ]; then
        ln -sf /etc/phpmyadmin/apache.conf /etc/apache2/conf-available/phpmyadmin.conf
        a2enconf phpmyadmin >> "$INSTALL_LOG" 2>&1
    fi

    # Enable Apache modules
    a2enmod ssl rewrite headers proxy proxy_http >> "$INSTALL_LOG" 2>&1
    systemctl restart apache2
    
    log "${GREEN}Dependencies installed.${NC}"
}

load_global_config() {
    if [ -f "$GLOBAL_CONFIG" ]; then
        source "$GLOBAL_CONFIG"
    else
        log "${YELLOW}Global configuration not found.${NC}"
        setup_global_config
    fi
}

setup_global_config() {
    log "${CYAN}--- Global Configuration Setup ---${NC}"
    
    # 1. Main Domain
    read -p "Enter your Main Domain (e.g., example.com): " MAIN_DOMAIN
    while [[ ! "$MAIN_DOMAIN" =~ ^[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; do
        echo -e "${RED}Invalid domain format.${NC}"
        read -p "Enter your Main Domain (e.g., example.com): " MAIN_DOMAIN
    done

    # 2. Cloudflare Config for Wildcard SSL
    echo -e "${YELLOW}To support multiple subdomains with one certificate, we use Cloudflare DNS API.${NC}"
    read -p "Enter your Cloudflare Email: " CF_EMAIL
    read -p "Enter your Cloudflare Global API Key: " CF_API_KEY
    
    # 3. MySQL Root Password
    echo -e "${YELLOW}Enter MySQL Root Password (if not set, leave blank to attempt default login):${NC}"
    read -s MYSQL_ROOT_PASS
    echo ""

    # Save to config file
    cat <<EOF > "$GLOBAL_CONFIG"
MAIN_DOMAIN="$MAIN_DOMAIN"
CF_EMAIL="$CF_EMAIL"
CF_API_KEY="$CF_API_KEY"
MYSQL_ROOT_PASS="$MYSQL_ROOT_PASS"
EOF
    chmod 600 "$GLOBAL_CONFIG"
    
    source "$GLOBAL_CONFIG"
    
    # Setup Wildcard SSL immediately
    setup_wildcard_ssl
}

setup_wildcard_ssl() {
    log "${CYAN}Setting up Wildcard SSL for *.$MAIN_DOMAIN and $MAIN_DOMAIN...${NC}"
    
    # Create Cloudflare credentials file for Certbot
    mkdir -p /root/.secrets
    cat <<EOF > /root/.secrets/cloudflare.ini
dns_cloudflare_email = $CF_EMAIL
dns_cloudflare_api_key = $CF_API_KEY
EOF
    chmod 600 /root/.secrets/cloudflare.ini

    # Run Certbot
    certbot certonly \
      --dns-cloudflare \
      --dns-cloudflare-credentials /root/.secrets/cloudflare.ini \
      -d "*.$MAIN_DOMAIN" \
      -d "$MAIN_DOMAIN" \
      --agree-tos \
      --non-interactive \
      --email "$CF_EMAIL"

    if [ $? -eq 0 ]; then
        log "${GREEN}Wildcard SSL Certificate obtained successfully!${NC}"
    else
        log "${RED}Failed to obtain SSL Certificate. Please check your Cloudflare credentials and domain.${NC}"
        # Ask to retry or exit
        read -p "Do you want to retry entering credentials? (y/n): " RETRY
        if [[ "$RETRY" == "y" ]]; then
            setup_global_config
        else
            exit 1
        fi
    fi
}

get_db_connection() {
    if [ -z "$MYSQL_ROOT_PASS" ]; then
        MYSQL_CMD="mysql -u root"
    else
        MYSQL_CMD="mysql -u root -p$MYSQL_ROOT_PASS"
    fi
}

# ------------------------------------------------------------------
# Main Features
# ------------------------------------------------------------------

install_new_bot() {
    load_global_config
    get_db_connection

    log "${CYAN}--- Install New Bot Instance ---${NC}"
    
    # 1. Bot Name (Subdomain Prefix)
    read -p "Enter Bot Name (used for subdomain and folder, e.g., 'bot1'): " BOT_NAME
    while [[ ! "$BOT_NAME" =~ ^[a-zA-Z0-9_]+$ ]]; do
        echo -e "${RED}Invalid name. Use only alphanumeric characters and underscores.${NC}"
        read -p "Enter Bot Name: " BOT_NAME
    done

    FULL_DOMAIN="$BOT_NAME.$MAIN_DOMAIN"
    BOT_DIR="/var/www/html/mirzabot_$BOT_NAME"
    DB_NAME="mirzabot_$BOT_NAME"
    DB_USER="user_$BOT_NAME"
    DB_PASS=$(openssl rand -base64 12 | tr -dc 'a-zA-Z0-9')

    # Check if exists
    if [ -d "$BOT_DIR" ]; then
        echo -e "${RED}Bot directory already exists. Please choose another name or remove the old bot first.${NC}"
        return
    fi

    # 2. Telegram Info
    read -p "Enter Telegram Bot Token: " BOT_TOKEN
    read -p "Enter Admin Numeric ID: " ADMIN_ID
    read -p "Enter Bot Username (without @): " BOT_USERNAME

    # 3. Create Database
    log "${YELLOW}Creating Database '$DB_NAME'...${NC}"
    $MYSQL_CMD -e "CREATE DATABASE IF NOT EXISTS $DB_NAME;"
    $MYSQL_CMD -e "CREATE USER IF NOT EXISTS '$DB_USER'@'localhost' IDENTIFIED BY '$DB_PASS';"
    $MYSQL_CMD -e "GRANT ALL PRIVILEGES ON $DB_NAME.* TO '$DB_USER'@'localhost';"
    $MYSQL_CMD -e "FLUSH PRIVILEGES;"

    # 4. Download Source
    log "${YELLOW}Downloading Bot Source...${NC}"
    mkdir -p "$BOT_DIR"
    # Download from main branch
    # Clean up previous extraction attempts AGGRESSIVELY
    rm -rf /tmp/mirza_pro-* /tmp/mirzabot-* /tmp/bot_source.zip /tmp/mirzabot-main

    wget -O /tmp/bot_source.zip "https://github.com/APX01/mirzabot/archive/refs/heads/main.zip"
    
    # Unzip with overwrite (-o) explicitly
    unzip -o /tmp/bot_source.zip -d /tmp/
    
    # Detect extracted folder name dynamically (Debug mode)
    echo "Listing files in /tmp/:"
    ls -la /tmp/
    
    # Search for both potential directory names
    EXTRACTED_DIR=$(find /tmp/ -maxdepth 1 -type d \( -name "mirza_pro-*" -o -name "mirzabot-*" \) | head -n 1)
    
    # Fallback: if find fails, try to find ANY directory created recently
    if [ -z "$EXTRACTED_DIR" ]; then
        echo "Trying fallback detection..."
        EXTRACTED_DIR=$(find /tmp/ -maxdepth 1 -type d ! -name "tmp" ! -name "." ! -name ".." -mmin -1 | head -n 1)
    fi
    
    echo "Detected Directory: '$EXTRACTED_DIR'"
    
    if [ -d "$EXTRACTED_DIR" ]; then
        mv "$EXTRACTED_DIR"/* "$BOT_DIR/"
        rm -rf "$EXTRACTED_DIR"
    else
        log "${RED}Error: Could not find extracted directory.${NC}"
        exit 1
    fi
    
    rm -f /tmp/bot_source.zip
    
    chown -R www-data:www-data "$BOT_DIR"
    chmod -R 755 "$BOT_DIR"

    # 5. Generate Config
    log "${YELLOW}Generating Config...${NC}"
    CONFIG_FILE="$BOT_DIR/config.php"
    
    cat <<EOF > "$CONFIG_FILE"
<?php
// Generated by MirzaBot Manager
\$request_exec_timeout = null;
\$dbhost = 'localhost';
\$dbname = '$DB_NAME';
\$usernamedb = '$DB_USER';
\$passworddb = '$DB_PASS';
\$connect = mysqli_connect(\$dbhost, \$usernamedb, \$passworddb, \$dbname);
if (\$connect->connect_error) { die("error" . \$connect->connect_error); }
mysqli_set_charset(\$connect, "utf8mb4");
\$options = [ PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION, PDO::ATTR_DEFAULT_FETCH_MODE => PDO::FETCH_ASSOC, PDO::ATTR_EMULATE_PREPARES => false, ];
\$dsn = "mysql:host=\$dbhost;dbname=\$dbname;charset=utf8mb4";
try { \$pdo = new PDO(\$dsn, \$usernamedb, \$passworddb, \$options); } catch (\PDOException \$e) { error_log("Database connection failed: " . \$e->getMessage()); }
\$APIKEY = '$BOT_TOKEN';
\$adminnumber = '$ADMIN_ID';
\$domainhosts = '$FULL_DOMAIN';
\$usernamebot = '$BOT_USERNAME';
?>
EOF

    # 6. Apache VHost
    log "${YELLOW}Creating Apache VHost...${NC}"
    VHOST_FILE="/etc/apache2/sites-available/$FULL_DOMAIN.conf"
    
    # Check SSL paths
    SSL_CERT="/etc/letsencrypt/live/$MAIN_DOMAIN/fullchain.pem"
    SSL_KEY="/etc/letsencrypt/live/$MAIN_DOMAIN/privkey.pem"

    if [ ! -f "$SSL_CERT" ]; then
        log "${RED}SSL Certificate not found at $SSL_CERT. Trying to regenerate...${NC}"
        setup_wildcard_ssl
    fi

    cat <<EOF > "$VHOST_FILE"
<VirtualHost *:80>
    ServerName $FULL_DOMAIN
    DocumentRoot $BOT_DIR
    <Directory $BOT_DIR>
        Options Indexes FollowSymLinks
        AllowOverride All
        Require all granted
    </Directory>
    
    # Include phpMyAdmin configuration
    IncludeOptional /etc/apache2/conf-available/phpmyadmin.conf
    
    ErrorLog \${APACHE_LOG_DIR}/${FULL_DOMAIN}-error.log
    CustomLog \${APACHE_LOG_DIR}/${FULL_DOMAIN}-access.log combined
    RewriteEngine on
    RewriteCond %{SERVER_NAME} =$FULL_DOMAIN
    RewriteRule ^ https://%{SERVER_NAME}%{REQUEST_URI} [END,NE,R=permanent]
</VirtualHost>

<VirtualHost *:443>
    ServerName $FULL_DOMAIN
    DocumentRoot $BOT_DIR
    
    SSLEngine on
    SSLCertificateFile $SSL_CERT
    SSLCertificateKeyFile $SSL_KEY
    
    <Directory $BOT_DIR>
        Options Indexes FollowSymLinks
        AllowOverride All
        Require all granted
    </Directory>
    
    # Include phpMyAdmin configuration
    IncludeOptional /etc/apache2/conf-available/phpmyadmin.conf
    
    ErrorLog \${APACHE_LOG_DIR}/${FULL_DOMAIN}-error.log
    CustomLog \${APACHE_LOG_DIR}/${FULL_DOMAIN}-access.log combined
</VirtualHost>
EOF

    a2ensite "$FULL_DOMAIN.conf"
    systemctl reload apache2

    # 7. Set Webhook
    log "${YELLOW}Setting Webhook...${NC}"
    SECRET_TOKEN=$(openssl rand -base64 10 | tr -dc 'a-zA-Z0-9')
    WEBHOOK_URL="https://$FULL_DOMAIN/index.php"
    
    RES=$(curl -s -F "url=$WEBHOOK_URL" -F "secret_token=$SECRET_TOKEN" "https://api.telegram.org/bot$BOT_TOKEN/setWebhook")
    
    if [[ $RES == *"true"* ]]; then
        log "${GREEN}Webhook set successfully!${NC}"
        
        # Trigger Database Creation via CLI PHP for reliability
        log "${YELLOW}Initializing Database Tables (via CLI)...${NC}"
        php "$BOT_DIR/table.php" > /dev/null 2>&1
        
        # Fallback via Curl just in case
        curl -s -k "https://$FULL_DOMAIN/table.php" > /dev/null
        
        # Verify Database Tables
        TABLE_COUNT=$($MYSQL_CMD -D "$DB_NAME" -e "SHOW TABLES;" | grep -v "Tables_in_" | wc -l)
        if [ "$TABLE_COUNT" -gt 0 ]; then
             log "${GREEN}Database tables initialized successfully ($TABLE_COUNT tables found).${NC}"
        else
             log "${RED}Warning: No tables found in database. Trying table.php again...${NC}"
             curl -s -k "https://$FULL_DOMAIN/table.php" > /dev/null
        fi

        # Send Test Message
        curl -s -X POST "https://api.telegram.org/bot$BOT_TOKEN/sendMessage" -d chat_id="$ADMIN_ID" -d text="✅ MirzaBot '$BOT_NAME' Installed Successfully! URL: $WEBHOOK_URL" > /dev/null
    else
        log "${RED}Failed to set webhook: $RES${NC}"
    fi

    log "${GREEN}Installation Complete!${NC}"
    echo ""
    echo -e "${CYAN}====================================================${NC}"
    echo -e "${YELLOW}Bot Name:${NC} $BOT_NAME"
    echo -e "${YELLOW}Bot URL:${NC} https://$FULL_DOMAIN"
    echo -e "${CYAN}----------------------------------------------------${NC}"
    echo -e "${YELLOW}Admin Panel:${NC} https://$FULL_DOMAIN/admin.php"
    echo -e "${CYAN}----------------------------------------------------${NC}"
    echo -e "${YELLOW}phpMyAdmin:${NC} https://$FULL_DOMAIN/phpmyadmin"
    echo -e "${YELLOW}DB Name:${NC} $DB_NAME"
    echo -e "${YELLOW}DB User:${NC} $DB_USER"
    echo -e "${YELLOW}DB Pass:${NC} $DB_PASS"
    echo -e "${CYAN}====================================================${NC}"
    echo ""
    read -p "Press Enter to return to menu..."
}

list_bots() {
    log "${CYAN}--- Installed Bots ---${NC}"
    echo "ID | Bot Name | Domain"
    echo "-----------------------------------"
    
    # Scan /var/www/html for mirzabot_* directories
    COUNT=1
    for dir in /var/www/html/mirzabot_*; do
        if [ -d "$dir" ]; then
            NAME=$(basename "$dir" | sed 's/mirzabot_//')
            # Extract domain from config if possible
            if [ -f "$dir/config.php" ]; then
                DOMAIN=$(grep '$domainhosts' "$dir/config.php" | cut -d"'" -f2)
            else
                DOMAIN="Unknown"
            fi
            echo "$COUNT) $NAME - $DOMAIN"
            ((COUNT++))
        fi
    done
    
    if [ $COUNT -eq 1 ]; then
        echo "No bots found."
    fi
    echo ""
    read -p "Press Enter to return to menu..."
}

remove_bot() {
    load_global_config
    get_db_connection
    
    log "${CYAN}--- Remove Bot ---${NC}"
    
    # List bots to select
    OPTIONS=()
    i=1
    for dir in /var/www/html/mirzabot_*; do
        if [ -d "$dir" ]; then
            NAME=$(basename "$dir" | sed 's/mirzabot_//')
            echo "$i) $NAME"
            OPTIONS+=("$NAME")
            ((i++))
        fi
    done

    if [ ${#OPTIONS[@]} -eq 0 ]; then
        echo "No bots found to remove."
        return
    fi

    read -p "Select bot number to remove: " CHOICE
    INDEX=$((CHOICE-1))

    if [ -z "${OPTIONS[$INDEX]}" ]; then
        echo -e "${RED}Invalid selection.${NC}"
        return
    fi

    BOT_NAME="${OPTIONS[$INDEX]}"
    
    echo -e "${RED}WARNING: This will permanently delete Bot '$BOT_NAME', its Database, and Files.${NC}"
    read -p "Are you sure? (type 'yes' to confirm): " CONFIRM
    
    if [[ "$CONFIRM" == "yes" ]]; then
        BOT_DIR="/var/www/html/mirzabot_$BOT_NAME"
        DB_NAME="mirzabot_$BOT_NAME"
        DB_USER="user_$BOT_NAME"
        FULL_DOMAIN="$BOT_NAME.$MAIN_DOMAIN"
        VHOST_FILE="/etc/apache2/sites-available/$FULL_DOMAIN.conf"

        log "${YELLOW}Deleting Database...${NC}"
        $MYSQL_CMD -e "DROP DATABASE IF EXISTS $DB_NAME;"
        $MYSQL_CMD -e "DROP USER IF EXISTS '$DB_USER'@'localhost';"
        $MYSQL_CMD -e "FLUSH PRIVILEGES;"

        log "${YELLOW}Deleting Files...${NC}"
        rm -rf "$BOT_DIR"

        log "${YELLOW}Removing Apache VHost...${NC}"
        a2dissite "$FULL_DOMAIN.conf" 2>/dev/null
        rm -f "$VHOST_FILE"
        systemctl reload apache2

        log "${GREEN}Bot '$BOT_NAME' removed successfully.${NC}"
    else
        echo "Cancelled."
    fi
    read -p "Press Enter to return to menu..."
}

update_bot_source() {
    log "${CYAN}--- Update Bot Source ---${NC}"
    
    OPTIONS=()
    i=1
    for dir in /var/www/html/mirzabot_*; do
        if [ -d "$dir" ]; then
            NAME=$(basename "$dir" | sed 's/mirzabot_//')
            echo "$i) $NAME"
            OPTIONS+=("$NAME")
            ((i++))
        fi
    done

    if [ ${#OPTIONS[@]} -eq 0 ]; then
        echo "No bots found."
        return
    fi

    read -p "Select bot number to update (or 0 for ALL): " CHOICE
    
    update_single() {
        NAME=$1
        DIR="/var/www/html/mirzabot_$NAME"
        log "${YELLOW}Updating $NAME...${NC}"
        
        # Backup Config
        cp "$DIR/config.php" "/tmp/config_$NAME.php"
        
        # Download and Extract
        wget -O /tmp/update_source.zip "https://github.com/APX01/mirzabot/archive/refs/heads/main.zip"
        unzip -q /tmp/update_source.zip -d /tmp/
        
        # Overwrite files
        cp -r /tmp/mirza_pro-main/* "$DIR/"
        
        # Restore Config
        mv "/tmp/config_$NAME.php" "$DIR/config.php"
        
        # Cleanup
        rm -rf /tmp/update_source.zip /tmp/mirza_pro-main
        
        # Fix Permissions
        chown -R www-data:www-data "$DIR"
        chmod -R 755 "$DIR"
        
        log "${GREEN}$NAME updated.${NC}"
    }

    if [ "$CHOICE" -eq 0 ]; then
        for NAME in "${OPTIONS[@]}"; do
            update_single "$NAME"
        done
    else
        INDEX=$((CHOICE-1))
        if [ -z "${OPTIONS[$INDEX]}" ]; then
            echo -e "${RED}Invalid selection.${NC}"
            return
        fi
        update_single "${OPTIONS[$INDEX]}"
    fi
    read -p "Press Enter to return to menu..."
}

# ------------------------------------------------------------------
# Main Menu
# ------------------------------------------------------------------

show_menu() {
    clear
    echo -e "${BLUE}=========================================${NC}"
    echo -e "${BLUE}    MirzaBot Manager (Multi-Bot) v1.0    ${NC}"
    echo -e "${BLUE}=========================================${NC}"
    echo -e "1) Install New Bot Instance"
    echo -e "2) List Installed Bots"
    echo -e "3) Remove Bot Instance"
    echo -e "4) Update Bot Source Code"
    echo -e "5) Configure Global Settings (SSL/Domain)"
    echo -e "6) Exit"
    echo -e "-----------------------------------------"
    read -p "Select option [1-6]: " OPTION

    case $OPTION in
        1) install_new_bot ;;
        2) list_bots ;;
        3) remove_bot ;;
        4) update_bot_source ;;
        5) setup_global_config ;;
        6) exit 0 ;;
        *) echo "Invalid option." ;;
    esac
}

# Initial Checks
check_dependencies

# Loop
while true; do
    show_menu
done
