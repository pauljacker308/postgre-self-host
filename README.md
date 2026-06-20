# PostgreSQL self-host bằng Docker + backup sang server khác

Project này giúp bạn:

- chạy PostgreSQL trên Ubuntu bằng Docker Compose
- backup định kỳ bằng `pg_dump`
- đẩy file backup sang 1 server khác qua SSH
- restore ngược từ file backup khi cần

## 1. Cấu trúc

- `docker-compose.yml`: chạy PostgreSQL
- `.env.example`: biến môi trường mẫu
- `scripts/backup.sh`: tạo backup và copy sang server backup
- `scripts/list_backups.sh`: liệt kê backup đang có trên server backup
- `scripts/restore.sh`: tải file backup về và restore
- `deploy/postgres-backup.service`: service `systemd`
- `deploy/postgres-backup.timer`: timer `systemd`

## 2. Chuẩn bị trên Ubuntu chính

### Cài Docker

```bash
sudo apt update
sudo apt install -y docker.io docker-compose-plugin rsync openssh-client
sudo systemctl enable --now docker
```

### Copy project lên server

Ví dụ:

```bash
sudo mkdir -p /opt/postgre-self-host
sudo chown -R "$USER":"$USER" /opt/postgre-self-host
cd /opt/postgre-self-host
```

### Tạo file `.env`

```bash
cp .env.example .env
mkdir -p ssh backups/local
chmod 700 ssh
```

Sửa `.env` theo môi trường thật:

```env
POSTGRES_VERSION=16
POSTGRES_CONTAINER_NAME=pg-primary
POSTGRES_PORT=5432
POSTGRES_DB=app_db
POSTGRES_USER=app_user
POSTGRES_PASSWORD=strong_password_here
TZ=Asia/Bangkok

BACKUP_LOCAL_DIR=./backups/local
BACKUP_FILENAME_PREFIX=primary
BACKUP_KEEP_LOCAL_DAYS=2
BACKUP_KEEP_REMOTE_DAYS=14

BACKUP_REMOTE_HOST=10.10.10.20
BACKUP_REMOTE_PORT=22
BACKUP_REMOTE_USER=backupuser
BACKUP_REMOTE_DIR=/srv/postgres-backups/primary
BACKUP_SSH_KEY=./ssh/backup_ed25519
```

## 3. Chuẩn bị server backup

Server backup nên có `openssh-server` và `rsync`:

```bash
sudo apt update
sudo apt install -y openssh-server rsync
```

Sau đó tạo thư mục lưu file:

```bash
sudo mkdir -p /srv/postgres-backups/primary
sudo chown -R backupuser:backupuser /srv/postgres-backups/primary
```

Tạo SSH key ở server chính:

```bash
ssh-keygen -t ed25519 -f ./ssh/backup_ed25519 -N ""
chmod 600 ./ssh/backup_ed25519
ssh-copy-id -i ./ssh/backup_ed25519.pub backupuser@10.10.10.20
```

Test SSH:

```bash
ssh -i ./ssh/backup_ed25519 backupuser@10.10.10.20
```

## 4. Chạy PostgreSQL

```bash
docker compose up -d
docker compose ps
```

Kiểm tra:

```bash
docker exec pg-primary pg_isready -U app_user -d app_db
```

## 5. Chạy backup thử

```bash
chmod +x scripts/*.sh
./scripts/backup.sh
./scripts/list_backups.sh
```

Sau khi chạy xong, server backup sẽ có:

- file `.dump` để restore database
- file `_globals.sql` cho roles/quyền ở mức cluster
- file `.sha256` để kiểm tra integrity

## 6. Bật backup định kỳ

Copy file `systemd`:

```bash
sudo cp deploy/postgres-backup.service /etc/systemd/system/
sudo cp deploy/postgres-backup.timer /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now postgres-backup.timer
sudo systemctl list-timers | grep postgres-backup
```

Mặc định timer đang là `hourly`.

Nếu muốn backup mỗi ngày lúc 02:00 sáng, sửa `/etc/systemd/system/postgres-backup.timer`:

```ini
[Timer]
OnCalendar=*-*-* 02:00:00
Persistent=true
Unit=postgres-backup.service
```

Sau đó reload:

```bash
sudo systemctl daemon-reload
sudo systemctl restart postgres-backup.timer
```

## 7. Restore từ server backup

Liệt kê danh sách backup:

```bash
./scripts/list_backups.sh
```

Restore:

```bash
./scripts/restore.sh primary_app_db_20260620_020000.dump
```

Script sẽ:

- tải file backup từ server backup nếu local chưa có
- verify checksum
- restore roles từ file `_globals.sql`
- drop và tạo lại database
- restore dữ liệu từ file `.dump`

## 8. Lưu ý quan trọng

- Cách này phù hợp cho backup theo giờ/ngày và restore toàn DB.
- Mẫu hiện tại đang backup 1 database chính trong biến `POSTGRES_DB`.
- Nếu bạn cần point-in-time recovery, nên nâng cấp sang `pgBackRest` hoặc WAL archiving.
- `restore.sh` sẽ ghi đè database hiện tại, nên chỉ chạy khi đã xác nhận downtime.
- Nên giới hạn firewall chỉ cho phép app hoặc IP cần thiết truy cập cổng `5432`.
