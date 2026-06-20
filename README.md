# PostgreSQL self-host bang Docker + backup sang server khac

Project nay giup ban:

- chay PostgreSQL tren Ubuntu bang Docker Compose
- backup dinh ky bang `pg_dump`
- day file backup sang 1 server khac qua SSH password
- restore nguoc tu file backup khi can

## 1. Cau truc

- `docker-compose.yml`: chay PostgreSQL
- `.env.example`: bien moi truong mau
- `scripts/backup.sh`: tao backup va copy sang server backup
- `scripts/list_backups.sh`: liet ke backup dang co tren server backup
- `scripts/restore.sh`: tai file backup ve va restore
- `deploy/postgres-backup.service`: service `systemd`
- `deploy/postgres-backup.timer`: timer `systemd`

## 2. Chuan bi tren Ubuntu chinh

### Cai Docker va cong cu backup

```bash
sudo apt update
sudo apt install -y docker.io docker-compose-plugin rsync openssh-client sshpass
sudo systemctl enable --now docker
```

### Copy project len server

```bash
sudo mkdir -p /opt/postgre-self-host
sudo chown -R "$USER":"$USER" /opt/postgre-self-host
cd /opt/postgre-self-host
```

### Tao file `.env`

```bash
cp .env.example .env
mkdir -p backups/local
chmod 600 .env
```

Sua `.env` theo moi truong that:

```env
POSTGRES_VERSION=18
POSTGRES_CONTAINER_NAME=pg-primary
POSTGRES_PORT=5432
POSTGRES_DB=tech_blog_db
POSTGRES_USER=tech_blog_user
POSTGRES_PASSWORD=strong_db_password_here
TZ=Asia/Bangkok

BACKUP_LOCAL_DIR=./backups/local
BACKUP_FILENAME_PREFIX=primary
BACKUP_KEEP_LOCAL_DAYS=2
BACKUP_KEEP_REMOTE_DAYS=14

BACKUP_REMOTE_HOST=103.72.56.221
BACKUP_REMOTE_PORT=22
BACKUP_REMOTE_USER=root
BACKUP_REMOTE_PASSWORD=strong_remote_password_here
BACKUP_REMOTE_DIR=/srv/postgres-backups/tech-blog
```

## 3. Chuan bi server backup

Server backup nen co `openssh-server` va `rsync`:

```bash
sudo apt update
sudo apt install -y openssh-server rsync
```

Tao thu muc luu file:

```bash
sudo mkdir -p /srv/postgres-backups/tech-blog
sudo chmod 755 /srv
sudo mkdir -p /srv/postgres-backups
sudo chmod 755 /srv/postgres-backups
sudo chmod 700 /srv/postgres-backups/tech-blog
```

Tu bat ky thu muc nao, ban vao truc tiep bang duong dan tuyet doi:

```bash
cd /srv/postgres-backups/tech-blog
```

Neu ban dang dung root cho server backup, khong can tao SSH key. Chi can dam bao dang nhap SSH bang password dang bat.

Neu SSH bang `root` bi chan, hay tao 1 user rieng de luu backup roi doi `BACKUP_REMOTE_USER`.

## 4. Chay PostgreSQL

```bash
docker compose up -d
docker compose ps
```

Kiem tra:

```bash
docker exec pg-primary pg_isready -U tech_blog_user -d tech_blog_db
```

## 4.1. Luu y khi len PostgreSQL 18

PostgreSQL 18 tren Docker official image da doi thu muc du lieu mac dinh theo major version. Vi vay file `docker-compose.yml` trong repo nay:

- mount volume vao `/var/lib/postgresql` thay vi `/var/lib/postgresql/data`
- set ro `PGDATA=/var/lib/postgresql/18/docker`
- dung volume moi ten `postgres18_data` de tranh dinh lai volume cu cua PostgreSQL 16

Neu ban dang chay moi tu dau thi khong can lam gi them.

Neu ban dang co data PostgreSQL 16 tu volume cu, khong nen chi doi image roi `docker compose up -d`. Cach an toan la:

```bash
./scripts/backup.sh
docker compose down
docker volume ls
```

Sau do dung cach backup/restore de dua du lieu sang instance PostgreSQL 18 moi, hoac lam major upgrade rieng. Nhu vay se an toan hon viec dung chung volume cu.

Neu ban chi muon chay moi lai cho sach sau khi `git pull`, dung:

```bash
cd /opt/postgre-self-host
git pull origin main
docker compose down
docker compose up -d
docker compose ps
docker logs --tail 100 pg-primary
```

Neu tren may van con volume cu `postgre-self-host_postgres_data` cua PostgreSQL 16 thi cung khong sao, vi ban compose moi se dung volume `postgre-self-host_postgres18_data`.

## 5. Chay backup thu

```bash
chmod +x scripts/*.sh
./scripts/backup.sh
./scripts/list_backups.sh
```

Sau khi chay xong, server backup se co:

- file `.dump` de restore database
- file `_globals.sql` cho roles/quyen o muc cluster
- file `.sha256` de kiem tra integrity

## 6. Bat backup dinh ky

```bash
sudo cp deploy/postgres-backup.service /etc/systemd/system/
sudo cp deploy/postgres-backup.timer /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now postgres-backup.timer
sudo systemctl list-timers | grep postgres-backup
```

Mac dinh timer dang la `hourly`.

Neu muon backup moi ngay luc 02:00 sang, sua `/etc/systemd/system/postgres-backup.timer`:

```ini
[Timer]
OnCalendar=*-*-* 02:00:00
Persistent=true
Unit=postgres-backup.service
```

Sau do reload:

```bash
sudo systemctl daemon-reload
sudo systemctl restart postgres-backup.timer
```

## 7. Restore tu server backup

Liet ke danh sach backup:

```bash
./scripts/list_backups.sh
```

Restore:

```bash
./scripts/restore.sh primary_tech_blog_db_20260620_020000.dump
```

Script se:

- tai file backup tu server backup neu local chua co
- verify checksum
- restore roles tu file `_globals.sql`
- drop va tao lai database
- restore du lieu tu file `.dump`

Neu role da ton tai san, buoc restore `globals` co the in ra loi `already exists`. Script se bo qua cac loi nay va tiep tuc restore database.

## 8. Luu y quan trong

- Cach nay phu hop cho backup theo gio/ngay va restore toan DB.
- Mau hien tai dang backup 1 database chinh trong bien `POSTGRES_DB`.
- Dung password de backup/restore la chay duoc ngay, nhung kem an toan hon SSH key.
- `BACKUP_REMOTE_PASSWORD` nam trong `.env`, vi vay nen giu file nay quyen `600` va khong commit file `.env`.
- `restore.sh` se ghi de database hien tai, nen chi chay khi da xac nhan downtime.
- Neu can point-in-time recovery, nen nang cap sang `pgBackRest` hoac WAL archiving.
