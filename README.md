# Labo réseau segmenté et sécurisé — namespaces Linux

Mini-infrastructure réseau d'entreprise (routeur/pare-feu + 3 segments + accès Internet)
construite **entièrement sur une seule machine Debian, sans machine virtuelle**, à l'aide
des *namespaces réseau* de Linux. Projet personnel d'apprentissage (BUT Réseaux &
Télécommunications).

> Les namespaces réseau sont la technologie qui se trouve sous le capot de Docker et
> Kubernetes. Les manipuler à la main donne une compréhension fine du réseau Linux,
> du routage, du filtrage et de la traduction d'adresses (NAT).

---

## Objectif

Simuler le réseau d'une petite entreprise avec trois zones isolées, reliées par un
routeur qui fait aussi office de pare-feu, serveur DHCP/DNS et passerelle NAT vers
Internet, en appliquant une politique de sécurité *deny by default*.

## Architecture

![Architecture du labo réseau](architecture.png)

Le routeur `ns-fw` possède une patte `.254` dans chaque segment plus un uplink vers le PC.
Tout le trafic inter-segments et vers Internet transite par lui : c'est le point de contrôle
unique où s'applique la politique de pare-feu.

## Plan d'adressage

| Segment     | Réseau             | Machine (namespace) | IP               | Rôle              |
|-------------|--------------------|---------------------|------------------|-------------------|
| LAN         | `192.168.10.0/24`  | ns-fw (patte LAN)   | `192.168.10.254` | Passerelle + DHCP/DNS |
| LAN         | `192.168.10.0/24`  | ns-lan              | DHCP `.2`–`.253` | Poste client      |
| DMZ         | `192.168.20.0/24`  | ns-fw (patte DMZ)   | `192.168.20.254` | Passerelle        |
| DMZ         | `192.168.20.0/24`  | ns-dmz              | `192.168.20.1`   | Serveur web + SSH |
| Management  | `192.168.30.0/24`  | ns-fw (patte MGMT)  | `192.168.30.254` | Passerelle        |
| Management  | `192.168.30.0/24`  | ns-mgmt             | `192.168.30.1`   | Administration    |
| Uplink      | `10.200.200.0/30`  | PC / ns-fw          | `.1` / `.2`      | Sortie Internet   |

Conventions : masque `/24` sur les segments, passerelles en `.254`, hôtes à partir de `.1`.

## Services réseau (DHCP + DNS)

Le routeur `ns-fw` héberge **dnsmasq**, qui fournit au segment LAN :
- le **DHCP** (plage `.2`–`.253`, bail 2 h, passerelle et DNS annoncés automatiquement) ;
- le **DNS** : résolution des noms locaux (ex. `web.lan` → `192.168.20.1`) et transfert
  des noms externes vers un DNS public (`8.8.8.8`).

Le client `ns-lan` obtient donc son adresse **automatiquement** (échange DORA : DISCOVER /
OFFER / REQUEST / ACK), avec passerelle et DNS, comme un vrai poste d'entreprise.

## Politique de sécurité (pare-feu)

Chaîne `forward` en **`policy drop`**, puis exceptions explicites :

| Source      | Destination     | Service        | Autorisé |
|-------------|-----------------|----------------|----------|
| LAN         | DMZ `:80`       | Web (HTTP)     | ✅       |
| Management  | DMZ `:22`       | SSH            | ✅       |
| LAN / MGMT  | Internet        | sortie         | ✅       |
| DMZ         | LAN             | (tout)         | ❌       |
| LAN         | DMZ `:22`       | SSH            | ❌       |
| Réponses des connexions établies (`ct state established,related`) | | | ✅ |

Principes : **deny by default**, **moindre privilège** (filtrage par port), **défense en
profondeur**, pare-feu **stateful**, et **NAT** (masquerade) pour la sortie Internet.

## Détection

Une règle finale journalise et **compte** chaque paquet sur le point d'être bloqué
(`log prefix "FW-DROP " counter`) : le pare-feu garde une trace des tentatives.

```bash
sudo ip netns exec ns-lan nmap 192.168.20.1          # seul :80 visible depuis le LAN
sudo ip netns exec ns-fw nft list ruleset | grep FW-DROP   # compteur de paquets bloques
```

## Protection anti-brute-force (ban automatique)

Le pare-feu détecte les attaques par force brute sur le SSH et **bannit automatiquement**
l'IP fautive, sans outil externe. Il s'appuie sur un *set* nftables dynamique à minuteur :
au-delà de **3 nouvelles connexions SSH par minute** depuis une même IP, celle-ci est
ajoutée à la liste `ssh_ban` pour **10 minutes** et tout son trafic est jeté.

C'est l'équivalent de fail2ban, mais réalisé nativement dans nftables (plus adapté à un
labo en namespaces, où fail2ban — qui lit les journaux système — est difficile à isoler).

```bash
# Simuler une attaque : plusieurs tentatives SSH rapides
for i in 1 2 3 4 5 6; do \
  sudo ip netns exec ns-mgmt ssh -o ConnectTimeout=3 -o BatchMode=yes johan@192.168.20.1 true; \
done

# L'IP attaquante est maintenant bannie
sudo ip netns exec ns-fw nft list set inet filter ssh_ban      # -> 192.168.30.1 (timeout)
sudo ip netns exec ns-mgmt ping -c2 192.168.20.1               # -> bloque (trafic forwarde)

# Debannir manuellement
sudo ip netns exec ns-fw nft delete element inet filter ssh_ban { 192.168.30.1 }
```

> Point clé : le ban agit sur la chaîne `forward` (trafic qui **traverse** le routeur). Un
> ping vers l'adresse du routeur lui-même (`.254`) passe par la chaîne `input` et n'est donc
> pas concerné — d'où l'importance de tester contre un hôte situé **derrière** le pare-feu.

## Accès Internet (NAT)

Le labo sort sur Internet via un double NAT contrôlé : `ns-fw` masque les adresses
internes vers son uplink, et le PC masque l'uplink vers le Wi-Fi. Pour éviter que le
client DHCP du labo n'écrase le DNS du PC, le namespace LAN utilise un `resolv.conf`
dédié (`/etc/netns/ns-lan/resolv.conf`).

## Utilisation

```bash
sudo ./deploy-lab.sh up       # construit tout le labo (pensez a regler WAN_IF en haut du script)
sudo ./deploy-lab.sh status   # affiche namespaces + regles
sudo ./deploy-lab.sh down     # detruit tout (namespaces, NAT, resolv.conf)
```

Le fichier `fw-ns-fw.nft` (règles du pare-feu) doit se trouver à côté du script ; la config
dnsmasq, elle, est générée automatiquement au lancement.

Prérequis : `iproute2`, `nftables`, `dnsmasq`, `openssh-server`, `isc-dhcp-client`, `python3`.

## Tests de validation

```bash
# DHCP : le client obtient une IP automatiquement
sudo ip netns exec ns-lan ip addr show veth-lan              # -> 192.168.10.x

# DNS local + externe
sudo ip netns exec ns-lan nslookup web.lan                   # -> 192.168.20.1
sudo ip netns exec ns-lan ping -c2 google.com                # -> resout + repond

# Routage : le LAN atteint le web de la DMZ
sudo ip netns exec ns-lan curl -sI http://192.168.20.1       # -> 200 OK

# Cloisonnement : la DMZ ne peut pas initier vers le LAN
sudo ip netns exec ns-dmz ping -c2 192.168.10.1              # -> bloque

# Moindre privilege : le LAN ne peut PAS faire de SSH vers la DMZ
sudo ip netns exec ns-lan ssh -o ConnectTimeout=5 johan@192.168.20.1   # -> bloque

# Administration : seul le Management peut faire du SSH
sudo ip netns exec ns-mgmt ssh johan@192.168.20.1            # -> connexion OK
```

## Compétences mises en œuvre

- Réseau Linux bas niveau : namespaces, paires `veth`, tables de routage, `ip_forward`
- Conception d'un plan d'adressage et segmentation en sous-réseaux
- Routage inter-segments et route par défaut
- **DHCP + DNS** avec dnsmasq (baux, options, résolution locale et transfert)
- Pare-feu **nftables** *stateful*, *deny by default*, filtrage par port
- **Protection anti-brute-force** : set nftables dynamique à minuteur (ban automatique)
- **NAT** (masquerade) pour un accès Internet contrôlé
- Isolation du `resolv.conf` par namespace (`/etc/netns/`)
- Services : serveur web, SSH
- Automatisation : script de déploiement rejouable (`up` / `down` / `status`)
- Documentation technique (schéma, plan, politique, tests)

## Pistes d'amélioration

- **IDS** (Suricata) pour inspecter le *contenu* du trafic, pas seulement les en-têtes
- **VPN WireGuard** pour l'accès distant au segment Management
- Supervision (Prometheus + Grafana)
- Rejouer l'ensemble avec Docker pour comparer les deux approches

---

*Projet personnel réalisé dans le cadre du BUT Réseaux & Télécommunications.*
