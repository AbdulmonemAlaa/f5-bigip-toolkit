#!/bin/bash

#######################################################
# check_vs_ssl_profiles.sh
#######################################################
#
# Author:
#   Eng. Abdulmonem Alaa Aldeen
#
# Purpose:
#   For each Virtual Server in the provided list file:
#     - Detect Client SSL and Server SSL profiles
#     - Extract Certificate/Key/Chain for Client SSL profiles
#     - Extract Certificate/Key/Chain (if configured) for Server SSL profiles
#     - Extract useful Server SSL fields (ca-file, peer-cert-mode, server-name, sni-default)
#
# Usage:
#   sed -i 's/\r$//' check_vs_ssl_profiles.sh
#   chmod +x check_vs_ssl_profiles.sh
#   ./check_vs_ssl_profiles.sh vs_list.txt > vip_ssl_report.csv
#
#######################################################


#############################
# Input Validation
#############################

INPUT_FILE="$1"

if [[ -z "$INPUT_FILE" || ! -f "$INPUT_FILE" ]]; then
  echo "Usage: $0 <vs_list_file>" >&2
  exit 1
fi

ALLVS="$(tmsh -q -c 'list ltm virtual one-line' 2>/dev/null)"

echo "VS_Name,ClientSSL_Profiles,Client_Cert,Client_Key,Client_Chain,ServerSSL_Profiles,Server_Cert,Server_Key,Server_Chain,Server_CA_File,Server_PeerCertMode,Server_Name,Server_SNI_Default"


#############################
# Caches
#############################

declare -A C_CERT_CACHE C_KEY_CACHE C_CHAIN_CACHE
declare -A S_CERT_CACHE S_KEY_CACHE S_CHAIN_CACHE S_CA_CACHE S_PCM_CACHE S_SNAME_CACHE S_SNI_CACHE


#############################
# Functions
#############################

parse_cert_key_chain() {
  local out="$1"
  local cert key chain

  cert="$(printf '%s\n' "$out" | sed -n 's/^[[:space:]]*cert[[:space:]]\+\([^[:space:]]\+\).*$/\1/p' | head -n 1)"
  key="$(printf '%s\n'  "$out" | sed -n 's/^[[:space:]]*key[[:space:]]\+\([^[:space:]]\+\).*$/\1/p'  | head -n 1)"
  chain="$(printf '%s\n' "$out" | sed -n 's/^[[:space:]]*chain[[:space:]]\+\([^[:space:]]\+\).*$/\1/p'| head -n 1)"

  if [[ -z "${cert}${key}${chain}" ]]; then
    cert="$(printf '%s\n' "$out" | awk '$1=="cert-key-chain"{inb=1} inb&&$1=="cert"{print $2; exit}')"
    key="$(printf '%s\n' "$out" | awk '$1=="cert-key-chain"{inb=1} inb&&$1=="key"{print $2; exit}')"
    chain="$(printf '%s\n' "$out" | awk '$1=="cert-key-chain"{inb=1} inb&&$1=="chain"{print $2; exit}')"
  fi

  [[ -z "$cert"  ]] && cert="(not-set)"
  [[ -z "$key"   ]] && key="(not-set)"
  [[ -z "$chain" ]] && chain="(not-set)"

  printf '%s|%s|%s' "$cert" "$key" "$chain"
}


get_clientssl_fields() {
  local prof="$1"

  if [[ -n "${C_CERT_CACHE[$prof]+x}" ]]; then
    printf '%s|%s|%s' "${C_CERT_CACHE[$prof]}" "${C_KEY_CACHE[$prof]}" "${C_CHAIN_CACHE[$prof]}"
    return
  fi

  local out
  out="$(tmsh -q -c "list ltm profile client-ssl $prof" 2>/dev/null)" || \
  out="$(tmsh -q -c "list ltm profile client-ssl /Common/$prof" 2>/dev/null)"

  local fields cert key chain
  fields="$(parse_cert_key_chain "$out")"
  cert="${fields%%|*}"; rest="${fields#*|}"
  key="${rest%%|*}"; chain="${rest#*|}"

  C_CERT_CACHE[$prof]="$cert"
  C_KEY_CACHE[$prof]="$key"
  C_CHAIN_CACHE[$prof]="$chain"

  printf '%s|%s|%s' "$cert" "$key" "$chain"
}


get_serverssl_fields() {
  local prof="$1"

  if [[ -n "${S_CERT_CACHE[$prof]+x}" ]]; then
    printf '%s|%s|%s|%s|%s|%s|%s' \
      "${S_CERT_CACHE[$prof]}" "${S_KEY_CACHE[$prof]}" "${S_CHAIN_CACHE[$prof]}" \
      "${S_CA_CACHE[$prof]}" "${S_PCM_CACHE[$prof]}" "${S_SNAME_CACHE[$prof]}" "${S_SNI_CACHE[$prof]}"
    return
  fi

  local out
  out="$(tmsh -q -c "list ltm profile server-ssl $prof" 2>/dev/null)" || \
  out="$(tmsh -q -c "list ltm profile server-ssl /Common/$prof" 2>/dev/null)"

  local fields cert key chain
  fields="$(parse_cert_key_chain "$out")"
  cert="${fields%%|*}"; rest="${fields#*|}"
  key="${rest%%|*}"; chain="${rest#*|}"

  local ca_file peer_cert_mode server_name sni_default
  ca_file="$(printf '%s\n' "$out" | sed -n 's/^[[:space:]]*ca-file[[:space:]]\+\([^[:space:]]\+\).*$/\1/p' | head -n 1)"
  peer_cert_mode="$(printf '%s\n' "$out" | sed -n 's/^[[:space:]]*peer-cert-mode[[:space:]]\+\([^[:space:]]\+\).*$/\1/p' | head -n 1)"
  server_name="$(printf '%s\n' "$out" | sed -n 's/^[[:space:]]*server-name[[:space:]]\+\([^[:space:]]\+\).*$/\1/p' | head -n 1)"
  sni_default="$(printf '%s\n' "$out" | sed -n 's/^[[:space:]]*sni-default[[:space:]]\+\([^[:space:]]\+\).*$/\1/p' | head -n 1)"

  [[ -z "$ca_file" ]] && ca_file="(not-set)"
  [[ -z "$peer_cert_mode" ]] && peer_cert_mode="(not-set)"
  [[ -z "$server_name" ]] && server_name="(not-set)"
  [[ -z "$sni_default" ]] && sni_default="(not-set)"

  S_CERT_CACHE[$prof]="$cert"
  S_KEY_CACHE[$prof]="$key"
  S_CHAIN_CACHE[$prof]="$chain"
  S_CA_CACHE[$prof]="$ca_file"
  S_PCM_CACHE[$prof]="$peer_cert_mode"
  S_SNAME_CACHE[$prof]="$server_name"
  S_SNI_CACHE[$prof]="$sni_default"

  printf '%s|%s|%s|%s|%s|%s|%s' "$cert" "$key" "$chain" "$ca_file" "$peer_cert_mode" "$server_name" "$sni_default"
}


#############################
# Main Loop
#############################

while read VS; do
  VS="$(printf '%s' "$VS" | tr -d '\r' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
  [[ -z "$VS" || "$VS" =~ ^# ]] && continue

  VS_LINE="$(printf '%s\n' "$ALLVS" | grep -E "^ltm virtual ${VS} " | head -n 1 || true)"
  [[ -z "$VS_LINE" ]] && VS_LINE="$(printf '%s\n' "$ALLVS" | grep -i "^ltm virtual " | grep -i "$VS" | head -n 1 || true)"

  if [[ -z "$VS_LINE" ]]; then
    echo "$VS,,,,,,,,,,,"
    continue
  fi

  CLIENT_PROFILES="$(printf '%s\n' "$VS_LINE" | grep -oE '[^ {]+ \{ context clientside \}' | awk '{print $1}' | paste -sd ';' - || true)"
  SERVER_PROFILES="$(printf '%s\n' "$VS_LINE" | grep -oE '[^ {]+ \{ context serverside \}' | awk '{print $1}' | paste -sd ';' - || true)"

  C_CERTS=""; C_KEYS=""; C_CHAINS=""
  S_CERTS=""; S_KEYS=""; S_CHAINS=""
  S_CA_FILES=""; S_PCMS=""; S_SNAME=""; S_SNI=""

  if [[ -n "$CLIENT_PROFILES" ]]; then
    IFS=';' read -r -a CP <<< "$CLIENT_PROFILES"
    for p in "${CP[@]}"; do
      f="$(get_clientssl_fields "$p")"
      c="${f%%|*}"; r="${f#*|}"; k="${r%%|*}"; ch="${r#*|}"
      C_CERTS+="${C_CERTS:+;}$p=$c"
      C_KEYS+="${C_KEYS:+;}$p=$k"
      C_CHAINS+="${C_CHAINS:+;}$p=$ch"
    done
  fi

  if [[ -n "$SERVER_PROFILES" ]]; then
    IFS=';' read -r -a SP <<< "$SERVER_PROFILES"
    for p in "${SP[@]}"; do
      f="$(get_serverssl_fields "$p")"
      cert="${f%%|*}"; rest="${f#*|}"
      key="${rest%%|*}"; rest="${rest#*|}"
      chain="${rest%%|*}"; rest="${rest#*|}"
      ca="${rest%%|*}"; rest="${rest#*|}"
      pcm="${rest%%|*}"; rest="${rest#*|}"
      sname="${rest%%|*}"; sni="${rest#*|}"

      S_CERTS+="${S_CERTS:+;}$p=$cert"
      S_KEYS+="${S_KEYS:+;}$p=$key"
      S_CHAINS+="${S_CHAINS:+;}$p=$chain"
      S_CA_FILES+="${S_CA_FILES:+;}$p=$ca"
      S_PCMS+="${S_PCMS:+;}$p=$pcm"
      S_SNAME+="${S_SNAME:+;}$p=$sname"
      S_SNI+="${S_SNI:+;}$p=$sni"
    done
  fi

  echo "$VS,\"$CLIENT_PROFILES\",\"$C_CERTS\",\"$C_KEYS\",\"$C_CHAINS\",\"$SERVER_PROFILES\",\"$S_CERTS\",\"$S_KEYS\",\"$S_CHAINS\",\"$S_CA_FILES\",\"$S_PCMS\",\"$S_SNAME\",\"$S_SNI\""

done < "$INPUT_FILE"
