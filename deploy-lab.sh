#!/usr/bin/env bash
#
# deploy-lab.sh - Labo reseau segmente et securise sur namespaces Linux
# Auteur : Johan - BUT RT2
#
# Reproduit un petit reseau d'entreprise (3 segments + routeur/pare-feu)
# entierement sur une seule machine, sans VM, grace aux namespaces reseau.
# Inclut : routage, pare-feu stateful, DHCP + DNS, et acces Internet (NAT).
#
# Usage :
#   sudo ./deploy-lab.sh up       # construit le labo
#   sudo ./deploy-lab.sh down     # detruit le labo (nettoyage complet)
#   sudo ./deploy-lab.sh status   # affiche l'etat
#
# Prerequis : iproute2, nftables, dnsmasq, openssh-server, isc-dhcp-client, python3
# ---------------------------------------------------------------------------

set -e  # arrete le script a la premiere erreur

# ==============================  CONFIG  ===================================
# Interface du PC par laquelle le labo sort sur Internet.
# Detectee automatiquement (celle de la route par defaut).
# Pour forcer une interface precise, remplacer par :  WAN_IF="nom_interface"
WAN_IF="$(ip route show default | awk '{print $5; exit}')"

# Dossier du script (pour y trouver les fichiers de config)
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DNSMASQ_CONF="$SCRIPT_DIR/dnsmasq-lan.conf"
FW_CONF="$SCRIPT_DIR/fw-ns-fw.nft"   # pare-feu + NAT + anti-brute-force SSH

# ============================  PLAN D'ADRESSAGE  ============================
# LAN        192.168.10.0/24   client (DHCP)   passerelle .254
# DMZ        192.168.20.0/24   web .1          passerelle .254
# Management 192.168.30.0/24   admin .1        passerelle .254
# Uplink     10.200.200.0/30   PC .1  <->  ns-fw .2   (sortie Internet)
# ===========================================================================

up() {
  echo "[*] Creation des namespaces + loopback..."
  for ns in ns-lan ns-dmz ns-mgmt ns-fw; do
    ip netns add "$ns"
    ip netns exec "$ns" ip link set lo up
  done

  echo "[*] Cables internes (veth) vers le routeur..."
  ip link add veth-lan  type veth peer name veth-fw-lan
  ip link set veth-lan  netns ns-lan ; ip link set veth-fw-lan  netns ns-fw
  ip link add veth-dmz  type veth peer name veth-fw-dmz
  ip link set veth-dmz  netns ns-dmz ; ip link set veth-fw-dmz  netns ns-fw
  ip link add veth-mgmt type veth peer name veth-fw-mgmt
  ip link set veth-mgmt netns ns-mgmt; ip link set veth-fw-mgmt netns ns-fw

  echo "[*] Uplink entre le routeur et le PC (sortie Internet)..."
  ip link add veth-fw-wan type veth peer name veth-lab-up
  ip link set veth-fw-wan netns ns-fw
  ip addr add 10.200.200.1/30 dev veth-lab-up
  ip link set veth-lab-up up

  echo "[*] Adressage des clients..."
  ip netns exec ns-dmz  ip addr add 192.168.20.1/24 dev veth-dmz
  ip netns exec ns-dmz  ip link set veth-dmz up
  ip netns exec ns-mgmt ip addr add 192.168.30.1/24 dev veth-mgmt
  ip netns exec ns-mgmt ip link set veth-mgmt up
  ip netns exec ns-lan  ip link set veth-lan up   # ns-lan : IP via DHCP (plus bas)

  echo "[*] Adressage des pattes du routeur..."
  ip netns exec ns-fw ip addr add 192.168.10.254/24 dev veth-fw-lan  ; ip netns exec ns-fw ip link set veth-fw-lan up
  ip netns exec ns-fw ip addr add 192.168.20.254/24 dev veth-fw-dmz  ; ip netns exec ns-fw ip link set veth-fw-dmz up
  ip netns exec ns-fw ip addr add 192.168.30.254/24 dev veth-fw-mgmt ; ip netns exec ns-fw ip link set veth-fw-mgmt up
  ip netns exec ns-fw ip addr add 10.200.200.2/30   dev veth-fw-wan  ; ip netns exec ns-fw ip link set veth-fw-wan up

  echo "[*] Routage..."
  ip netns exec ns-fw sysctl -w net.ipv4.ip_forward=1 >/dev/null
  ip netns exec ns-fw   ip route add default via 10.200.200.1   # routeur -> PC -> Internet
  ip netns exec ns-dmz  ip route add default via 192.168.20.254
  ip netns exec ns-mgmt ip route add default via 192.168.30.254

  echo "[*] Pare-feu + NAT + anti-brute-force SSH (fichier $FW_CONF)..."
  # Charge tout le jeu de regles du routeur depuis le fichier nft :
  # politique deny by default, filtrage par port, NAT de sortie,
  # et bannissement automatique apres 3 tentatives SSH/minute.
  ip netns exec ns-fw nft -f "$FW_CONF"

  echo "[*] NAT sur le PC (vers $WAN_IF)..."
  sysctl -w net.ipv4.ip_forward=1 >/dev/null
  nft add table ip lab_nat
  nft add chain ip lab_nat postrouting '{ type nat hook postrouting priority 100 ; }'
  nft add rule ip lab_nat postrouting ip saddr 10.200.200.0/30 oifname "$WAN_IF" masquerade

  echo "[*] resolv.conf dedie au namespace LAN (evite de toucher au DNS du PC)..."
  mkdir -p /etc/netns/ns-lan
  echo "nameserver 192.168.10.254" > /etc/netns/ns-lan/resolv.conf

  echo "[*] Generation de la config dnsmasq (DHCP + DNS)..."
  cat > "$DNSMASQ_CONF" <<EOF
# DHCP + DNS pour le segment LAN (tourne dans ns-fw)
interface=veth-fw-lan
bind-interfaces
dhcp-range=192.168.10.2,192.168.10.253,255.255.255.0,2h
dhcp-option=3,192.168.10.254
dhcp-option=6,192.168.10.254
domain=lan
address=/web.lan/192.168.20.1
no-resolv
server=8.8.8.8
log-dhcp
EOF

  echo "[*] Demarrage dnsmasq..."
  pkill -f dnsmasq-lan.conf 2>/dev/null || true
  ip netns exec ns-fw dnsmasq --conf-file="$DNSMASQ_CONF"

  echo "[*] Services dans la DMZ (SSH + serveur web)..."
  mkdir -p /run/sshd
  ip netns exec ns-dmz /usr/sbin/sshd
  ip netns exec ns-dmz bash -c 'python3 -m http.server 80 >/tmp/web-dmz.log 2>&1 &'

  echo "[*] Le client LAN demande une adresse en DHCP..."
  ip netns exec ns-lan dhclient veth-lan 2>/dev/null || \
    echo "    (dhclient absent : installer isc-dhcp-client, ou adresser ns-lan a la main)"

  echo "[+] Labo deploye avec acces Internet."
}

down() {
  echo "[*] Arret des services du labo..."
  pkill -f dnsmasq-lan.conf 2>/dev/null || true
  pkill -f "http.server 80"  2>/dev/null || true

  echo "[*] Suppression des namespaces (nettoie aussi les veth)..."
  for ns in ns-lan ns-dmz ns-mgmt ns-fw; do
    ip netns del "$ns" 2>/dev/null || true
  done

  echo "[*] Nettoyage du NAT et du resolv.conf cote PC..."
  nft delete table ip lab_nat 2>/dev/null || true
  rm -rf /etc/netns/ns-lan

  echo "[+] Labo supprime."
}

status() {
  echo "=== Namespaces ==="
  ip netns list
  echo
  echo "=== Pare-feu (ns-fw) ==="
  ip netns exec ns-fw nft list ruleset 2>/dev/null || echo "(aucune regle)"
}

case "${1:-}" in
  up)     up ;;
  down)   down ;;
  status) status ;;
  *)      echo "Usage : sudo $0 {up|down|status}" ; exit 1 ;;
esac
