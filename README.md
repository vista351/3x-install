# 3x-install
Готовый deploy.sh собран и проверен через bash -n.
Он выполняет весь согласованный сценарий:
- apt update + dist-upgrade;
- устанавливает ufw и ipset, не включая и не конфигурируя их;
- устанавливает Nginx, Certbot, Python-модули, GeoIP2 и Fail2Ban;
- запускает ваш install-docker.sh, который устанавливает Docker CE и Compose Plugin;   install-docker
- создаёт /opt/docker/3x-ui/db, /opt/ammo, /etc/nginx/geo;
- делает backup существующих конфигов;
- останавливает Nginx;
- комментирует активные access_log;
- добавляет error_log /var/log/nginx/error.log;;
- устанавливает geoip2.conf, logformat.conf, vless.conf;
- интерактивно запрашивает домен и проверяет его формат;
- заменяет Domain_name в vless.conf;
- автоматически скачивает GeoLite2-Country.mmdb и GeoLite2-City.mmdb из releases/latest/download, поэтому дата релиза не захардкожена. Текущий latest действительно ведёт на релиз 2026.09.28. GitHub
- выполняет nginx -t перед запуском;
- устанавливает ваш jail.local и все nginx-*.conf, затем выполняет fail2ban-client -t;
- переносит docker-compose.yml в /opt/docker/3x-ui/ и запускает 3x-ui через docker compose up -d. Compose сохраняет БД в $PWD/db и монтирует /etc/letsencrypt read-only.
