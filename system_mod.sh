#!/bin/bash
# fix_system_limits.sh - Naprawia limity systemowe dla Linuxa klonującego

echo "=== Naprawa limitów systemowych ==="

# Backup obecnych konfiguracji
echo "[1/5] Tworzę backupy..."
cp /etc/security/limits.conf /etc/security/limits.conf.backup.$(date +%Y%m%d)
cp /etc/systemd/logind.conf /etc/systemd/logind.conf.backup.$(date +%Y%m%d)
cp /etc/sysctl.conf /etc/sysctl.conf.backup.$(date +%Y%m%d)

# Konfiguracja limits.conf
echo "[2/5] Konfiguruję /etc/security/limits.conf..."
cat >> /etc/security/limits.conf << 'EOF'

# Dodane przez fix_system_limits.sh
*    soft    nproc     8192
*    hard    nproc     16384
*    soft    nofile    8192
*    hard    nofile    16384
root soft    nproc     unlimited
root hard    nproc     unlimited
root soft    nofile    unlimited
root hard    nofile    unlimited
EOF

# Konfiguracja systemd-logind
echo "[3/5] Konfiguruję /etc/systemd/logind.conf..."
sed -i 's/#UserTasksMax=.*/UserTasksMax=16384/' /etc/systemd/logind.conf
if ! grep -q "^UserTasksMax" /etc/systemd/logind.conf; then
    echo "UserTasksMax=16384" >> /etc/systemd/logind.conf
fi

# Konfiguracja sysctl
echo "[4/5] Konfiguruję /etc/sysctl.conf..."
cat >> /etc/sysctl.conf << 'EOF'

# Dodane przez fix_system_limits.sh
kernel.pid_max = 65536
kernel.threads-max = 65536
vm.max_map_count = 262144
EOF

# Zastosuj zmiany
echo "[5/5] Stosuję zmiany..."
sysctl -p

systemctl restart systemd-logind

echo ""
echo "=== GOTOWE ==="
echo "Obecne limity:"
echo "- Max procesów na użytkownika: 8192 (soft) / 16384 (hard)"
echo "- Max otwartych plików: 8192 (soft) / 16384 (hard)"
echo "- Max PID systemowy: 65536"
echo ""
echo "Backupy zapisane z rozszerzeniem .backup.$(date +%Y%m%d)"
echo ""
echo "UWAGA: Wyloguj się i zaloguj ponownie aby zmiany zadziałały!"
echo "       Lub zrestartuj system: reboot"