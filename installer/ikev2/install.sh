#!/bin/bash -e

source config.sh
export DEBIAN_FRONTEND=noninteractive

function Terminated {
  echo "$1"
  exit 1
}

function InstallPackage {
  apt-get update
  apt-get install -y net-tools

  apt-get -o Acquire::ForceIPv4=true update
  apt-get -o Acquire::ForceIPv4=true install -y software-properties-common
  
  add-apt-repository -y universe
  add-apt-repository -y restricted
  add-apt-repository -y multiverse

  apt-get -o Acquire::ForceIPv4=true install -y moreutils dnsutils
  apt-get -o Acquire::ForceIPv4=true install -y iptables-persistent unattended-upgrades uuid-runtime strongswan libstrongswan-standard-plugins strongswan-libcharon libcharon-extra-plugins libcharon-standard-plugins libcharon-extauth-plugins
  apt-get -o Acquire::ForceIPv4=true --with-new-pkgs upgrade -y

  apt autoremove -y
}

InstallPackage

[[ $(id -u) -eq 0 ]] || Terminated "Please re-run as root via sudo."

iptables -P INPUT   ACCEPT
iptables -P FORWARD ACCEPT
iptables -P OUTPUT  ACCEPT

iptables -F
iptables -t nat -F
iptables -t mangle -F

iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
iptables -A INPUT -i lo -j ACCEPT
iptables -A INPUT -m state --state INVALID -j DROP
iptables -I INPUT -i "${ETH0}" -m state --state NEW -m recent --set
iptables -I INPUT -i "${ETH0}" -m state --state NEW -m recent --update --seconds 300 --hitcount 60 -j DROP
iptables -A INPUT -p tcp --dport "${SSHPORT}" -j ACCEPT

iptables -A INPUT -p udp --dport  500 -j ACCEPT
iptables -A INPUT -p udp --dport 4500 -j ACCEPT
iptables -A FORWARD --match policy --pol ipsec --dir in  --proto esp -s "${VPNIPPOOL}" -j ACCEPT
iptables -A FORWARD --match policy --pol ipsec --dir out --proto esp -d "${VPNIPPOOL}" -j ACCEPT
iptables -t mangle -A FORWARD --match policy --pol ipsec --dir in -s "${VPNIPPOOL}" -o "${ETH0}" -p tcp -m tcp --tcp-flags SYN,RST SYN -m tcpmss --mss 1361:1536 -j TCPMSS --set-mss 1360
iptables -t nat -A POSTROUTING -s "${VPNIPPOOL}" -o "${ETH0}" -m policy --pol ipsec --dir out -j ACCEPT  # exempt IPsec traffic from masquerading
iptables -t nat -A POSTROUTING -s "${VPNIPPOOL}" -o "${ETH0}" -j MASQUERADE

iptables -A INPUT   -j DROP
iptables -A FORWARD -j DROP
iptables -L

netfilter-persistent save

# /etc/ipsec.d/certs/cert.pem
# /etc/ipsec.d/private/privkey.pem
# /etc/ipsec.d/cacerts/chain.pem

grep -Fq 'jawj/IKEv2-setup' /etc/apparmor.d/local/usr.lib.ipsec.charon || echo "
/etc/letsencrypt/archive/${VPNHOST}/* r," >> /etc/apparmor.d/local/usr.lib.ipsec.charon

aa-status --enabled && invoke-rc.d apparmor reload

grep -Fq 'jawj/IKEv2-setup' /etc/sysctl.conf || echo "
net.ipv4.ip_forward = 1
net.ipv4.ip_no_pmtu_disc = 1
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
net.ipv6.conf.${ETH0}.disable_ipv6 = 1
" >> /etc/sysctl.conf

sysctl -p

echo "
config setup
  strictcrlpolicy=yes
  uniqueids=never

conn roadwarrior
  auto=add
  compress=no
  type=tunnel
  keyexchange=ikev2
  fragmentation=yes
  forceencaps=yes

  ike=aes256gcm16-prfsha384-ecp384!
  esp=aes256gcm16-ecp384!

  dpdaction=clear
  dpddelay=900s
  rekey=no
  left=%any
  leftid=@${VPNHOST}
  leftcert=cert.pem
  leftsendcert=always
  leftsubnet=0.0.0.0/0
  right=%any
  rightid=%any
  rightauth=eap-mschapv2
  eap_identity=%any
  rightdns=${VPNDNS}
  rightsourceip=${VPNIPPOOL}
  rightsendcert=never" > /etc/ipsec.conf



ipsec restart

sed -r \
-e 's/^#?LoginGraceTime (120|2m)$/LoginGraceTime 30/' \
-e 's/^#?PermitRootLogin yes$/PermitRootLogin no/' \
-e 's/^#?X11Forwarding yes$/X11Forwarding no/' \
-e 's/^#?UsePAM yes$/UsePAM no/' \
-i.original /etc/ssh/sshd_config

systemctl restart sshd


timedatectl set-timezone "${TZONE}"
/usr/sbin/update-locale LANG=$LANG


sed -r \
-e 's|^//Unattended-Upgrade::MinimalSteps "true";$|Unattended-Upgrade::MinimalSteps "true";|' \
-e 's|^//Unattended-Upgrade::Mail "root";$|Unattended-Upgrade::Mail "root";|' \
-e 's|^//Unattended-Upgrade::Automatic-Reboot "false";$|Unattended-Upgrade::Automatic-Reboot "true";|' \
-e 's|^//Unattended-Upgrade::Remove-Unused-Dependencies "false";|Unattended-Upgrade::Remove-Unused-Dependencies "true";|' \
-e 's|^//Unattended-Upgrade::Automatic-Reboot-Time "02:00";$|Unattended-Upgrade::Automatic-Reboot-Time "03:00";|' \
-i /etc/apt/apt.conf.d/50unattended-upgrades

echo "
APT::Periodic::Update-Package-Lists \"1\";
APT::Periodic::Download-Upgradeable-Packages \"1\";
APT::Periodic::AutocleanInterval \"7\";
APT::Periodic::Unattended-Upgrade \"1\";
" > /etc/apt/apt.conf.d/10periodic

systemctl restart unattended-upgrades 


echo
echo "--- How to connect ---"
echo
echo "Connection instructions have been emailed to you, and can also be found in your home directory, /home/${LOGINUSERNAME}"

# necessary for IKEv2?
# Windows: https://support.microsoft.com/en-us/kb/926179
# HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Services\PolicyAgent += AssumeUDPEncapsulationContextOnSendRule, DWORD = 2

sudo rm /var/log/syslog && sudo ln -s /dev/null /var/log/syslog
sudo rm /var/log/auth.log && sudo ln -s /dev/null /var/log/auth.log