#!/usr/bin/env bash
set -euo pipefail

# Ubuntu init.sh: Instala Docker (docs oficiais), Portainer, NetworkManager (nmtui),
# desabilita systemd-networkd, cria diretórios/configs, aplica correção de porta 53 (Pi-hole),
# instala utilitários e cria/ativa services do sistema.

require_root() {
  if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
    echo "Este script deve ser executado como root. Ex.: sudo $0" >&2
    exit 1
  fi
}

ensure_ubuntu() {
  if [[ ! -f /etc/os-release ]]; then
    echo "/etc/os-release não encontrado; não é um sistema compatível." >&2
    exit 1
  fi
  . /etc/os-release
  if [[ "${ID}" != "ubuntu" ]]; then
    echo "Distribuição detectada: ${ID}. Este script segue apenas as instruções oficiais do Ubuntu." >&2
    exit 1
  fi
}

install_docker_ubuntu() {
  # Fonte: https://docs.docker.com/engine/install/ubuntu/
  apt-get update -y
  apt-get install -y ca-certificates curl gnupg
  install -m 0755 -d /etc/apt/keyrings
  if [[ ! -f /etc/apt/keyrings/docker.gpg ]]; then
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg
  fi
  . /etc/os-release
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu ${VERSION_CODENAME} stable" \
    > /etc/apt/sources.list.d/docker.list
  apt-get update -y
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  systemctl enable --now docker
}

install_portainer() {
  # Fonte: https://docs.portainer.io/start/install-ce/server/docker/linux
  if ! command -v docker >/dev/null 2>&1; then
    echo "Docker não encontrado; instale o Docker antes do Portainer." >&2
    exit 1
  fi
  docker volume create portainer_data >/dev/null 2>&1 || true
  if ! docker ps --format '{{.Names}}' | grep -q '^portainer$'; then
    docker run -d \
      -p 8000:8000 -p 9443:9443 \
      --name portainer \
      --restart=always \
      -v /var/run/docker.sock:/var/run/docker.sock \
      -v portainer_data:/data \
      portainer/portainer-ce:latest
  fi
}

install_network_manager() {
  apt-get update -y
  apt-get install -y network-manager
  systemctl enable --now NetworkManager
}

disable_systemd_networkd() {
  if systemctl list-unit-files | grep -q '^systemd-networkd.service'; then
    systemctl disable --now systemd-networkd || true
    systemctl mask systemd-networkd || true
  fi
}

create_containers_config_dir() {
  mkdir -p /home-data/containers-config/
}

fix_pihole_port53_ubuntu() {
  # Baseado em práticas comuns para liberar a porta 53 no Ubuntu usando systemd-resolved
  if [[ -f /etc/systemd/resolved.conf ]]; then
    sed -i 's/^#\?DNSStubListener=.*/DNSStubListener=no/' /etc/systemd/resolved.conf || true
    if ! grep -q '^DNSStubListener=' /etc/systemd/resolved.conf; then
      echo 'DNSStubListener=no' >> /etc/systemd/resolved.conf
    fi
    systemctl restart systemd-resolved || true
    if [[ -L /etc/resolv.conf || -f /etc/resolv.conf ]]; then
      rm -f /etc/resolv.conf
    fi
    ln -s /run/systemd/resolve/resolv.conf /etc/resolv.conf || true
  fi
}

install_powertop_hdparm() {
  apt-get update -y
  apt-get install -y powertop hdparm
}

create_enable_services_from_units() {
  local script_dir
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  local services_dir="$script_dir/Services"
  if [[ -d "$services_dir" ]]; then
    shopt -s nullglob
    for unit in "$services_dir"/*.service; do
      local name
      name="$(basename "$unit" .service)"
      local target="/etc/systemd/system/${name}.service"
      cp "$unit" "$target"
      chmod 0644 "$target"
      systemctl daemon-reload
      systemctl enable --now "$name" || true
    done
    shopt -u nullglob
  fi
}

run_apps_docker_compose() {
  local script_dir
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  local apps_dir="$script_dir/Apps"
  if [[ -d "$apps_dir" ]]; then
    for dir in "$apps_dir"/*/; do
      [[ -d "$dir" ]] || continue
      if [[ -f "$dir/docker-compose.yml" || -f "$dir/docker-compose.yaml" ]]; then
        if docker compose version >/dev/null 2>&1; then
          (cd "$dir" && docker compose up -d)
        elif command -v docker-compose >/dev/null 2>&1; then
          (cd "$dir" && docker-compose up -d)
        else
          echo "docker compose/docker-compose não encontrado para $dir" >&2
        fi
      fi
    done
  fi
}

main() {
  require_root
  ensure_ubuntu

  echo "[1/9] Instalando Docker (Ubuntu - docs oficiais)"
  install_docker_ubuntu

  echo "[2/9] Instalando Portainer"
  install_portainer

  echo "[3/9] Instalando NetworkManager (nmtui)"
  install_network_manager

  echo "[4/9] Desabilitando systemd-networkd"
  disable_systemd_networkd

  echo "[5/9] Criando diretório /home-data/containers-config/"
  create_containers_config_dir

  echo "[6/9] Aplicando correção da porta 53 para Pi-hole (systemd-resolved)"
  fix_pihole_port53_ubuntu

  echo "[7/9] Instalando powertop e hdparm"
  install_powertop_hdparm

  echo "[8/9] Criando e habilitando serviços a partir de Services/*.service"
  create_enable_services_from_units

  echo "[9/9] Executando docker compose em cada subpasta de Apps"
  run_apps_docker_compose

  echo "Concluído. Portainer: https://<IP>:9443 | Execute 'nmtui' para configurar a rede."
}

main "$@"


