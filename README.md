# hlabos
HomeLab OS - via Unbutu

Quickstart: ISO bauen & auf USB schreiben
Achtung: /dev/sdX muss durch dein Zielgerät ersetzt werden (z. B. /dev/sdb).
--force überspringt die Sicherheitsabfrage.
```bash
bash <(curl -fsSL https://raw.githubusercontent.com/makthu75/hlabos/main/build-ubuntu-homelab.sh) /dev/sdX --force
```

Nur ISO bauen (ohne auf USB zu schreiben):
```bash
bash <(curl -fsSL https://raw.githubusercontent.com/makthu75/hlabos/main/build-ubuntu-homelab.sh)
```
