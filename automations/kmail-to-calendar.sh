#!/bin/bash

DOMAINS=(
  "namecheap.com" 
  "cloudflare.com"
)

# This script processes new emails received in KMail and adds an event to khal
# if the email is from specified domains. The event will include the email subject
# as the title, and the email link as the location. The category will be set to the domain.
# Notifications are sent if khal is not installed or if no domains are specified.

# 이 스크립트는 KMail에서 수신된 새로운 이메일을 처리하여 지정된 도메인에서 온 경우 khal에 일정을 추가합니다.
# 이메일 제목을 일정제목으로 설정하고, 이메일 링크를 위치로 포함합니다. 카테고리는 도메인으로 설정됩니다.
# khal이 설치되어 있지 않거나 도메인이 지정되지 않은 경우 알림을 보냅니다.


notify() {
  local message="$1"
  notify-send "KMail Script Notification" "$message"
}

if ! command -v khal &> /dev/null; then
  notify-send "khal is not installed. Please install khal to use this script."
  exit 1
fi

if [ ${#DOMAINS[@]} -eq 0 ]; then
  notify "No domains specified in the script. Please add domains to the DOMAINS list."
  exit 1
fi

EMAIL_CONTENT=$(cat -)

EMAIL_SUBJECT=$(echo "$EMAIL_CONTENT" | grep "^Subject:" | sed 's/Subject: //')
EMAIL_FROM=$(echo "$EMAIL_CONTENT" | grep "^From:" | sed 's/From: //')

is_from_domain() {
  local email_from="$1"
  for domain in "${DOMAINS[@]}"; do
    if [[ "$email_from" == *"$domain"* ]]; then
      echo "$domain"
      return 0
    fi
  done
  return 1
}

DOMAIN_FOUND=$(is_from_domain "$EMAIL_FROM")

if [ $? -eq 0 ]; then
  EMAIL_LINK=$(echo "$EMAIL_CONTENT" | grep "^Message-ID:" | sed 's/Message-ID: //; s/<//; s/>//' | awk '{print "kmail://localhost/"$1}')

  START_TIME=$(date +'%Y-%m-%dT%H:%M')
  END_TIME=$(date +'%Y-%m-%dT%H:%M' -d '+1 hour')

  khal new "$START_TIME" "$END_TIME" "$EMAIL_SUBJECT" --location "$EMAIL_LINK" --calendar default --category "$DOMAIN_FOUND"
fi
