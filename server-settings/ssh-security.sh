#!/bin/bash

echo ; echo -e "\033[37;44mSSH SECURITY SETTING\033[0m" ; echo

REQUIRED_PACKAGES=("ufw" "fail2ban")
SSH_CONFIG="/etc/ssh/sshd_config"

EXISTING_PORTS=($(grep -E "^[^#]*Port " "$SSH_CONFIG" 2>/dev/null | awk '{print $2}'))
DEFAULT_PORT=${EXISTING_PORTS[0]:-22}
PRIMARY_PORT=$DEFAULT_PORT
BACKUP_PORT=${EXISTING_PORTS[1]}

UFW_STATUS=$(ufw status | grep -o "inactive")
JAIL_LOCAL="/etc/fail2ban/jail.local"

REM () {
  echo
  echo -e "\033[1;37m# $@\033[0m"
}

REM_X () {
  echo -e "\033[31mError: $@\033[0m"
  echo
}

if [ "$EUID" -ne 0 ]; then
  REM_X "Run as root or sudo run"
  exit 1
fi

READ_PORTS () {
  while true; do
    read -p "Enter SSH port ($PRIMARY_PORT): " PRIMARY_PORT
    PRIMARY_PORT=${PRIMARY_PORT:-$DEFAULT_PORT}

    read -p "Enter backup SSH port (optional, current: '$BACKUP_PORT'): " BACKUP_PORT

    if ! [[ "$PRIMARY_PORT" =~ ^[0-9]+$ ]] || [ "$PRIMARY_PORT" -lt 1 ] || [ "$PRIMARY_PORT" -gt 65535 ]; then
      REM_X "Invalid primary port: $PRIMARY_PORT"
      continue
    fi

    if ss -tuln | grep -q ":$PRIMARY_PORT "; then
      if [ "$DEFAULT_PORT" -ne "$PRIMARY_PORT" ]; then
        REM_X "$PRIMARY_PORT port already in use"
        continue
      fi
    fi

    if [ -n "$BACKUP_PORT" ]; then
      if ! [[ "$BACKUP_PORT" =~ ^[0-9]+$ ]] || [ "$BACKUP_PORT" -lt 1 ] || [ "$BACKUP_PORT" -gt 65535 ]; then
        REM_X "Invalid backup port: $BACKUP_PORT"
        continue
      fi

      if ss -tuln | grep -q ":$BACKUP_PORT "; then
        if [ "$DEFAULT_PORT" -ne "$BACKUP_PORT" ]; then
          REM_X "$BACKUP_PORT backup port is already in use"
          continue
        fi
      fi

      if [ "$PRIMARY_PORT" -eq "$BACKUP_PORT" ]; then
        REM_X "$BACKUP_PORT backup port is already in setting"
        continue
      fi
    fi

    break
  done
}

# APT
for package in "${REQUIRED_PACKAGES[@]}"; do
  if ! dpkg -l | grep -qw "$package"; then
    REM "Install package: $package"
    apt update && apt install -y "$package"
  fi
done

# INPUT PORTS
READ_PORTS

# UFW CONFIGURATION
REM "UFW Configuration"
if [ "$UFW_STATUS" == "inactive" ]; then
  ufw enable
fi

ufw allow "$PRIMARY_PORT"/tcp
if [ -n "$BACKUP_PORT" ]; then
  ufw allow "$BACKUP_PORT"/tcp
fi
ufw allow "$DEFAULT_PORT"/tcp
ufw reload

# SSH CONFIGURATION
REM "Update SSH sshd_config"

cp "$SSH_CONFIG" "${SSH_CONFIG}.bak"
sed -i "s/^#Port .*/Port $PRIMARY_PORT/" "$SSH_CONFIG"
sed -i "s/^Port .*/Port $PRIMARY_PORT/" "$SSH_CONFIG"

if [ -n "$BACKUP_PORT" ]; then
  echo "Port $BACKUP_PORT" >> "$SSH_CONFIG"
fi

if [ "$DEFAULT_PORT" -ne "$PRIMARY_PORT" ] && [ "$DEFAULT_PORT" -ne "$BACKUP_PORT" ]; then
  echo "Port $DEFAULT_PORT" >> "$SSH_CONFIG"
fi

REM "Restarting SSH service"
if ! systemctl restart sshd; then
  REM_X "Restore SSH config"

  ufw delete allow "$PRIMARY_PORT"/tcp
  if [ -n "$BACKUP_PORT" ]; then
    ufw delete allow "$BACKUP_PORT"/tcp
  fi

  cp "${SSH_CONFIG}.bak" "$SSH_CONFIG"
  systemctl restart sshd
  exit 1
fi

# FAIL2BAN CONFIGURATION
REM "Fail2Ban Configuration"
if [ ! -f "$JAIL_LOCAL" ]; then
  cp /etc/fail2ban/jail.conf "$JAIL_LOCAL"
fi

if grep -q "^\[sshd\]" "$JAIL_LOCAL"; then
  sed -i "/^\[sshd\]/,/^\[/s/^enabled.*=.*$/enabled = true/" "$JAIL_LOCAL"
  sed -i "/^\[sshd\]/,/^\[/s/^port.*=.*$/port = $PRIMARY_PORT,$BACKUP_PORT/" "$JAIL_LOCAL"
  sed -i "/^\[sshd\]/,/^\[/s/^logpath.*=.*$/logpath = %(sshd_log)s/" "$JAIL_LOCAL"
else
  bash -c "cat <<EOL >> $JAIL_LOCAL

[sshd]
enabled = true
port = $PRIMARY_PORT,$BACKUP_PORT
logpath = %(sshd_log)s
backend = %(sshd_backend)s
maxretry = 5
EOL"
fi

sed -i 's/port\s*=\s*\([^,]*\),\s*$/port = \1/' /etc/fail2ban/jail.local
systemctl restart fail2ban
