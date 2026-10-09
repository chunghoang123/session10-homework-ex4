# EX4 — Custom Bridge Network + Named Volume + DNS + Persistence

## 1. Kiến trúc

```text
                    +----------------------------+
                    |   custom bridge: app-net   |
                    |   subnet: 172.19.0.0/16    |
                    |   embedded DNS: 127.0.0.11 |
                    +-------------+--------------+
                                  |
              +-------------------+-------------------+
              |                                       |
   +--------------------+                 +--------------------+
   | app-container      |                 | db-server            |
   | image: hw-backend  |  DNS name       | image: postgres:     |
   |   :v1 (ex2 build)  |  "db-server"    |   15-alpine          |
   | env: DB_HOST=      |  ------->       | env: POSTGRES_DB=    |
   |   db-server        |  172.19.0.2     |   appdb, USER=       |
   |   PORT=3000        |                 |   appuser            |
   +----------+---------+                 +---------+----------+
              |                                     |
              |                          named volume db-data
              |                          mount: /var/lib/postgresql/data
              |                          (dữ liệu sống ngoài vòng đời container)
              +-------------------------------------+
```

| Thành phần | Giá trị thực tế (đã kiểm chứng) |
|---|---|
| Network | `app-net`, driver `bridge`, subnet `172.19.0.0/16`, gateway `172.19.0.1` |
| db-server | IP `172.19.0.2/16` trên `app-net` |
| app-container | IP `172.19.0.3/16` trên `app-net`, image `hw-backend:v1` (build từ `../ex2`), env `DB_HOST=db-server` |
| Volume | `db-data` (driver `local`), mountpoint host `/var/lib/docker/volumes/db-data/_data`, mount vào `/var/lib/postgresql/data` |

## 2. Giải thích khái niệm

### 2.1. Custom bridge network + DNS nhúng

- Mặc định Docker có network `bridge`, nhưng container trên đó **không phân giải được tên nhau** (phải dùng `--link` cũ, hoặc IP cứng).
- `docker network create app-net` tạo một **user-defined bridge** riêng. Docker tự bật **embedded DNS server (127.0.0.11)** cho network này: mỗi container được cấp DNS theo tên, nên `ping db-server` từ `app-container` phân giải ra `172.19.0.2`.
- Kiểm chứng thực tế trong bài:
  - `docker exec app-container ping -c 2 db-server` → `2 packets transmitted, 2 received, 0% loss`.
  - `docker exec app-container getent hosts db-server` → `172.19.0.2 db-server`.
  - `docker network inspect app-net` cho thấy cả 2 container cùng subnet `172.19.0.0/16` (xem output mục 4).
- Cô lập: container ngoài `app-net` không thấy `db-server` bằng tên; muốn giao tiếp phải `--network app-net` (join显式).

### 2.2. Named volume (`db-data`)

- `docker volume create db-data` tạo volume có tên do Docker quản lý (khác bind-mount trỏ thư mục host cụ thể và khác anonymous volume tự sinh tên hash).
- Mount `-v db-data:/var/lib/postgresql/data`: mọi file dữ liệu Postgres (PGDATA) ghi xuống volume trên host, **không nằm trong writable layer của container**.
- Hệ quả: `docker rm -f db-server` chỉ xóa container + layer ghi, **volume còn nguyên**. Container mới mount cùng volume đọc lại được dữ liệu cũ → mục 3 chứng minh điều này.

## 3. Các bước persistence test + output thực tế

Thực thi trên Windows PowerShell bằng `docker` CLI tương đương (không dùng `sudo`, không dùng `grep`, dùng `Select-String`). Thứ tự đúng như `commands.sh`.

**Bước 0 — Dọn tên trùng (idempotent):**

```powershell
docker rm -f db-server app-container
```

**Bước 1 — Network (kiểm tra tồn tại trước):**

```powershell
docker network inspect app-net
docker network create app-net
docker network ls | Select-String "app-net|NETWORK"
```

Output thực tế:

```text
cec78c8bdb23479c56199b60411674f882acb8cc28a4588390e57f418f657688
NETWORK ID     NAME      DRIVER    SCOPE
cec78c8bdb23   app-net   bridge    local
```

**Bước 2 — Volume:**

```powershell
docker volume create db-data
docker volume ls | Select-String "db-data|VOLUME"
```

```text
db-data
DRIVER    VOLUME NAME
local     db-data
```

**Bước 3 — Chạy Postgres + chờ ready:**

```powershell
docker run -d --name db-server --network app-net `
  -v db-data:/var/lib/postgresql/data `
  -e POSTGRES_DB=appdb -e POSTGRES_USER=appuser -e POSTGRES_PASSWORD=apppass123 `
  postgres:15-alpine
docker exec db-server pg_isready -U appuser -d appdb
```

```text
/var/run/postgresql:5432 - accepting connections
```

**Bước 4 — Backend (`hw-backend:v1` build từ ex2, ưu tiên theo đề):**

```powershell
docker build -t hw-backend:v1 "C:\...\session10\ex2"
docker run -d --name app-container --network app-net `
  -e DB_HOST=db-server -e PORT=3000 hw-backend:v1
docker exec app-container env | Select-String "DB_HOST|PORT"
```

```text
DB_HOST=db-server
PORT=3000
```

> Ghi chú fallback trong `commands.sh`: nếu `docker image inspect hw-backend:v1` thất bại và không có `../ex2/Dockerfile`, script tự `docker pull node:18-alpine` và chạy `... node:18-alpine sleep infinity` làm backend demo giữ DNS test.

**Bước 5 — Test DNS:**

```powershell
docker exec app-container ping -c 2 db-server
docker exec app-container getent hosts db-server
```

```text
PING db-server (172.19.0.2): 56 data bytes
64 bytes from 172.19.0.2: seq=0 ttl=64 time=0.470 ms
64 bytes from 172.19.0.2: seq=1 ttl=64 time=0.068 ms
--- db-server ping statistics ---
2 packets transmitted, 2 packets received, 0% packet loss
round-trip min/avg/max = 0.068/0.269/0.470 ms

172.19.0.2        db-server  db-server
```

Nếu image backend không có `ping`, `commands.sh` tự fallback `getent hosts` rồi `nslookup`.

**Bước 6 — Ghi dữ liệu lần 1:**

```powershell
docker exec db-server psql -U appuser -d appdb -c "CREATE TABLE IF NOT EXISTS demo(id SERIAL PRIMARY KEY, val TEXT);"
docker exec db-server psql -U appuser -d appdb -c "INSERT INTO demo(val) VALUES('hello-persist');"
docker exec db-server psql -U appuser -d appdb -c "SELECT * FROM demo;"
```

```text
CREATE TABLE
INSERT 0 1
 id |      val
----+---------------
  1 | hello-persist
(1 row)
```

**Bước 7 — Xóa container, tạo lại cùng volume, đọc lại:**

```powershell
docker rm -f db-server
docker run -d --name db-server --network app-net `
  -v db-data:/var/lib/postgresql/data `
  -e POSTGRES_DB=appdb -e POSTGRES_USER=appuser -e POSTGRES_PASSWORD=apppass123 `
  postgres:15-alpine
Start-Sleep -Seconds 8
docker exec db-server pg_isready -U appuser -d appdb
docker exec db-server psql -U appuser -d appdb -c "SELECT * FROM demo;"
```

```text
db-server
4f8b43541f96ea5f97e98aaf773dc055eb50f2a73952ab02632f3a9da44830c8
/var/run/postgresql:5432 - accepting connections
 id |      val
----+---------------
  1 | hello-persist
(1 row)
```

→ Kết luận: bản ghi `hello-persist` **vẫn còn sau khi xóa + tạo lại container** → persistence qua named volume hoạt động.

## 4. Kết quả kiểm chứng tổng hợp

```powershell
docker network ls
docker network inspect app-net
docker volume ls
docker volume inspect db-data
docker ps --format "{{.Names}} | {{.Image}} | {{.Status}} | {{.Networks}}"
```

```text
NETWORK ID     NAME                  DRIVER    SCOPE
cec78c8bdb23   app-net               bridge    local
199d4d07f8c1   bridge                bridge    local
82d68f3850af   host                  host      local
406965a29cfe   none                  null      local

"Subnet": "172.19.0.0/16", "Gateway": "172.19.0.1"
"db-server":     IPv4Address 172.19.0.2/16
"app-container": IPv4Address 172.19.0.3/16

DRIVER    VOLUME NAME
local     db-data
"Mountpoint": "/var/lib/docker/volumes/db-data/_data", "Name": "db-data"

db-server     | postgres:15-alpine | Up 15 seconds | app-net
app-container | hw-backend:v1      | Up 32 seconds | app-net
```

## 5. File `commands.sh` — tính idempotent

- Biến môi trường khai báo tập trung đầu file: `NETWORK`, `VOLUME`, `DB_CONTAINER`, `APP_CONTAINER`, `POSTGRES_IMAGE`, `BACKEND_IMAGE`, `FALLBACK_IMAGE`, `POSTGRES_DB/USER/PASSWORD`.
- Idempotent (chạy lại an toàn):
  - `docker rm -f ... || true` dọn tên trùng trước khi chạy.
  - `docker network inspect` kiểm tra tồn tại trước khi `create`.
  - `CREATE TABLE IF NOT EXISTS` nên ghi lại không lỗi trùng bảng.
- Cấp quyền thực thi (Linux, chạy 1 lần đầu): `chmod +x commands.sh`, sau đó `./commands.sh`.
- Script giữ lại container sau khi xong để giảng viên kiểm tra; câu lệnh dọn dẹp in ở cuối output.

## 6. Dọn dẹp thủ công (khi không cần nữa)

```powershell
docker rm -f db-server app-container
docker network rm app-net
docker volume rm db-data
```
