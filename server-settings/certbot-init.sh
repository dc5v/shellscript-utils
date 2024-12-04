#!/bin/bash

echo ; echo -e "\033[37;44mCERTBOT AUTOMATION SETTING\033[0m" ; echo

CERTBOT="certbot"
CLOUDFLARE_API_VALIDATE_URL="https://api.cloudflare.com/client/v4/user/tokens/verify"
CERTBOT_CONF_FILE=/home/certbot/.config
CERTBOT_EXPORT_DIR=/home/certbot/exports
CERTBOT_RENEW_SCRIPT=/usr/bin/certbot-renew.sh
REQUIRED_PACKAGES=("pwgen" "snapd" "libpam-pwquality" "openjdk-11-jdk" "curl")
CLOUDFLARE_API_TOKEN=
DOMAINS=()

REM () {
  echo
  echo -e "\033[1;37m# $@\033[0m"
}

REM_X () {
  echo -e "\033[31mError: $@\033[0m"
  echo
}

READ_DOMAINS() {
  local input_domains
  while true; do
    read -p "Enter domains (separate with ','): " input_domains

    local domains=$(echo "$input_domains" | tr ',' '\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')

    while read -r domain; do
      [ -n "$domain" ] && DOMAINS+=("$domain")
    done <<< "$domains"

    REM "Check domains"
    for domain in "${DOMAINS[@]}"; do
      echo "- $domain"
    done

    echo
    read -p "Is this correct? (y/N): " confirm
    case "$confirm" in
      [yY][eE][sS]|[yY]) 
        break 
        ;;
      *) 
        ;;
    esac
  done
}

VALIDATE_CLOUDFLARE_API_TOKEN() {
  local response
  response=$(curl -s -o /dev/null -w "%{http_code}" -X GET "$CLOUDFLARE_API_VALIDATE_URL" -H "Authorization: Bearer $1" -H "Content-Type: application/json")

  if [ "$response" -eq 200 ]; then
    return 0
  else
    return 1
  fi
}

if [ "$EUID" -ne 0 ]; then
  REM_X "Run as root or sudo run"
  exit 1
fi

# READ DOMAINS
READ_DOMAINS

# READ CLOUDFLARE API TOKEN
REM "Cloudflare API token Configuration - https://dash.cloudflare.com/profile/api-tokens"

while true; do
  read -p "Enter Cloudflare API token: " CLOUDFLARE_API_TOKEN

  if VALIDATE_CLOUDFLARE_API_TOKEN "$CLOUDFLARE_API_TOKEN"; then
    break 
  else
    REM_X "Invalid Cloudflare API token."
  fi
done


# APT
for package in "${REQUIRED_PACKAGES[@]}"; do
  if ! dpkg -l | grep -qw "$package"; then
    REM "Install package: $package"
    apt update && apt install -y "$package"
  fi
done

# SNAP
REM "Install required snap packages"
snap install --classic certbot
snap set certbot trust-plugin-with-root=ok
snap install certbot-dns-cloudflare

# ADD USER
if ! id "$CERTBOT" &>/dev/null; then
  useradd --system --no-create-home --shell /usr/sbin/nologin "$CERTBOT"
fi

# ADD CONFIG FILE
REM "Generate config file"
mkdir -p $CERTBOT_EXPORT_DIR
touch $CERTBOT_CONF_FILE
echo "dns_cloudflare_api_token=$CLOUDFLARE_API_TOKEN" > $CERTBOT_CONF_FILE
chown certbot:certbot $CERTBOT_CONF_FILE
chmod 600 $CERTBOT_CONF_FILE

# REMOVE REGISTERED CERTBOT
REM "Initialize certbot"
for DOMAIN in "${DOMAINS[@]}"; do
  if [ ! -z "$DOMAIN" ]; then
    certbot delete --cert-name "$DOMAIN" --non-interactive > /dev/null 2>&1
  fi
done

# REGISTER CERTBOT DOMAINS
for DOMAIN in "${DOMAINS[@]}"; do
  REM "Request create certificate: $DOMAIN"
  certbot certonly --dns-cloudflare --dns-cloudflare-propagation-seconds 30 --dns-cloudflare-credentials "${CERTBOT_CONF_FILE}"  -d "*.${DOMAIN}" -d "${DOMAIN}" --non-interactive --agree-tos --email "certbot@${DOMAIN}"
done

# ADD RENEW SCRIPT
REM "Generate certbot renew script"
cat > $CERTBOT_RENEW_SCRIPT << EOF
#!/bin/bash
source $CERTBOT_CONF_FILE
certbot renew --quiet --no-self-upgrade
rm -rf $CERTBOT_EXPORT_DIR/*
cp --dereference -R /etc/letsencrypt/live/* $CERTBOT_EXPORT_DIR
chmod 600 -R $CERTBOT_EXPORT_DIR
EOF
chmod +x $CERTBOT_RENEW_SCRIPT

# CRON.D
REM "Add auto-renew schedule"
echo "0 0 * * 0 root $CERTBOT_RENEW_SCRIPT" > /etc/cron.d/certbot

# COPY TO EXPORTS
rm -rf $CERTBOT_EXPORT_DIR/*
cp -R $CERTBOT_EXPORT_DIR
cp --dereference -R /etc/letsencrypt/live/* $CERTBOT_EXPORT_DIR
chmod 600 -R $CERTBOT_EXPORT_DIR
