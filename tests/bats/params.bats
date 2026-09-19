#!/usr/bin/env bash
# bats unit tests: rule parameters (ports/protocol/families) and source config.

setup() {
  load 'helper'
}

@test "ports spec validation" {
  valid_ports_spec any
  valid_ports_spec 443
  valid_ports_spec "443,8443"
  valid_ports_spec "8000-8080"
  run valid_ports_spec 0
  [ "$status" -ne 0 ]
  run valid_ports_spec 65536
  [ "$status" -ne 0 ]
  run valid_ports_spec "9000-8000"
  [ "$status" -ne 0 ]
  run valid_ports_spec abc
  [ "$status" -ne 0 ]
}

@test "ports normalization" {
  [ "$(normalize_ports '8443, 443,443')" = "443,8443" ]
  [ "$(normalize_ports all)" = "any" ]
  [ "$(normalize_ports '8000-8080')" = "8000-8080" ]
  [ "$(normalize_ports '00443')" = "443" ]
}

@test "protocol validation and normalization" {
  valid_protocol_spec tcp
  valid_protocol_spec tcp+udp
  valid_protocol_spec tcp,udp
  run valid_protocol_spec sctp
  [ "$status" -ne 0 ]
  [ "$(normalize_protocol 'udp+tcp')" = "tcp+udp" ]
  [ "$(normalize_protocol all)" = "any" ]
}

@test "effective protocols: allow_ports=all ignores protocol" {
  [ "$(effective_protocols any any)" = "" ]
  [ "$(effective_protocols tcp any)" = "" ]
  [ "$(effective_protocols tcp+udp any)" = "" ]
  [ "$(effective_protocols any 443)" = "tcp udp" ]
  [ "$(effective_protocols tcp 443)" = "tcp" ]
  [ "$(effective_protocols udp 443)" = "udp" ]
  [ "$(ports_to_ufw '443,8000-8080')" = "443,8000:8080" ]
}

@test "source config requires name, type and a matching location" {
  local d; d="$(mktmp)"
  printf 'name=cf\ntype=http\nurls=https://example.com/a\n' >"$d/ok.conf"
  declare -A s=()
  source_load_config s "$d/ok.conf"
  [ "${s[name]}" = "cf" ]
  [ "${s[enabled]}" = "true" ]

  printf 'name=cf\ntype=file\npaths=/tmp/x\nurls=http://x\n' >"$d/bad.conf"
  declare -A b=()
  run source_load_config b "$d/bad.conf"
  [ "$status" -ne 0 ]

  printf 'name=Bad\ntype=http\nurls=http://x\n' >"$d/name.conf"
  declare -A n=()
  run source_load_config n "$d/name.conf"
  [ "$status" -ne 0 ]

  printf 'name=cf\ntype=http\nurls=http://x\nbogus=1\n' >"$d/unk.conf"
  declare -A u=()
  run source_load_config u "$d/unk.conf"
  [ "$status" -ne 0 ]
  rm -rf "$d"
}
