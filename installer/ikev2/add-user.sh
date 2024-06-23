#!/bin/bash

source config.sh

read -r -p "Username: " USERNAME

CERTLOGIN="n"
if [[ -s /root/.ssh/authorized_keys ]]; then
  while true; do
    read -r -p "Copy /root/.ssh/authorized_keys to new user and disable SSH password log-in [Y/n]? " CERTLOGIN
    [[ ${CERTLOGIN,,} =~ ^(y(es)?)?$ ]] && CERTLOGIN=y
    [[ ${CERTLOGIN,,} =~ ^no?$ ]] && CERTLOGIN=n
    [[ $CERTLOGIN =~ ^(y|n)$ ]] && break
  done
fi

while true; do
  [[ ${CERTLOGIN} = "y" ]] && read -r -s -p "Password:  " PASSWORD
  [[ ${CERTLOGIN} != "y" ]] && read -r -s -p "SSH log-in password: " PASSWORD
  echo
  read -r -s -p "Retype password: " PASSWORD2
  echo

  [[ "${PASSWORD}" = "${PASSWORD2}" ]] && break
  echo "Passwords didn't match!"
  echo
done

id -u "${USERNAME}" &>/dev/null || adduser --disabled-password --gecos "" "${USERNAME}"
echo "${USERNAME}:${PASSWORD}" | chpasswd
adduser "${USERNAME}" sudo

if [[ $CERTLOGIN = "y" ]]; then
  mkdir -p "/home/${LOGINUSERNAME}/.ssh"
  chown "${LOGINUSERNAME}" "/home/${LOGINUSERNAME}/.ssh"
  chmod 700 "/home/${LOGINUSERNAME}/.ssh"

  cp "/root/.ssh/authorized_keys" "/home/${LOGINUSERNAME}/.ssh/authorized_keys"
  chown "${LOGINUSERNAME}" "/home/${LOGINUSERNAME}/.ssh/authorized_keys"
  chmod 600 "/home/${LOGINUSERNAME}/.ssh/authorized_keys"

  sed -r \
  -e "s/^#?PasswordAuthentication yes$/PasswordAuthentication no/" \
  -i.allows_pwd /etc/ssh/sshd_config
fi
