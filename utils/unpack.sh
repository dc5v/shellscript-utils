#!/usr/bin/env bash
set -euo pipefail

# -------------------------------------------------------------------------------
_L='
\033[33m ▄ ▄▀▀▀▄ \033[37m ▄ ▄ ▄▄▄ ▄▄▄ ▄▄▄ ▄▄▄ ▄ ▄    ▄▄ ▄ ▄\033[0m
\033[33m █ ▀▄▀ █ \033[37m █ █ █ █ █▄█ █▄█ █   █▀▄   ▀▀▄ █▀█\033[0m
\033[33m  ▀▄▄▄▀  \033[37m ▀▀▀ ▀ ▀ ▀   ▀ ▀ ▀▀▀ ▀ ▀ ▀ ▀▀  ▀ ▀\033[0m
                         Extract archives into directories.'
                        _A='Author: kinomoto <dev@dc5v.com>'
# -------------------------------------------------------------------------------
_U='
Usage: ./unpack.sh [OPTIONS] <filename|directory>
Options:
  -p, --purge           Delete the original archive files (only if successful).
  -o, --overwrite       Overwrite directory name (disable sequence rule).
  -a, --all-extensions  Detect archive types using magic numbers.'
# -------------------------------------------------------------------------------

declare -a _FLIST=()
declare -a _FAILED_FILES=()
declare -i _TOTAL_FILES=0
declare -i _SUCCESS_COUNT=0
declare -i _TOTAL_SIZE=0
declare -a _TEMP_DIRS=()

declare -A _EXTRACTORS=([7z]=7z [br]=brotli [bz2]=bzip2 [gz]=gzip [jar]=unzip [lz]=lzip [lz4]=lz4 [lzma]=lzma [rar]=unrar [tar.bz2]=tar [tar.gz]=tar [tar.xz]=tar [tar.zst]=tar [tar]=tar [tbz2]=tar [tgz]=tar [txz]=tar [tzst]=tar [xz]=xz [Z]=uncompress [zip]=unzip [zst]=zstd )
declare -A _MAGIC_EXTRACTORS=([7z]=7z [ace]=unace [ar]=ar [arj]=arj [brotli]=brotli [bzip2]=bzip2 [cab]=cabextract [compress]=uncompress [cpio-bin]=cpio [cpio-crc]=cpio [cpio-newc]=cpio [cpio-odc]=cpio [deb]=ar [dmg]=7z [gzip]=gzip [iso]=7z [lha]=lha [lz4]=lz4 [lzip]=lzip [pack]=uncompress [rar]=unrar [rar5]=unrar [rpm]=rpm2cpio [sit]=unsit [tar]=tar [xz]=xz [zip-empty]=unzip [zip-spanned]=unzip [zip]=unzip [zstd]=zstd)

# Arguments
declare -g _ARGS_PURGE=0
declare -g _ARGS_OVERWRITE=0
declare -g _ARGS_ALL_EXT=0

# Magic code
readonly _MAGIC_READ_SIZE=16
readonly _TAR_BLOCK_SIZE=512

# Exit code
readonly _EXITCODE_DEPS_MISSING=1
readonly _EXITCODE_INVALID_ARGS=2
readonly _EXITCODE_FREAD_FAILED=3
readonly _EXITCODE_UNSUPPORTED_FORMAT=4
  
echo; echo; echo -e "$_L"; echo; 

fn_timestamp() { date '+%Y-%m-%d %H:%M:%S' }
fn_error() { echo -e "[$( fn_timestamp )]\033[0;31m ERROR\033[0m: $@" >&2; echo >&2; [[ $# -eq 2 ]] && exit "$2"; }
fn_warning() { echo -e "[$( fn_timestamp )]\033[0;33m WARNING\033[0m: $@" >&2; echo >&2; [[ $# -eq 2 ]] && exit "$2"; }
fn_info() { echo -e "[$( fn_timestamp )] $@"; }

fn_register_tmp(){ _TEMP_DIRS+=("$1"); }
fn_cleanup(){ local d; for d in "${_TEMP_DIRS[@]:-}"; do [[ -n "${d:-}" && -d "$d" ]] && rm -rf -- "$d" 2>/dev/null || true; done }
fn_filesize() { [[ "$OSTYPE" == "darwin"* ]] && stat -f%z -- "$1" 2>/dev/null || stat -c%s -- "$1" 2>/dev/null || echo 0;}

trap 'echo; echo -e "\033[0;36m[SIGINT]\033[0m"; fn_cleanup; exit 130' INT TERM
trap 'fn_cleanup' EXIT


fn_read_bytes() {
  local _file="$1" _count="$2"; local -n _array_ref=$3
  local _fd _i=0 _char _val
  _array_ref=()
  
  exec {_fd}<"$_file" 2>/dev/null || return $_EXITCODE_FREAD_FAILED

  while (( _i < _count )); do
    if ! read -r -N 1 -u "$_fd" _char; then
      break
    fi
    
    if [[ -z "$_char" ]]; then
      _val=0
    else
      printf -v _val "%d" "'$_char"
    fi
    
    _array_ref[$_i]=$_val
    ((_i++))
  done

  exec {_fd}>&-
}

fn_check_deb() {
  local _file="$1" _name
  
  _name=$(dd if="$_file" bs=1 skip=8 count=16 2>/dev/null | tr -d '\0')
  _name="${_name%% *}"
  
  [[ "$_name" == debian-binary* ]]
}

fn_check_cpio() {
  local _len="$2"; local -n _h=$3
  (( _len < 6 )) && return 1
  
  if (( _h[0]==48 && _h[1]==55 && _h[2]==48 && _h[3]==55 && _h[4]==48 )); then
    case ${_h[5]} in 
      49) echo cpio-newc; return 0;; 
      50) echo cpio-crc; return 0;; 
      55) echo cpio-odc; return 0;; 
    esac
  fi
  
  (( _h[0]==199 && _h[1]==113 )) && { echo cpio-bin; return 0; }

  return 1
}

fn_check_iso() { [[ "$(dd if="$1" bs=1 skip=32769 count=5 2>/dev/null)" == "CD001" ]]; }

fn_check_tar() {
  local _file="$1"; local -a _blk=()

  fn_read_bytes "$_file" "$_TAR_BLOCK_SIZE" _blk || return 1

  (( ${#_blk[@]} < 512 )) && return 1
  
  local _nonzero=0 _i
  for ((_i=0; _i<512; _i++)); do (( _blk[_i]!=0 )) && { _nonzero=1; break; }; done
  (( _nonzero==0 )) && return 1
  
  local _sum_u=0 _sum_s=0 _b
  for ((_i=0; _i<512; _i++)); do _b=$(( (_i>=148 && _i<=155) ? 32 : _blk[_i] )); (( _sum_u+=_b, _sum_s+= (_b>=128)?(_b-256):_b )); done
  
  local _oct=0 _d
  for ((_i=148; _i<=154; _i++)); do _d=${_blk[_i]}; if (( _d>=48 && _d<=55 )); then (( _oct = (_oct<<3) + (_d-48) )); elif (( _d==0 || _d==32 )); then break; fi; done
  
  (( (_blk[257]==117 && _blk[258]==115 && _blk[259]==116 && _blk[260]==97 && _blk[261]==114) || _oct==_sum_u || _oct==_sum_s ))
}

fn_detect_magic() {
  local _file="$1" _fsize; local -a _hdr=()

  [[ -z "$_file" || ! -e "$_file" || ! -r "$_file" || ! -f "$_file" || -L "$_file" ]] && return $_EXITCODE_INVALID_ARGS
  _fsize=$(fn_filesize "$_file"); (( _fsize==0 )) && return $_EXITCODE_INVALID_ARGS
  fn_read_bytes "$_file" "$_MAGIC_READ_SIZE" _hdr || return $_EXITCODE_FREAD_FAILED
  
  local _len=${#_hdr[@]}
  local _bytes=$(printf "%s " "${_hdr[@]}")

  case "$_bytes" in
    "31 139 "*) echo gzip; return 0;;
    "80 75 3 4 "*) echo zip; return 0;;
    "80 75 5 6 "*) echo zip-empty; return 0;;
    "80 75 7 8 "*) echo zip-spanned; return 0;;
    "66 90 104 "*) echo bzip2; return 0;;
    "253 55 122 88 90 0 "*) echo xz; return 0;;
    "55 122 188 175 39 28 "*) echo 7z; return 0;;
    "82 97 114 33 26 7 0 0 "*) echo rar; return 0;;
    "82 97 114 33 26 7 1 0 "*) echo rar5; return 0;;
    "40 181 47 253 "*) echo zstd; return 0;;
    "4 34 77 24 "*) echo lz4; return 0;;
    "76 90 73 80 "*) echo lzip; return 0;;
    "31 157 "*) echo compress; return 0;;
    "31 160 "*) echo pack; return 0;;
    "206 178 207 129 "*) echo brotli; return 0;;
    "237 171 238 219 "*) echo rpm; return 0;;
    "33 60 97 114 99 104 62 10 "*) { fn_check_deb "$_file" && { echo deb; return 0; }; echo ar; return 0; };;
    "77 83 67 70 "*) echo cab; return 0;;
    "120 1 115 218 "*) echo dmg; return 0;;
    "107 111 108 121 "*) echo dmg; return 0;;
    "42 42 65 67 69 42 42 0 "*) echo ace; return 0;;
    "96 234 "*) echo arj; return 0;;
    "45 108 104 "*) echo lha; return 0;;
    "83 73 84 33 "*) echo sit; return 0;;
    "83 116 117 102 "*) echo sit; return 0;;
  esac

  fn_check_iso "$_file" && { echo iso; return 0; }
  fn_check_cpio "$_file" "$_len" _hdr && return 0
  fn_check_tar "$_file" && { echo tar; return 0; }
  
  return $_EXITCODE_UNSUPPORTED_FORMAT
}

fn_get_base_name() {
  local _fname="$1" _method="$2" _format="$3" _base="$_fname"

  if [[ "$_method" == ext ]]; then
    if [[ "$_format" =~ ^(tar\.|t[gbx]z|tzst) ]]; then
      [[ "$_format" =~ ^t[gbx]z|tzst$ ]] && _base="${_fname%.*}" || _base="${_fname%.*.*}"
    else
      _base="${_fname%.*}"
    fi
  else
    while [[ "$_base" =~ \.(gz|bz2|xz|zst|Z|lz|lzma|lz4|br|tar|zip|rar|7z)$ ]]; do
      _base="${_base%.*}"
    done
  fi

  echo "$_base"
}

fn_get_ext() {
  local _fname="${1##*/}" _ext=""
  
  if [[ "$_fname" =~ \.(tar\.(gz|bz2|xz|zst)|t(gz|bz2|xz|zst))$ ]]; then
    case "${BASH_REMATCH[1]}" in
      tar.*) _ext="${BASH_REMATCH[1]}";;
      tgz) _ext=tar.gz;; tbz2) _ext=tar.bz2;; txz) _ext=tar.xz;; tzst) _ext=tar.zst;;
    esac
  elif [[ "$_fname" =~ \.([^.]+)$ ]]; then
    _ext="${BASH_REMATCH[1]}"
  fi
  
  echo "$_ext"
}

fn_add_file() {
  local _file="$1" _ext _magic_type
  [[ ! -f "$_file" ]] && return
  _ext=$(fn_get_ext "$_file")
  if [[ -n "$_ext" && -n "${_EXTRACTORS[$_ext]:-}" ]]; then _FLIST+=("$_file"); return; fi
  if (( _ARGS_ALL_EXT==1 )); then
    _magic_type=$(fn_detect_magic "$_file" 2>/dev/null || true)
    if [[ -n "$_magic_type" && -n "${_MAGIC_EXTRACTORS[$_magic_type]:-}" ]]; then _FLIST+=("$_file"); fi
  fi
}

fn_collect_archives() {
  local _dir="$1" _file
  local -a _files=()
  
  # Use mapfile to safely collect files without IFS manipulation
  mapfile -t _files < <(find "$_dir" -maxdepth 1 -type f -print 2>/dev/null)
  
  for _file in "${_files[@]}"; do
    fn_add_file "$_file"
  done
}

fn_parse_args() {
  local -a _args=()
  local _path _file
  
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -p|--purge)
        _ARGS_PURGE=1
        shift
        ;;
      -o|--overwrite|-f|--force)
        _ARGS_OVERWRITE=1
        shift
        ;;
      -a|--all-extensions)
        _ARGS_ALL_EXT=1
        shift
        ;;
      --)
        shift
        break
        ;;
      -*)
        fn_error "Unknown option: $1"
        exit $_EXITCODE_INVALID_ARGS
        ;;
      *)
        _args+=("$1")
        shift
        ;;
    esac
  done

  if [[ ${#_args[@]} -eq 0 ]]; then
    fn_error "No input files specified"
    exit $_EXITCODE_INVALID_ARGS
  fi

  for _path in "${_args[@]}"; do
    if [[ -d "$_path" ]]; then
      fn_collect_archives "$_path"
    elif [[ -e "$_path" ]]; then
      fn_add_file "$_path"
    else
      shopt -s nullglob
      mapfile -t _expanded < <(compgen -G -- "$_path")
      shopt -u nullglob
      
      if (( ${#_expanded[@]} > 0 )); then
        for _file in "${_expanded[@]}"; do
          fn_add_file "$_file"
        done
      else
        fn_warning "No files match pattern: $_path"
      fi
    fi
  done

  if (( ${#_FLIST[@]} == 0 )); then
    fn_error "No supported archive files found"
    exit $_EXITCODE_INVALID_ARGS
  fi
}

fn_check_deps() {
  local -A _deps_map=()
  local _file _ext _magic_type _extractor
  for _file in "${_FLIST[@]}"; do
    _ext=$(fn_get_ext "$_file")
    if [[ -n "$_ext" && -n "${_EXTRACTORS[$_ext]:-}" ]]; then _extractor="${_EXTRACTORS[$_ext]}"
    elif (( _ARGS_ALL_EXT==1 )); then _magic_type=$(fn_detect_magic "$_file" 2>/dev/null || true); [[ -n "$_magic_type" ]] && _extractor="${_MAGIC_EXTRACTORS[$_magic_type]:-}"; fi
    [[ -n "${_extractor:-}" ]] && _deps_map["$_extractor"]=1
  done
  if [[ -n "${_deps_map[tar]:-}" ]]; then
    for _file in "${_FLIST[@]}"; do _ext=$(fn_get_ext "$_file"); [[ "$_ext" == tar.zst || "$_ext" == tzst ]] && _deps_map[zstd]=1; done
  fi
  local _dep _missing=()
  
  for _dep in "${!_deps_map[@]}"; do command -v "$_dep" &>/dev/null || _missing+=("$_dep"); done
  
  if (( ${#_missing[@]} )); then
    local _missing_deps
    
    printf -v _missing_deps "  %s" "${_missing[@]}"
    fn_error "Missing required dependencies: $_missing_deps"
    
    exit $_EXITCODE_DEPS_MISSING
  fi
}

fn_get_unique_dir() {
  local _base="$1" _dir="$_base" _counter=1
  if (( _ARGS_OVERWRITE==1 )); then rm -rf -- "$_dir" 2>/dev/null || true; echo "$_dir"; return; fi
  while [[ -e "$_dir" ]]; do _dir=$(printf "%s-%02d" "$_base" "$_counter"); ((_counter++)); (( _counter>999 )) && { echo "Error: Cannot create unique directory for: $_base" >&2; return 1; }; done
  echo "$_dir"
}

fn_get_extract_type() {
  local _file="$1" _ext _magic_type
  _ext=$(fn_get_ext "$_file")
  if [[ -n "$_ext" && -n "${_EXTRACTORS[$_ext]:-}" ]]; then echo "ext:$_ext"; return; fi
  _magic_type=$(fn_detect_magic "$_file" 2>/dev/null || true)
  if [[ -n "$_magic_type" && -n "${_MAGIC_EXTRACTORS[$_magic_type]:-}" ]]; then echo "magic:$_magic_type"; return; fi
  return 1
}

fn_flatten_if_needed() {
  local _src="$1" _dst="$2"
  local -a _entries=() _info_files=()
  local _single_dir=""
  shopt -s nullglob dotglob; _entries=("$_src"/*); shopt -u nullglob dotglob
  if (( ${#_entries[@]}==0 )); then mkdir -p -- "$_dst"; return; fi
  local _e _name _name_upper
  for _e in "${_entries[@]}"; do
    _name="${_e##*/}"; _name_upper="${_name^^}"
    if [[ "$_name_upper" =~ ^(README|LICENSE|LICENCE|COPYING|AUTHORS|CHANGELOG|NOTICE|COPYRIGHT|INSTALL|NEWS|THANKS|TODO|HISTORY)(\..*)?$ ]]; then
      _info_files+=("$_e"); continue
    fi
    if [[ -d "$_e" ]]; then
      if [[ -z "$_single_dir" ]]; then _single_dir="$_e"; else _single_dir=""; break; fi
    else
      _single_dir=""; break
    fi
  done
  mkdir -p -- "$_dst"
  if [[ -n "$_single_dir" ]]; then
    shopt -s nullglob dotglob
    mv -f -- "$_single_dir"/* "$_dst"/ 2>/dev/null || true
    shopt -u nullglob dotglob
    local _info
    for _info in "${_info_files[@]}"; do
      local _bn="${_info##*/}" _t="$_dst/$_bn" _i=1 _stem="${_bn%.*}" _ext="${_bn##*.}"
      while [[ -e "$_t" ]]; do
        if [[ "$_stem" == "$_ext" ]]; then _t=$(printf "%s/owned-%s-%02d" "$_dst" "$_stem" "$_i")
        else _t=$(printf "%s/owned-%s-%02d.%s" "$_dst" "$_stem" "$_i" "$_ext"); fi
        ((_i++))
      done
      mv -f -- "$_info" "$_t" 2>/dev/null || true
    done
  else
    shopt -s nullglob dotglob
    mv -f -- "$_src"/* "$_dst"/ 2>/dev/null || true
    shopt -u nullglob dotglob
  fi
}

fn_zip_count(){
  local _file="$1" _n
  if command -v zipinfo &>/dev/null; then
    _n=$(zipinfo -1 "$1" 2>/dev/null | grep -v '/$' | wc -l)
  else
    _n=$(unzip -Z -1 "$1" 2>/dev/null | grep -v '/$' | wc -l)
  fi
  echo "${_n:-0}"
}

fn_extract() {
  local _file="$1" _fname="${_file##*/}" _dir="${_file%/*}"
  local _type _method _format _base _target_dir _temp_dir _rc=0
  _type=$(fn_get_extract_type "$_file") || return 1
  _method="${_type%%:*}"; _format="${_type#*:}"
  _base=$(fn_get_base_name "$_fname" "$_method" "$_format")

  _target_dir=$(fn_get_unique_dir "$_dir/$_base") || return 1
  _temp_dir=$(mktemp -d "${_target_dir}.tmp.XXXXXX") || return 1; fn_register_tmp "$_temp_dir"

  case "$_format" in
    zip|zip-*) unzip -q "$_file" -d "$_temp_dir" 2>/dev/null || _rc=$? ;;
    rar|rar5)  unrar x -y "$_file" "$_temp_dir"/ >/dev/null 2>&1 || _rc=$? ;;
    7z)        7z x -y -o"$_temp_dir" "$_file" >/dev/null 2>&1 || _rc=$? ;;
    tar)       tar -C "$_temp_dir" -xf "$_file" 2>/dev/null || _rc=$? ;;
    tar.gz|tgz|gzip)
      if [[ "$_format" == gzip ]]; then gzip -dc "$_file" > "$_temp_dir/${_base}" 2>/dev/null || _rc=$?
      else tar -C "$_temp_dir" -xzf "$_file" 2>/dev/null || _rc=$?; fi ;;
    tar.bz2|tbz2|bzip2)
      if [[ "$_format" == bzip2 ]]; then bzip2 -dc "$_file" > "$_temp_dir/${_base}" 2>/dev/null || _rc=$?
      else tar -C "$_temp_dir" -xjf "$_file" 2>/dev/null || _rc=$?; fi ;;
    tar.xz|txz|xz)
      if [[ "$_format" == xz ]]; then xz -dc "$_file" > "$_temp_dir/${_base}" 2>/dev/null || _rc=$?
      else tar -C "$_temp_dir" -xJf "$_file" 2>/dev/null || _rc=$?; fi ;;
    tar.zst|tzst|zstd)
      if [[ "$_format" == zstd ]]; then zstd -dc "$_file" > "$_temp_dir/${_base}" 2>/dev/null || _rc=$?
      else if command -v zstdmt &>/dev/null; then zstdmt -dc "$_file" | tar -C "$_temp_dir" -x 2>/dev/null || _rc=$?
           else zstd -dc "$_file" | tar -C "$_temp_dir" -x 2>/dev/null || _rc=$?; fi; fi ;;
    gz)   gzip -dc "$_file" > "$_temp_dir/${_base}" 2>/dev/null || _rc=$? ;;
    bz2)  bzip2 -dc "$_file" > "$_temp_dir/${_base}" 2>/dev/null || _rc=$? ;;
    Z|compress|pack) uncompress -c "$_file" > "$_temp_dir/${_base}" 2>/dev/null || _rc=$? ;;
    lz|lzip) lzip -dc "$_file" > "$_temp_dir/${_base}" 2>/dev/null || _rc=$? ;;
    lzma) lzma -dc "$_file" > "$_temp_dir/${_base}" 2>/dev/null || _rc=$? ;;
    lz4)  lz4 -dc "$_file" > "$_temp_dir/${_base}" 2>/dev/null || _rc=$? ;;
    br|brotli) brotli -dc "$_file" > "$_temp_dir/${_base}" 2>/dev/null || _rc=$? ;;
    cpio-*) ( cd "$_temp_dir" && cpio -id < "$_file" ) 2>/dev/null || _rc=$? ;;
    deb)
      ( cd "$_temp_dir" && ar x "$_file" ) >/dev/null 2>&1 || _rc=$?
      if [[ -f "$_temp_dir/data.tar.gz" ]]; then tar -C "$_temp_dir" -xzf "$_temp_dir/data.tar.gz" 2>/dev/null; rm -f "$_temp_dir/data.tar.gz" "$_temp_dir/control.tar.gz" "$_temp_dir/debian-binary"
      elif [[ -f "$_temp_dir/data.tar.xz" ]]; then tar -C "$_temp_dir" -xJf "$_temp_dir/data.tar.xz" 2>/dev/null; rm -f "$_temp_dir/data.tar.xz" "$_temp_dir/control.tar.xz" "$_temp_dir/debian-binary"; fi ;;
    ar)   ( cd "$_temp_dir" && ar x "$_file" ) 2>/dev/null || _rc=$? ;;
    rpm)  ( cd "$_temp_dir" && rpm2cpio "$_file" | cpio -id ) 2>/dev/null || _rc=$? ;;
    cab)  cabextract -q -d "$_temp_dir" "$_file" 2>/dev/null || _rc=$? ;;
    iso|dmg) 7z x -y -o"$_temp_dir" "$_file" >/dev/null 2>&1 || _rc=$? ;;
    ace)  unace x -y "$_file" "$_temp_dir"/ >/dev/null 2>&1 || _rc=$? ;;
    arj)  ( cd "$_temp_dir" && arj x -y "$_file" ) >/dev/null 2>&1 || _rc=$? ;;
    lha)  lha xq "$_file" "$_temp_dir"/ 2>/dev/null || _rc=$? ;;
    sit)  unsit "$_file" "$_temp_dir"/ 2>/dev/null || _rc=$? ;;
    *)    return 1;;
  esac

  if (( _rc != 0 )); then return $_rc; fi
  fn_flatten_if_needed "$_temp_dir" "$_target_dir"
  rm -rf -- "$_temp_dir" 2>/dev/null || true

  if [[ -d "$_target_dir" ]]; then
    local _size
    if [[ "$OSTYPE" == "darwin"* ]]; then _size=$(du -sk -- "$_target_dir" 2>/dev/null | cut -f1); _size=$((_size * 1024))
    else _size=$(du -sb -- "$_target_dir" 2>/dev/null | cut -f1); fi
    _TOTAL_SIZE=$((_TOTAL_SIZE + ${_size:-0}))
  fi
  return 0
}

fn_verify_extraction() {
  local _file="$1" _dir="$2" _type _method _format
  [[ ! -d "$_dir" ]] && return 1
  local _count; _count=$(find "$_dir" -type f 2>/dev/null | wc -l)
  (( _count==0 )) && return 1
  _type=$(fn_get_extract_type "$_file" 2>/dev/null || true)
  if [[ -n "$_type" ]]; then _method="${_type%%:*}"; _format="${_type#*:}"; fi
  case "$_format" in
    zip|zip-*)
      local _expected; _expected=$(fn_zip_count "$_file")
      if [[ -n "$_expected" && "$_expected" =~ ^[0-9]+$ ]]; then (( _count < _expected )) && return 1; fi ;;
    tar|tar.*|t[gbx]z*|tzst)
      local _expected; _expected=$(tar -tf "$_file" 2>/dev/null | grep -v '/$' | wc -l)
      if [[ -n "$_expected" && "$_expected" =~ ^[0-9]+$ ]]; then (( _count != _expected )) && return 1; fi ;;
  esac
  return 0
}

fn_find_created_dir() {
  local _base="$1"
  if [[ -d "$_base" ]]; then echo "$_base"; return; fi
  local i
  for i in {01..99}; do [[ -d "${_base}-${i}" ]] && { echo "${_base}-${i}"; return; }; done
  echo "$_base"
}

fn_process_file() {
  local _file="$1" _fname="${_file##*/}" _dir="${_file%/*}" _type _base _target_dir
  printf 'Processing: %s ... ' "$_fname"
  _type=$(fn_get_extract_type "$_file" 2>/dev/null || true)
  if [[ -z "$_type" ]]; then echo 'SKIPPED (unsupported format)'; _FAILED_FILES+=("$_fname: Unsupported format"); return 1; fi
  
  local _method="${_type%%:*}" _format="${_type#*:}"
  _base=$(fn_get_base_name "$_fname" "$_method" "$_format")
  _target_dir="$_dir/$_base"

  if fn_extract "$_file"; then
    local _actual_dir; _actual_dir=$(fn_find_created_dir "$_target_dir")
    if fn_verify_extraction "$_file" "$_actual_dir"; then
      echo "OK [${_type#*:}]"; ((_SUCCESS_COUNT++))
      if (( _ARGS_PURGE==1 )); then rm -f -- "$_file" 2>/dev/null && echo "  -> Original deleted"; fi
      return 0
    else
      echo 'FAILED (verification error)'; _FAILED_FILES+=("$_fname: Extraction verification failed"); [[ -d "$_actual_dir" ]] && rm -rf -- "$_actual_dir"
      return 1
    fi
  else
    echo 'FAILED (extraction error)'; _FAILED_FILES+=("$_fname: Extraction failed")
    return 1
  fi
}

fn_main() {
  fn_parse_args "$@"

  echo "Found ${#_FLIST[@]} archive(s) to process"; echo

  fn_check_deps
  _TOTAL_FILES=${#_FLIST[@]}

  local _file
  for _file in "${_FLIST[@]}"; do fn_process_file "$_file" || true; done

  echo
  echo "## Result"
  echo "Succeeded: $_SUCCESS_COUNT/$_TOTAL_FILES"
  if (( _TOTAL_SIZE==0 )); then echo "Size: 0"
  else echo "Size: $((_TOTAL_SIZE/1024)) KB"; fi

  if (( ${#_FAILED_FILES[@]} )); then
    echo "## Failed"
    echo "Failed extractions:"; printf "  - %s\n" "${_FAILED_FILES[@]}"
    exit 1
  fi
  exit 0
}

fn_main "$@"
fn_main "$@"
  for _file in "${_FLIST[@]}"; do fn_process_file "$_file" || true; done

  echo
  echo "## Result"
  echo "Succeeded: $_SUCCESS_COUNT/$_TOTAL_FILES"
  if (( _TOTAL_SIZE==0 )); then echo "Size: 0"
  else echo "Size: $((_TOTAL_SIZE/1024)) KB"; fi

  if (( ${#_FAILED_FILES[@]} )); then
    echo "## Failed"
    echo "Failed extractions:"; printf "  - %s\n" "${_FAILED_FILES[@]}"
    exit 1
  fi
  exit 0
}

fn_main "$@"
fn_main "$@"
fn_main "$@"
fn_main "$@"
