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

mkdir "/home/${USERNAME}/IKEv2-profile"
cd "/home/${USERNAME}/IKEv2-profile"

cat << EOF > ios-ikev2-vpn-profile.mobileconfig
<?xml version='1.0' encoding='UTF-8'?>
<!DOCTYPE plist PUBLIC '-//Apple//DTD PLIST 1.0//EN' 'http://www.apple.com/DTDs/PropertyList-1.0.dtd'>
<plist version='1.0'>
<dict>
  <key>PayloadContent</key>
  <array>
    <dict>
      <key>IKEv2</key>
      <dict>
        <key>AuthenticationMethod</key>
        <string>None</string>
        <key>ChildSecurityAssociationParameters</key>
        <dict>
          <key>EncryptionAlgorithm</key>
          <string>AES-256-GCM</string>
          <key>IntegrityAlgorithm</key>
          <string>SHA2-384</string>
          <key>DiffieHellmanGroup</key>
          <integer>20</integer>
          <key>LifeTimeInMinutes</key>
          <integer>1440</integer>
        </dict>
        <key>DeadPeerDetectionRate</key>
        <string>Medium</string>
        <key>DisableMOBIKE</key>
        <integer>0</integer>
        <key>DisableRedirect</key>
        <integer>0</integer>
        <key>EnableCertificateRevocationCheck</key>
        <integer>0</integer>
        <key>EnablePFS</key>
        <true/>
        <key>ExtendedAuthEnabled</key>
        <true/>
        <key>IKESecurityAssociationParameters</key>
        <dict>
          <key>EncryptionAlgorithm</key>
          <string>AES-256-GCM</string>
          <key>IntegrityAlgorithm</key>
          <string>SHA2-384</string>
          <key>DiffieHellmanGroup</key>
          <integer>20</integer>
          <key>LifeTimeInMinutes</key>
          <integer>1440</integer>
        </dict>
        <key>OnDemandEnabled</key>
        <integer>1</integer>
        <key>OnDemandRules</key>
        <array>
          <dict>
            <key>Action</key>
            <string>Connect</string>
          </dict>
        </array>
        <key>RemoteAddress</key>
        <string>${VPNHOST}</string>
        <key>RemoteIdentifier</key>
        <string>${VPNHOST}</string>
        <key>UseConfigurationAttributeInternalIPSubnet</key>
        <integer>0</integer>
      </dict>
      <key>IPv4</key>
      <dict>
        <key>OverridePrimary</key>
        <integer>1</integer>
      </dict>
      <key>PayloadDescription</key>
      <string>Configures VPN settings</string>
      <key>PayloadDisplayName</key>
      <string>VPN</string>
      <key>PayloadIdentifier</key>
      <string>com.apple.vpn.managed.$(uuidgen)</string>
      <key>PayloadType</key>
      <string>com.apple.vpn.managed</string>
      <key>PayloadUUID</key>
      <string>$(uuidgen)</string>
      <key>PayloadVersion</key>
      <integer>1</integer>
      <key>Proxies</key>
      <dict>
        <key>HTTPEnable</key>
        <integer>0</integer>
        <key>HTTPSEnable</key>
        <integer>0</integer>
      </dict>
      <key>UserDefinedName</key>
      <string>${VPNHOST}</string>
      <key>VPNType</key>
      <string>IKEv2</string>
    </dict>
  </array>
  <key>PayloadDisplayName</key>
  <string>IKEv2 VPN configuration (${VPNHOST})</string>
  <key>PayloadIdentifier</key>
  <string>com.mackerron.vpn.$(uuidgen)</string>
  <key>PayloadRemovalDisallowed</key>
  <false/>
  <key>PayloadType</key>
  <string>Configuration</string>
  <key>PayloadUUID</key>
  <string>$(uuidgen)</string>
  <key>PayloadVersion</key>
  <integer>1</integer>
</dict>
</plist>
EOF

cat << EOF > mac-ikev2-vpn-profile.applescript
set vpnuser to text returned of (display dialog "Please enter your VPN username" default answer "")
set vpnpass to text returned of (display dialog "Please enter your VPN password" default answer "" with hidden answer)
set plist to "<?xml version='1.0' encoding='UTF-8'?>
<!DOCTYPE plist PUBLIC '-//Apple//DTD PLIST 1.0//EN' 'http://www.apple.com/DTDs/PropertyList-1.0.dtd'>
<plist version='1.0'>
<dict>
  <key>PayloadContent</key>
  <array>
    <dict>
      <key>IKEv2</key>
      <dict>
        <key>AuthenticationMethod</key>
        <string>None</string>
        <key>ChildSecurityAssociationParameters</key>
        <dict>
          <key>EncryptionAlgorithm</key>
          <string>AES-256-GCM</string>
          <key>IntegrityAlgorithm</key>
          <string>SHA2-384</string>
          <key>DiffieHellmanGroup</key>
          <integer>20</integer>
          <key>LifeTimeInMinutes</key>
          <integer>1440</integer>
        </dict>
        <key>DeadPeerDetectionRate</key>
        <string>Medium</string>
        <key>DisableMOBIKE</key>
        <integer>0</integer>
        <key>DisableRedirect</key>
        <integer>0</integer>
        <key>EnableCertificateRevocationCheck</key>
        <integer>0</integer>
        <key>EnablePFS</key>
        <true/>
        <key>ExtendedAuthEnabled</key>
        <true/>
        <key>AuthName</key>
        <string>" & vpnuser & "</string>
        <key>AuthPassword</key>
        <string>" & vpnpass & "</string>
        <key>IKESecurityAssociationParameters</key>
        <dict>
          <key>EncryptionAlgorithm</key>
          <string>AES-256-GCM</string>
          <key>IntegrityAlgorithm</key>
          <string>SHA2-384</string>
          <key>DiffieHellmanGroup</key>
          <integer>20</integer>
          <key>LifeTimeInMinutes</key>
          <integer>1440</integer>
        </dict>
        <key>OnDemandEnabled</key>
        <integer>1</integer>
        <key>OnDemandRules</key>
        <array>
          <dict>
            <key>Action</key>
            <string>Connect</string>
          </dict>
        </array>
        <key>RemoteAddress</key>
        <string>${VPNHOST}</string>
        <key>RemoteIdentifier</key>
        <string>${VPNHOST}</string>
        <key>UseConfigurationAttributeInternalIPSubnet</key>
        <integer>0</integer>
      </dict>
      <key>IPv4</key>
      <dict>
        <key>OverridePrimary</key>
        <integer>1</integer>
      </dict>
      <key>PayloadDescription</key>
      <string>Configures VPN settings</string>
      <key>PayloadDisplayName</key>
      <string>VPN</string>
      <key>PayloadIdentifier</key>
      <string>com.apple.vpn.managed.$(uuidgen)</string>
      <key>PayloadType</key>
      <string>com.apple.vpn.managed</string>
      <key>PayloadUUID</key>
      <string>$(uuidgen)</string>
      <key>PayloadVersion</key>
      <integer>1</integer>
      <key>Proxies</key>
      <dict>
        <key>HTTPEnable</key>
        <integer>0</integer>
        <key>HTTPSEnable</key>
        <integer>0</integer>
      </dict>
      <key>UserDefinedName</key>
      <string>${VPNHOST}</string>
      <key>VPNType</key>
      <string>IKEv2</string>
    </dict>
  </array>
  <key>PayloadDisplayName</key>
  <string>IKEv2 VPN configuration (${VPNHOST})</string>
  <key>PayloadIdentifier</key>
  <string>com.mackerron.vpn.$(uuidgen)</string>
  <key>PayloadRemovalDisallowed</key>
  <false/>
  <key>PayloadType</key>
  <string>Configuration</string>
  <key>PayloadUUID</key>
  <string>$(uuidgen)</string>
  <key>PayloadVersion</key>
  <integer>1</integer>
</dict>
</plist>"
set tmpdir to do shell script "mktemp -d"
set tmpfile to tmpdir & "/vpn.mobileconfig"
do shell script "touch " & tmpfile
write plist to tmpfile
do shell script "open /System/Library/PreferencePanes/Profiles.prefPane " & tmpfile
delay 5
do shell script "rm " & tmpfile
EOF

grep -Fq 'jawj/IKEv2-setup' /etc/mime.types
sed -i '/application\/vnd\.strongswan\.profile/d' /etc/mime.types
echo "application/vnd.strongswan.profile  sswan" >> /etc/mime.types

cat << EOF > android-ikev2-vpn-profile.sswan
{
  "uuid": "$(uuidgen)",
  "name": "${VPNHOST}",
  "type": "ikev2-eap",
  "remote": {
    "addr": "${VPNHOST}"
  }
}
EOF

cat << EOF > ubuntu-client-ikev2-profile.sh
#!/bin/bash -e
if [[ \$(id -u) -ne 0 ]]; then echo "Please run as root (e.g. sudo ./path/to/this/script)"; exit 1; fi

read -p "VPN username (same as entered on server): " USERNAME
while true; do
read -s -p "VPN password (same as entered on server): " PASSWORD
echo
done

apt-get install -y strongswan libstrongswan-standard-plugins libcharon-extra-plugins
apt-get install -y libcharon-standard-plugins || true  # 17.04+ only

ln -f -s /etc/ssl/certs/ISRG_Root_X1.pem /etc/ipsec.d/cacerts/

grep -Fq 'jawj/IKEv2-setup' /etc/ipsec.conf || echo "
conn ikev2vpn
        ikelifetime=60m
        keylife=20m
        rekeymargin=3m
        keyingtries=1
        keyexchange=ikev2
        ike=aes256gcm16-prfsha384-ecp384!
        esp=aes256gcm16-ecp384!
        leftsourceip=%config
        leftauth=eap-mschapv2
        eap_identity=\${VPNUSERNAME}
        right=${VPNHOST}
        rightauth=pubkey
        rightid=@${VPNHOST}
        rightsubnet=0.0.0.0/0
        auto=add  # or auto=start to bring up automatically
" >> /etc/ipsec.conf

grep -Fq 'jawj/IKEv2-setup' /etc/ipsec.secrets ||
echo "\${USERNAME} : EAP \"\${PASSWORD}\"" >> /etc/ipsec.secrets

ipsec restart
sleep 3

ipsec up ikev2vpn
ipsec statusall

VPNIP=\$(dig -4 +short ${VPNHOST})
ACTUALIP=\$(dig -4 +short myip.opendns.com @resolver1.opendns.com)
if [[ "\$VPNIP" == "\$ACTUALIP" ]]; then echo "Connection test success (IP: \${VPNIP})"; else echo "Connection test fail (IP: \${ACTUALIP}, VPN IP: \${VPNIP})"; fi
EOF

cat << EOF > vpn-instructions.txt
== iOS ==

A configuration profile is attached as vpn-ios.mobileconfig.

Open this attachment. Then go to Settings > General > VPN & Device Management, and find the profile under 'DOWNLOADED PROFILE'.

You will be asked for your device PIN or password, and then your VPN username and password.

These instructions apply to iOS 15. Earlier (and probably later) versions of iOS will also work, but the exact setup steps may differ.


== macOS ==

In macOS Monterey, your VPN username and password must be embedded in the profile file. However, your password cannot be included in a profile sent by email for security reasons.

So: open vpn-mac.applescript and run it from Script Editor. You'll be prompted for your VPN username and password.

System Preferences will then open. Select the profile listed as 'Downloaded' on the left, and click 'Install...' in the main panel.


== Windows ==

You will need Windows 10 Pro or above. Please run the following commands in PowerShell:

\$Response = Invoke-WebRequest -UseBasicParsing -Uri https://valid-isrgrootx1.letsencrypt.org
# ^ this line fixes a certificate lazy-loading bug: see https://github.com/jawj/IKEv2-setup/issues/126

Add-VpnConnection -Name "${VPNHOST}" \`
  -ServerAddress "${VPNHOST}" \`
  -TunnelType IKEv2 \`
  -EncryptionLevel Maximum \`
  -AuthenticationMethod EAP \`
  -RememberCredential

Set-VpnConnectionIPsecConfiguration -ConnectionName "${VPNHOST}" \`
  -AuthenticationTransformConstants GCMAES256 \`
  -CipherTransformConstants GCMAES256 \`
  -EncryptionMethod GCMAES256 \`
  -IntegrityCheckMethod SHA384 \`
  -DHGroup ECP384 \`
  -PfsGroup ECP384 \`
  -Force

# Run the following command to retain access to the local network (e.g. printers, file servers) while the VPN is connected.
# On a home network, you probably want this. On a public network, you probably don't.

Set-VpnConnection -Name "${VPNHOST}" -SplitTunneling \$True

You will need to enter your chosen VPN username and password in order to connect.


== Android ==

Download the strongSwan app from the Play Store: https://play.google.com/store/apps/details?id=org.strongswan.android

Then open the attached .sswan file, or select it after choosing 'Import VPN profile' from the strongSwan app menu. You will need to enter your chosen VPN username and password in order to connect.

For a persistent connection, go to your device's Settings app and choose Network & Internet > Advanced > VPN > strongSwan VPN Client, tap the gear icon and toggle on 'Always-on VPN' (these options may differ by Android version and provider).


== Ubuntu ==

A bash script to set up strongSwan as a VPN client is attached as vpn-ubuntu-client.sh. You will need to chmod +x and then run the script as root.

EOF

EMAIL=$USER@$VPNHOST mutt -s "VPN configuration" -a vpn-ios.mobileconfig vpn-mac.applescript vpn-android.sswan vpn-ubuntu-client.sh -- "${EMAILADDR}" < vpn-instructions.txt
