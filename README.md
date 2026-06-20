# PostgreSQL self-host bằng Docker + backup sang server khác

Project này giúp bạn:

- chạy PostgreSQL trên Ubuntu bằng Docker Compose
- backup định kỳ bằng `pg_dump`
- đẩy file backup sang 1 server khác qua SSH password
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

### Cài Docker và công cụ backup

```bash
sudo apt update
sudo apt install -y docker.io docker-compose-plugin rsync openssh-client sshpass
sudo systemctl enable --now docker
```

### Copy project lên server

```bash
sudo mkdir -p /opt/postgre-self-host
sudo chown -R "$USER":"$USER" /opt/postgre-self-host
cd /opt/postgre-self-host
```

### Tạo file `.env`

```bash
cp .env.example .env
mkdir -p backups/local
chmod 600 .env
```

Sửa `.env` theo môi trường thật:

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

Lưu ý: nếu password có ký tự đặc biệt như `#`, `&`, `@`, hãy bọc bằng nháy đơn:

```env
POSTGRES_PASSWORD='4#xd&Tae@H5x3bD'
BACKUP_REMOTE_PASSWORD='4#xd&Tae@H5x3bD'
```

## 3. Chuẩn bị server backup

Server backup nên có `openssh-server` và `rsync`:

```bash
sudo apt update
sudo apt install -y openssh-server rsync
```

Tạo thư mục lưu file:

```bash
sudo mkdir -p /srv/postgres-backups/tech-blog
sudo chmod 755 /srv
sudo mkdir -p /srv/postgres-backups
sudo chmod 755 /srv/postgres-backups
sudo chmod 700 /srv/postgres-backups/tech-blog
```

Từ bất kỳ thư mục nào, bạn vào trực tiếp bằng đường dẫn tuyệt đối:

```bash
cd /srv/postgres-backups/tech-blog
```

Nếu bạn đang dùng `root` cho server backup, không cần tạo SSH key. Chỉ cần đảm bảo đăng nhập SSH bằng password đang bật.

Nếu SSH bằng `root` bị chặn, hãy tạo 1 user riêng để lưu backup rồi đổi `BACKUP_REMOTE_USER`.

## 4. Chạy PostgreSQL

```bash
docker compose up -d
docker compose ps
```

Kiểm tra:

```bash
docker exec pg-primary pg_isready -U tech_blog_user -d tech_blog_db
```

## 4.1. Lưu ý khi lên PostgreSQL 18

PostgreSQL 18 trên Docker official image đã đổi thư mục dữ liệu mặc định theo major version. Vì vậy file `docker-compose.yml` trong repo này:

- mount volume vào `/var/lib/postgresql` thay vì `/var/lib/postgresql/data`
- set rõ `PGDATA=/var/lib/postgresql/18/docker`
- dùng volume mới tên `postgres18_data` để tránh dính lại volume cũ của PostgreSQL 16

Nếu bạn đang chạy mới từ đầu thì không cần làm gì thêm.

Nếu bạn đang có data PostgreSQL 16 từ volume cũ, không nên chỉ đổi image rồi `docker compose up -d`. Cách an toàn là:

```bash
./scripts/backup.sh
docker compose down
docker volume ls
```

Sau đó dùng cách backup/restore để đưa dữ liệu sang instance PostgreSQL 18 mới, hoặc làm major upgrade riêng. Như vậy sẽ an toàn hơn việc dùng chung volume cũ.

Nếu bạn chỉ muốn chạy mới lại cho sạch sau khi `git pull`, dùng:

```bash
cd /opt/postgre-self-host
git pull origin main
docker compose down
docker compose up -d
docker compose ps
docker logs --tail 100 pg-primary
```

Nếu trên máy vẫn còn volume cũ `postgre-self-host_postgres_data` của PostgreSQL 16 thì cũng không sao, vì bản compose mới sẽ dùng volume `postgre-self-host_postgres18_data`.

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

## 5.1. Cách backup thủ công từng bước

Khi cần tạo backup ngay lập tức trên server chính, chạy:

```bash
cd /opt/postgre-self-host
./scripts/backup.sh
```

Sau khi chạy xong, kiểm tra danh sách backup đang có trên server backup:

```bash
./scripts/list_backups.sh
```

Nếu muốn kiểm tra trực tiếp trên server backup:

```bash
cd /srv/postgres-backups/tech-blog
ls -lah
```

Quy trình backup thủ công nên làm theo thứ tự:

1. Xác nhận PostgreSQL đang chạy.
2. Chạy `./scripts/backup.sh`.
3. Chạy `./scripts/list_backups.sh`.
4. Kiểm tra trên server backup đã có file `.dump`, `_globals.sql`, `.sha256`.

## 6. Bật backup định kỳ

```bash
sudo cp deploy/postgres-backup.service /etc/systemd/system/
sudo cp deploy/postgres-backup.timer /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now postgres-backup.timer
sudo systemctl list-timers | grep postgres-backup
```

Mặc định timer trong repo đang là backup mỗi ngày lúc `02:00` sáng.

Nếu muốn chạy backup ngay lập tức bằng systemd mà không đợi lịch:

```bash
sudo systemctl start postgres-backup.service
sudo systemctl status postgres-backup.service
```

Nếu bạn đã copy timer cũ từ trước đó, hãy sửa `/etc/systemd/system/postgres-backup.timer` thành:

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

Sau khi đổi sang daily, kiểm tra lịch:

```bash
sudo systemctl list-timers | grep postgres-backup
systemctl cat postgres-backup.timer
```

Nếu bạn vừa `git pull` bản mới trên VPS và muốn áp dụng timer daily ngay, chạy lại:

```bash
cd /opt/postgre-self-host
sudo cp deploy/postgres-backup.timer /etc/systemd/system/
sudo cp deploy/postgres-backup.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl restart postgres-backup.timer
sudo systemctl enable --now postgres-backup.timer
sudo systemctl list-timers | grep postgres-backup
```

## 7. Restore từ server backup

Liệt kê danh sách backup:

```bash
./scripts/list_backups.sh
```

Restore:

```bash
./scripts/restore.sh primary_tech_blog_db_20260620_020000.dump
```

Script sẽ:

- tải file backup từ server backup nếu local chưa có
- verify checksum
- restore roles từ file `_globals.sql`
- drop và tạo lại database
- restore dữ liệu từ file `.dump`

Nếu role đã tồn tại sẵn, bước restore `globals` có thể in ra lỗi `already exists`. Script sẽ bỏ qua các lỗi này và tiếp tục restore database.

## 7.1. Cách restore thủ công từng bước

Khi cần khôi phục database từ 1 file backup cụ thể, làm theo thứ tự:

1. Xác định file backup cần dùng bằng `./scripts/list_backups.sh`.
2. Đảm bảo bạn chấp nhận ghi đè toàn bộ database hiện tại.
3. Chạy lệnh restore với tên file dump.
4. Kiểm tra lại bảng hoặc dữ liệu sau restore.

Lệnh mẫu:

```bash
cd /opt/postgre-self-host
./scripts/list_backups.sh
./scripts/restore.sh primary_tech_blog_db_20260620_215653.dump
```

Kiểm tra lại sau restore:

```bash
docker exec -e PGPASSWORD='your_db_password' pg-primary \
  psql -U tech_blog_user -d tech_blog_db -c "\dt"

docker exec -e PGPASSWORD='your_db_password' pg-primary \
  psql -U tech_blog_user -d tech_blog_db -c "SELECT * FROM backup_test;"
```

Nếu bạn chỉ muốn test restore, nên:

1. Tạo 1 record mẫu.
2. Chạy backup.
3. Xóa record đó.
4. Chạy restore từ file backup vừa tạo.
5. Kiểm tra record đã quay lại hay chưa.

## 8. Lưu ý quan trọng

- Cách này phù hợp cho backup theo giờ/ngày và restore toàn DB.
- Mẫu hiện tại đang backup 1 database chính trong biến `POSTGRES_DB`.
- Dùng password để backup/restore là chạy được ngay, nhưng kém an toàn hơn SSH key.
- `BACKUP_REMOTE_PASSWORD` nằm trong `.env`, vì vậy nên giữ file này quyền `600` và không commit file `.env`.
- `restore.sh` sẽ ghi đè database hiện tại, nên chỉ chạy khi đã xác nhận downtime.
- Nếu cần point-in-time recovery, nên nâng cấp sang `pgBackRest` hoặc WAL archiving.
