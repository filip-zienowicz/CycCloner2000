# CycCloner2000 - Zaawansowane Narzędzie do Klonowania Dysków

Profesjonalne narzędzie do klonowania dysków na Ubuntu, działające na poziomie partycji, obsługujące Windows, Linux oraz konfiguracje mieszane.

## Funkcje

- **Klonowanie na poziomie partycji** - zapisuje tylko zajęte dane, nie cały dysk
- **Obsługa wielu systemów plików**: ext2/3/4, NTFS, FAT32, swap
- **Automatyczna instalacja GRUB** - dla BIOS i UEFI
- **Równoległe klonowanie** - jednoczesne przywracanie na 8+ dysków
- **Kompresja** - backup z wykorzystaniem pigz (równoległy gzip)
- **Bootowalne obrazy** - pełna kopia 1:1 z bootloaderem

## Wymagania

### Instalacja zależności na Ubuntu:

```bash
sudo apt-get update
sudo apt-get install -y parted partclone pigz pv gdisk lsblk util-linux
```

### Dodatkowe pakiety partclone:

```bash
sudo apt-get install -y partclone
```

## Konfiguracja

Edytuj zmienne na początku skryptu `cyc-cloner.sh`:

```bash
BACKUP_DIR="/mnt/backups/disk-images"  # Ścieżka do backupów
LOG_FILE="/var/log/cyc-cloner.log"     # Plik logów
PARALLEL_JOBS=8                        # Liczba równoległych zadań
COMPRESSION="pigz"                      # Kompresja: pigz, gzip, lub none
```

## Użycie

### 1. Nadaj uprawnienia wykonywania:

```bash
chmod +x cyc-cloner.sh
```

### 2. Uruchom z uprawnieniami root:

```bash
sudo ./cyc-cloner.sh
```

### 3. Menu interaktywne:

```
======================================
    CycCloner2000 - Disk Cloning Tool
======================================

1) Clone disk to files
2) Restore to single disk
3) Restore to multiple disks (parallel)
4) List available disks
5) List available backups
6) Exit
```

## Scenariusze użycia

### Scenariusz 1: Backup dysku

1. Wybierz opcję `1) Clone disk to files`
2. Wybierz dysk źródłowy (np. `sda`)
3. Potwierdź operację
4. Backup zostanie zapisany w `$BACKUP_DIR/sda_YYYYMMDD_HHMMSS/`

**Co się zapisuje:**
- Tabela partycji (GPT/MBR)
- Wszystkie partycje jako skompresowane obrazy
- Metadane (typ bootu, liczba partycji, daty)
- Informacje o systemach plików

### Scenariusz 2: Przywracanie na jeden dysk

1. Wybierz opcję `2) Restore to single disk`
2. Wybierz backup z listy
3. Wybierz dysk docelowy (np. `sdb`)
4. Potwierdź wpisując `YES`
5. Dysk zostanie sklonowany 1:1 z automatyczną instalacją GRUB

### Scenariusz 3: Klonowanie na 8 dysków równolegle

1. Wybierz opcję `3) Restore to multiple disks (parallel)`
2. Wybierz backup z listy
3. Podaj dyski docelowe oddzielone spacjami (np. `sdb sdc sdd sde sdf sdg sdh sdi`)
4. Potwierdź wpisując `YES`
5. Wszystkie dyski będą klonowane równolegle

## Struktura backupu

```
/mnt/backups/disk-images/sda_20260105_143022/
├── partition-table.sgdisk      # Backup GPT
├── partition-table.sfdisk      # Backup MBR
├── disk-geometry.txt           # Geometria dysku
├── metadata.txt                # Metadane backupu
├── partition_1.img.gz          # Partycja 1 (skompresowana)
├── partition_1.fstype          # Typ systemu plików
├── partition_1.info            # Informacje o partycji
├── partition_2.img.gz          # Partycja 2
├── partition_2.fstype
└── partition_2.info
```

## Obsługiwane konfiguracje

### Windows + Linux (Dual Boot)

Dysk z:
- EFI System Partition (FAT32)
- Windows (NTFS)
- Linux root (ext4)
- Linux swap

**Wynik:** Pełna bootowalna kopia, GRUB wykryje oba systemy.

### Tylko Linux

Dysk z:
- /boot (ext4)
- / (ext4)
- /home (ext4)
- swap

**Wynik:** Bootowalna kopia z GRUB.

### Tylko Windows

Dysk z:
- EFI/System Reserved
- Windows (NTFS)

**Wynik:** Bootowalna kopia Windows (wymaga dodatkowego `bootmgr` w UEFI).

### Mieszane partycje

40% Windows, 40% Linux, 20% wolne miejsce

**Wynik:** Wszystkie partycje zostają sklonowane, wolne miejsce pozostaje wolne.

## Jak to działa

### Backup (Clone to Files)

1. **Skanowanie dysku**: Wykrywa wszystkie partycje
2. **Backup tabeli partycji**: Zapisuje GPT/MBR
3. **Dla każdej partycji**:
   - Wykrywa typ systemu plików (ext4, NTFS, FAT32, etc.)
   - Używa `partclone` do skopiowania tylko zajętych bloków
   - Kompresuje obraz używając `pigz` (parallel gzip)
   - Zapisuje metadane
4. **Zapisuje metadane całego dysku**

### Restore (Files to Disk)

1. **Czyszczenie dysku docelowego**: Usuwa starą tabelę partycji
2. **Przywracanie tabeli partycji**: Odtwarza strukturę GPT/MBR
3. **Dla każdej partycji**:
   - Dekompresuje obraz
   - Używa `partclone` do przywrócenia danych
   - Odtwarza UUIDs i metadane
4. **Instalacja GRUB**:
   - Wykrywa tryb boot (BIOS/UEFI)
   - Instaluje GRUB na dysk
   - Generuje konfigurację GRUB
   - Wykrywa wszystkie systemy operacyjne

### Parallel Restore (Multiple Disks)

Uruchamia proces restore dla każdego dysku w osobnym procesie, co pozwala na jednoczesne klonowanie wielu dysków.

## Logi

Wszystkie operacje są logowane do:
- Konsola (kolorowe output)
- Plik: `/var/log/cyc-cloner.log`

Format logów:
```
[2026-01-05 14:30:22] [INFO] Starting disk clone...
[2026-01-05 14:30:25] [SUCCESS] Partition table backed up
[2026-01-05 14:31:10] [WARNING] Partition mounted, unmounting...
[2026-01-05 14:45:00] [SUCCESS] Disk clone completed
```

## Bezpieczeństwo

- **Wymaga uprawnień root** - sprawdza przed każdą operacją
- **Potwierdza niszczące operacje** - wymaga wpisania `YES` przed restore
- **Sprawdza zamontowane partycje** - zapobiega zapisowi na zamontowane dyski
- **Weryfikuje istnienie dysków** - sprawdza `/dev/sdX` przed operacją

## Rozwiązywanie problemów

### Problem: "Missing dependencies"

```bash
sudo apt-get install parted partclone pigz pv gdisk
```

### Problem: "Partition is mounted"

```bash
sudo umount /dev/sdX1
sudo umount /dev/sdX2
# lub
sudo swapoff /dev/sdX3  # dla swap
```

### Problem: "GRUB installation failed"

- Sprawdź czy dysk ma poprawną tabelę partycji
- Dla UEFI: upewnij się że istnieje partycja EFI (FAT32, typ `EF00`)
- Dla BIOS: upewnij się że jest wolne miejsce na początku dysku (1-2 MB)

### Problem: Backup zajmuje za dużo miejsca

- Kompresja `pigz` jest domyślnie włączona
- Partclone zapisuje tylko zajęte bloki
- Sprawdź czy masz wystarczająco miejsca w `$BACKUP_DIR`

## Przykłady

### Backup dysku systemowego:

```bash
sudo ./cyc-cloner.sh
# Wybierz opcję 1
# Wpisz: sda
# Potwierdź: yes
```

### Przywrócenie na 3 dyski jednocześnie:

```bash
sudo ./cyc-cloner.sh
# Wybierz opcję 3
# Wpisz nazwę backupu: sda_20260105_143022
# Wpisz dyski: sdb sdc sdd
# Potwierdź: YES
```

### Lista dostępnych backupów:

```bash
sudo ./cyc-cloner.sh
# Wybierz opcję 5
```

## Wydajność

- **Backup**: ~50-100 MB/s (zależnie od dysku i procesora)
- **Restore**: ~50-150 MB/s
- **Parallel Restore (8 dysków)**: ~8x szybciej niż sekwencyjnie
- **Kompresja**: pigz wykorzystuje wszystkie rdzenie CPU

## Testowane konfiguracje

- Ubuntu 20.04 LTS / 22.04 LTS / 24.04 LTS
- Windows 10 / Windows 11
- Dual boot Windows + Ubuntu
- Multi-boot (Windows + 2x Linux)
- BIOS i UEFI
- GPT i MBR
- Dyski od 128GB do 4TB

## Licencja

Open source - używaj jak chcesz.

## Autor

CycCloner2000 - Stworzony dla profesjonalnego klonowania dysków.

## Uwagi końcowe

- **Zawsze testuj restore na dysku testowym przed produkcją**
- **Upewnij się że masz wystarczająco miejsca w $BACKUP_DIR**
- **Dla dysków >1TB, backup może zająć kilka godzin**
- **Równoległe klonowanie może obciążyć I/O systemu**
- **Zalecane jest używanie dedykowanego dysku dla backupów**
