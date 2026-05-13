# CycCloner2000

Masowy kloner dyskow po partycjach. Robisz jeden obraz dysku wzorcowego, przenosisz go na hosty klonujace i odtwarzasz rownolegle na wiele dyskow.

Obslugiwane uklady:

- Windows only
- Linux only
- Windows + Linux na jednym dysku

## Pliki

- `cyc-cloner.sh` - glowne narzedzie do clone/restore.
- `install.sh` - instalacja zaleznosci i tuning hosta klonujacego.

## Instalacja hosta klonujacego

```bash
sudo ./install.sh
```

Installer uzywa nieinteraktywnych pakietow GRUB (`grub-efi-amd64-bin`, `grub-pc-bin`), zeby live system nie pytal o docelowy dysk podczas instalacji. Jesli paczki sa juz zainstalowane i chcesz tylko poprawic limity systemowe:

```bash
sudo ./install.sh --no-packages
```

## Szybki workflow

1. Przygotuj dysk wzorcowy i upewnij sie, ze bootuje.
2. Zrob obraz:

```bash
sudo ./cyc-cloner.sh clone sda
```

Obrazy trafiaja domyslnie do `/root/images`.

3. Po podlaczeniu dyskow docelowych odswiez tablice urzadzen:

```bash
sudo partprobe
```

4. Przywroc obraz na jeden dysk:

```bash
sudo ./cyc-cloner.sh restore sda_20260513_120000 sdb
```

5. Przywroc obraz na wiele dyskow rownolegle:

```bash
sudo ./cyc-cloner.sh restore-many sda_20260513_120000 sdb sdc sdd sde sdf
```

Mozesz podac pelna sciezke do obrazu zamiast samej nazwy katalogu.

## Boot po klonowaniu

Skrypt zapisuje w metadanych typ obrazu (`WINDOWS`, `LINUX`, `MIXED`) oraz tryb bootowania (`UEFI` albo `BIOS`). Po restore:

- Windows UEFI: sprawdza `EFI/Microsoft/Boot/bootmgfw.efi` i tworzy fallback `EFI/BOOT/BOOTX64.EFI`.
- Linux UEFI: instaluje GRUB z `--removable --no-nvram`.
- Windows + Linux: instaluje GRUB, wlacza `os-prober` i zachowuje Windows Boot Manager.
- BIOS/MBR: odtwarza boot code MBR z obrazu.

Domyslnie GPT GUID-y sa zachowywane, bo Windows BCD i Linux `/etc/fstab` moga sie na nich opierac. Jezeli potrzebujesz losowac GPT GUID-y po restore:

```bash
sudo RANDOMIZE_GPT_GUIDS=true ./cyc-cloner.sh restore-many obraz sdb sdc sdd
```

Wpisy EFI NVRAM sa domyslnie pomijane, bo przy masowym klonowaniu zapisalyby sie w komputerze klonujacym, nie w docelowych PC. Jezeli testujesz boot na tej samej maszynie:

```bash
sudo CREATE_EFI_NVRAM_ENTRY=true ./cyc-cloner.sh restore obraz sdb
```

## Komendy pomocnicze

```bash
sudo ./cyc-cloner.sh list-disks
sudo ./cyc-cloner.sh list-backups
sudo ./cyc-cloner.sh menu
sudo ./cyc-cloner.sh --help
```
