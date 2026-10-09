#!/bin/bash
# ==============================================================================
# EX4 - Custom bridge network + Named volume + DNS + Persistence test
# ------------------------------------------------------------------------------
# Cách chạy trên Linux:
#   chmod +x commands.sh   # cấp quyền thực thi (chỉ cần chạy 1 lần đầu)
#   ./commands.sh          # thực thi script
#
# Trên Windows PowerShell: không chạy trực tiếp file .sh, mà chạy từng lệnh
# docker tương đương (xem README.md mục "Các bước thực hiện").
# ==============================================================================
set -euo pipefail

# ---------------- Biến môi trường rõ ràng ----------------
NETWORK="app-net"
VOLUME="db-data"
DB_CONTAINER="db-server"
APP_CONTAINER="app-container"
POSTGRES_IMAGE="postgres:15-alpine"
BACKEND_IMAGE="hw-backend:v1"
FALLBACK_IMAGE="node:18-alpine"
EX2_DIR="../ex2"
POSTGRES_DB="appdb"
POSTGRES_USER="appuser"
POSTGRES_PASSWORD="apppass123"

echo "==> [0/7] Dọn dẹp tên container trùng (idempotent, an toàn chạy lại)"
docker rm -f "${DB_CONTAINER}" "${APP_CONTAINER}" 2>/dev/null || true

echo "==> [1/7] Tạo custom bridge network '${NETWORK}' (kiểm tra tồn tại trước)"
if docker network inspect "${NETWORK}" >/dev/null 2>&1; then
  echo "Network '${NETWORK}' đã tồn tại, bỏ qua tạo mới."
else
  docker network create "${NETWORK}"
fi

echo "==> [2/7] Tạo named volume '${VOLUME}'"
docker volume create "${VOLUME}"

echo "==> [3/7] Chạy container Postgres '${DB_CONTAINER}'"
docker run -d \
  --name "${DB_CONTAINER}" \
  --network "${NETWORK}" \
  -v "${VOLUME}:/var/lib/postgresql/data" \
  -e POSTGRES_DB="${POSTGRES_DB}" \
  -e POSTGRES_USER="${POSTGRES_USER}" \
  -e POSTGRES_PASSWORD="${POSTGRES_PASSWORD}" \
  "${POSTGRES_IMAGE}"

echo "==> Chờ Postgres sẵn sàng (pg_isready, tối đa ~30s)"
for i in $(seq 1 30); do
  if docker exec "${DB_CONTAINER}" pg_isready -U "${POSTGRES_USER}" -d "${POSTGRES_DB}" >/dev/null 2>&1; then
    echo "Postgres đã sẵn sàng."
    break
  fi
  sleep 1
  if [ "$i" -eq 30 ]; then
    echo "Cảnh báo: Postgres chưa ready sau 30s, vẫn tiếp tục."
  fi
done

echo "==> [4/7] Chuẩn bị backend image '${BACKEND_IMAGE}'"
if ! docker image inspect "${BACKEND_IMAGE}" >/dev/null 2>&1; then
  echo "Không thấy '${BACKEND_IMAGE}', thử build từ '${EX2_DIR}' ..."
  if [ -f "${EX2_DIR}/Dockerfile" ]; then
    docker build -t "${BACKEND_IMAGE}" "${EX2_DIR}"
  else
    echo "Không thấy ${EX2_DIR}/Dockerfile, dùng '${FALLBACK_IMAGE}' làm backend demo."
    docker pull "${FALLBACK_IMAGE}"
    BACKEND_IMAGE="${FALLBACK_IMAGE}"
  fi
fi
echo "Backend image dùng: ${BACKEND_IMAGE}"

echo "==> [5/7] Chạy backend container '${APP_CONTAINER}' trong network '${NETWORK}'"
if [ "${BACKEND_IMAGE}" = "${FALLBACK_IMAGE}" ]; then
  # Backend demo: giữ container sống để test DNS
  docker run -d \
    --name "${APP_CONTAINER}" \
    --network "${NETWORK}" \
    -e DB_HOST="${DB_CONTAINER}" \
    "${BACKEND_IMAGE}" sleep infinity
else
  docker run -d \
    --name "${APP_CONTAINER}" \
    --network "${NETWORK}" \
    -e DB_HOST="${DB_CONTAINER}" \
    -e PORT=3000 \
    "${BACKEND_IMAGE}"
fi

echo "==> [6/7] Test DNS: phân giải '${DB_CONTAINER}' từ '${APP_CONTAINER}'"
# Ưu tiên ping, fallback getent / nslookup nếu image không có ping
if docker exec "${APP_CONTAINER}" ping -c 2 "${DB_CONTAINER}"; then
  echo "DNS OK (ping thành công)."
elif docker exec "${APP_CONTAINER}" getent hosts "${DB_CONTAINER}"; then
  echo "DNS OK (getent thành công)."
elif docker exec "${APP_CONTAINER}" nslookup "${DB_CONTAINER}"; then
  echo "DNS OK (nslookup thành công)."
else
  echo "Thử phân giải từ chính Docker: docker exec kiểm tra /etc/hosts"
  docker exec "${APP_CONTAINER}" cat /etc/hosts || true
  docker network inspect "${NETWORK}"
fi

echo "==> [7/7] Test persistence: ghi dữ liệu -> xóa container -> tạo lại -> đọc lại"
echo "--- Ghi dữ liệu lần 1 ---"
docker exec "${DB_CONTAINER}" psql -U "${POSTGRES_USER}" -d "${POSTGRES_DB}" \
  -c "CREATE TABLE IF NOT EXISTS demo(id SERIAL PRIMARY KEY, val TEXT);"
docker exec "${DB_CONTAINER}" psql -U "${POSTGRES_USER}" -d "${POSTGRES_DB}" \
  -c "INSERT INTO demo(val) VALUES('hello-persist');"
docker exec "${DB_CONTAINER}" psql -U "${POSTGRES_USER}" -d "${POSTGRES_DB}" \
  -c "SELECT * FROM demo;"

echo "--- Xóa container '${DB_CONTAINER}' (GIỮ LẠI volume '${VOLUME}') ---"
docker rm -f "${DB_CONTAINER}"

echo "--- Chạy lại container mới, mount cùng volume ---"
docker run -d \
  --name "${DB_CONTAINER}" \
  --network "${NETWORK}" \
  -v "${VOLUME}:/var/lib/postgresql/data" \
  -e POSTGRES_DB="${POSTGRES_DB}" \
  -e POSTGRES_USER="${POSTGRES_USER}" \
  -e POSTGRES_PASSWORD="${POSTGRES_PASSWORD}" \
  "${POSTGRES_IMAGE}"

echo "--- Chờ Postgres (container mới) sẵn sàng ---"
for i in $(seq 1 30); do
  if docker exec "${DB_CONTAINER}" pg_isready -U "${POSTGRES_USER}" -d "${POSTGRES_DB}" >/dev/null 2>&1; then
    echo "Postgres (mới) đã sẵn sàng."
    break
  fi
  sleep 1
done

echo "--- Đọc lại dữ liệu sau khi recreate (xác minh persistence) ---"
docker exec "${DB_CONTAINER}" psql -U "${POSTGRES_USER}" -d "${POSTGRES_DB}" \
  -c "SELECT * FROM demo;"

echo ""
echo "==> Kết quả kiểm chứng:"
docker network ls | grep "${NETWORK}" || docker network ls
docker volume ls | grep "${VOLUME}" || docker volume ls
docker ps --filter "name=${DB_CONTAINER}" --filter "name=${APP_CONTAINER}"

echo ""
echo "Hoàn tất EX4. Container giữ lại để giảng viên kiểm tra."
echo "Dọn dẹp thủ công khi không cần nữa:"
echo "  docker rm -f ${DB_CONTAINER} ${APP_CONTAINER}"
echo "  docker network rm ${NETWORK}"
echo "  docker volume rm ${VOLUME}"
