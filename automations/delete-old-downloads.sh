#!/bin/bash

DOWNLOADS_DIR=~/Downloads
OLD_DOWNLOADS_DIR=$DOWNLOADS_DIR/.old_downloads
LOG_FILE=$OLD_DOWNLOADS_DIR/logs
DAYS=14

# This script moves files and directories from ~/Downloads to ~/Downloads/.old_downloads
# if they are older than a specified number of days($DAYS), excluding those specified in a .deleteignore file.
# The .deleteignore file works similarly to .gitignore, specifying patterns to ignore.
# If the .deleteignore file does not exist, it will be created.
#
# DISCLAIMER:
# Use this script at your own risk. The author is not responsible for any loss of data
# or other damages that may occur as a result of using this script. Make sure to backup
# your important files before running the script.

# 면책:
# 이 스크립트 사용으로 인해 발생할 수 있는 데이터 손실이나 기타 손해에 대해 작성자는 책임을 지지 않습니다. 
# 스크립트를 실행하기 전에 중요한 파일을 백업하시기 바랍니다.


# Create .deleteignore file if it does not exist
if [ ! -f "$DOWNLOADS_DIR/.deleteignore" ]; then
  touch "$DOWNLOADS_DIR/.deleteignore" > /dev/null 2>&1
fi

# Create the directory to move old files to
mkdir -p "$OLD_DOWNLOADS_DIR" > /dev/null 2>&1

# Read the .deleteignore file
IGNORE_LIST=()
while IFS= read -r line; do
  IGNORE_LIST+=("$line")
done < "$DOWNLOADS_DIR/.deleteignore"

# Function to log moved files with timestamp
log_moved_file() {
  local FILE=$1
  local TIMESTAMP=$(date +"%Y-%m-%d %H:%M:%S")
  echo "$TIMESTAMP - Moved: $FILE" >> "$LOG_FILE"
}

# Function to check if a directory contains recently modified files
contains_recent_files() {
  local DIR=$1
  if find "$DIR" -type f -mtime -$DAYS | grep -q .; then
    return 0
  else
    return 1
  fi
}

# Find files and directories older than the specified number of days
find "$DOWNLOADS_DIR" -mindepth 1 -mtime +$DAYS 2>/dev/null | while read -r FILE; do
  # Check if the file matches any pattern in the .deleteignore file
  IGNORED=false
  for IGNORE in "${IGNORE_LIST[@]}"; do
    if [[ "$FILE" == "$DOWNLOADS_DIR/$IGNORE" || "$FILE" == "$DOWNLOADS_DIR/$IGNORE/"* ]]; then
      IGNORED=true
      break
    fi
  done

  # If not ignored, and if it is a directory, check if it contains recent files
  if ! $IGNORED; then
    if [ -d "$FILE" ] && contains_recent_files "$FILE"; then
      IGNORED=true
    fi
  fi

  # If not ignored, move the file/directory while preserving the directory structure
  if ! $IGNORED; then
    DEST="$OLD_DOWNLOADS_DIR/${FILE#$DOWNLOADS_DIR/}"
    mkdir -p "$(dirname "$DEST")" > /dev/null 2>&1
    mv "$FILE" "$DEST" > /dev/null 2>&1 && log_moved_file "$FILE"
  fi
done