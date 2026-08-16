"""
Webhook-прокси: vmalert → VoceChat.

Принимает JSON-алерты от vmalert (формат Prometheus Alertmanager),
преобразует их в читаемый текст и отправляет в канал VoceChat
через API бота с x-api-key авторизацией.

Решает проблему несовместимости форматов:
- vmalert отдаёт JSON в формате Alertmanager webhook
- VoceChat принимает plain text через бот-API

Переменные окружения:
- VOCECHAT_API_KEY        — токен бота VoceChat (обязательно)
- VOCECHAT_CHANNEL_ID     — ID канала для отправки (по умолчанию: 4)
- VOCECHAT_HOST           — имя хоста VoceChat в Docker-сети
                            (по умолчанию: vocechat-notifications)
- REPEAT_INTERVAL_MINUTES — интервал повтора firing-алертов (по умолчанию: 2)
"""

import http.server
import json
import urllib.request
import urllib.error
import os
import sys
import socket
from datetime import datetime, timedelta, timezone

# =============================================================================
# КОНФИГУРАЦИЯ
# =============================================================================
API_KEY = os.environ.get('VOCECHAT_API_KEY', '')
CHANNEL_ID = os.environ.get('VOCECHAT_CHANNEL_ID', '4')
VOCECHAT_HOST = os.environ.get('VOCECHAT_HOST', 'vocechat-notifications')
VOCECHAT_URL = f"http://{VOCECHAT_HOST}:3000/api/bot/send_to_group/{CHANNEL_ID}"

REPEAT_INTERVAL = timedelta(minutes=int(os.environ.get('REPEAT_INTERVAL_MINUTES', '2')))
SERVICE_CACHE_TTL = timedelta(seconds=30)

# HTTP-статус ниже 500 считаем "сервис жив" (даже если 4xx — это проблема клиента,
# а не сервиса). 5xx и ошибки соединения = DOWN.
HEALTHY_STATUS_THRESHOLD = 500

alert_state = {}
service_cache = {}


def log(msg):
    """Выводит сообщение в stderr с немедленным сбросом буфера."""
    print(msg, file=sys.stderr, flush=True)


def get_alert_key(alert):
    """Формирует уникальный ключ алерта по имени и instance."""
    alertname = alert.get('labels', {}).get('alertname', 'Unknown')
    instance = alert.get('labels', {}).get('instance', '')
    return f"{alertname}:{instance}"


def check_service_health(instance_url):
    """
    Проверяет, отвечает ли сервис по URL (HEAD-запрос).
    Результаты кэшируются на SERVICE_CACHE_TTL, чтобы не долбить
    сервисы проверками при каждом повторном срабатывании алерта.
    """
    now = datetime.now(timezone.utc)
    if instance_url in service_cache:
        cached_status, cached_time = service_cache[instance_url]
        if now - cached_time < SERVICE_CACHE_TTL:
            return cached_status
    try:
        req = urllib.request.Request(instance_url, method='HEAD')
        with urllib.request.urlopen(req, timeout=2) as response:
            is_healthy = response.status < HEALTHY_STATUS_THRESHOLD
    except Exception:
        is_healthy = False
    service_cache[instance_url] = (is_healthy, now)
    log(f"[HEALTH] {instance_url} -> {'UP' if is_healthy else 'DOWN'}")
    return is_healthy


def utc_iso():
    """Возвращает текущее время UTC в формате YYYY-MM-DDTHH:MM:SSZ."""
    return datetime.now(timezone.utc).isoformat(timespec='seconds').replace('+00:00', 'Z')


def should_send_alert(alert):
    """
    Решает, нужно ли отправлять уведомление по этому алерту.
    
    Логика:
    - Новый алерт → отправляем
    - Изменился статус (firing ↔ resolved) → отправляем
    - Firing и прошло больше REPEAT_INTERVAL → повтор
    - Resolved уже отправляли → пропускаем (не повторяем RESOLVED)
    
    Дополнительная проверка: если имя алерта содержит 'Down' или 'Unavailable',
    делает HEAD-запрос к сервису и корректирует статус по факту (обходит
    проблему задержек vmalert при определении RESOLVED).
    """
    key = get_alert_key(alert)
    vmalert_status = alert.get('status') or 'firing'
    now = datetime.now(timezone.utc)
    
    real_status = vmalert_status
    if 'Down' in key or 'Unavailable' in key:
        instance = alert.get('labels', {}).get('instance', '')
        if instance:
            is_healthy = check_service_health(instance)
            real_status = 'resolved' if is_healthy else 'firing'
            log(f"[REAL_STATUS] {key} -> {real_status} (vmalert says {vmalert_status})")
    
    if real_status != vmalert_status:
        log(f"[FIX] Correcting status for {key}: {vmalert_status} -> {real_status}")
        alert['status'] = real_status
        if real_status == 'resolved':
            alert['endsAt'] = utc_iso()
        else:
            alert['startsAt'] = alert.get('startsAt', utc_iso())
    
    if key not in alert_state:
        alert_state[key] = {
            'status': real_status,
            'last_sent': now,
            'resolved_sent': (real_status == 'resolved')
        }
        log(f"[NEW] Alert '{key}' -> {real_status}")
        return True
    
    state = alert_state[key]
    old_status = state['status']
    last_sent = state['last_sent']
    
    if old_status != real_status:
        if old_status == 'resolved' and real_status == 'firing':
            alert['startsAt'] = utc_iso()
            log(f"[UPDATE] Updated startsAt for {key} to {utc_iso()}")
        alert_state[key] = {
            'status': real_status,
            'last_sent': now,
            'resolved_sent': (real_status == 'resolved')
        }
        log(f"[CHANGE] Alert '{key}' {old_status} -> {real_status}")
        return True
    
    if real_status == 'resolved':
        if state.get('resolved_sent', False):
            log(f"[SKIP] Alert '{key}' already resolved, no repeat")
            return False
        else:
            alert_state[key]['resolved_sent'] = True
            alert_state[key]['last_sent'] = now
            log(f"[RESOLVED] Alert '{key}' first resolved notification")
            return True
    
    if real_status == 'firing':
        if now - last_sent >= REPEAT_INTERVAL:
            alert_state[key]['last_sent'] = now
            log(f"[REPEAT] Alert '{key}' -> firing (after {REPEAT_INTERVAL})")
            return True
        else:
            remaining = REPEAT_INTERVAL - (now - last_sent)
            log(f"[SKIP] Alert '{key}' firing, next repeat in {remaining}")
            return False
    
    return False


def normalize_alerts(data):
    """
    Извлекает список алертов из тела webhook-запроса.
    vmalert может присылать либо список алертов напрямую,
    либо обёртку {"alerts": [...]}.
    """
    if isinstance(data, list):
        alerts = data
    elif isinstance(data, dict):
        alerts = data.get('alerts', [])
    else:
        log(f"[WARN] Unknown data type: {type(data).__name__}")
        return []
    log(f"[INFO] Received {len(alerts)} alerts from vmalert")
    return alerts


def format_alert_message(status, alerts):
    """Формирует читаемое текстовое сообщение для VoceChat."""
    if status == 'firing':
        text = "🚨 *СРАБОТАЛИ АЛЕРТЫ* 🚨\n"
    else:
        text = "✅ *АЛЕРТЫ СНЯТЫ* ✅\n"
    text += "━━━━━━━━━━━━━━━━━━━━\n"
    
    firing_alerts = [a for a in alerts if a.get('status') in (None, 'firing')]
    resolved_alerts = [a for a in alerts if a.get('status') == 'resolved']
    
    if firing_alerts:
        text += "🔴 *СРАБОТАЛ:*\n"
        for alert in firing_alerts:
            name = alert.get('labels', {}).get('alertname', 'Unknown')
            summary = alert.get('annotations', {}).get('summary', '')
            description = alert.get('annotations', {}).get('description', '')
            text += f"• {name}\n"
            if summary:
                text += f"{summary}\n"
            if description and description != summary:
                text += f"{description}\n"
            starts_at = alert.get('startsAt')
            if starts_at:
                try:
                    dt = datetime.fromisoformat(starts_at.replace('Z', '+00:00'))
                    local_dt = dt.astimezone()
                    text += f"⏰ Время: {local_dt.strftime('%H:%M:%S')}\n"
                except Exception:
                    pass
            text += "\n"
    
    if resolved_alerts:
        text += "🟢 *УСТРАНЕН:*\n"
        for alert in resolved_alerts:
            name = alert.get('labels', {}).get('alertname', 'Unknown')
            summary = alert.get('annotations', {}).get('summary', '')
            description = alert.get('annotations', {}).get('description', '')
            text += f"• {name}\n"
            if summary:
                text += f"{summary}\n"
            if description and description != summary:
                text += f"{description}\n"
            ends_at = alert.get('endsAt')
            if ends_at:
                try:
                    dt = datetime.fromisoformat(ends_at.replace('Z', '+00:00'))
                    local_dt = dt.astimezone()
                    text += f"⏰ Восстановлен: {local_dt.strftime('%H:%M:%S')}\n"
                except Exception:
                    pass
            text += "\n"
    
    text += "━━━━━━━━━━━━━━━━━━━━\n"
    text += f"📊 Итого: {len(firing_alerts)} сработали, {len(resolved_alerts)} устранены\n"
    return text


class WebhookHandler(http.server.BaseHTTPRequestHandler):
    """HTTP-обработчик входящих webhook-запросов от vmalert."""

    def do_POST(self):
        try:
            content_length = int(self.headers.get('Content-Length', 0))
            post_data = self.rfile.read(content_length)
            log(f"[INFO] Received {content_length} bytes")
            data = json.loads(post_data)
            all_alerts = normalize_alerts(data)
            
            alerts_to_send = []
            for alert in all_alerts:
                if should_send_alert(alert):
                    alerts_to_send.append(alert)
            
            if not alerts_to_send:
                log("[SKIP] No new state changes, skipping notification")
                self.send_response(200)
                self.end_headers()
                return
            
            firing_to_send = [a for a in alerts_to_send if a.get('status') in (None, 'firing')]
            resolved_to_send = [a for a in alerts_to_send if a.get('status') == 'resolved']
            if firing_to_send:
                send_status = "firing"
            elif resolved_to_send:
                send_status = "resolved"
            else:
                send_status = "unknown"
            
            log(f"[INFO] Sending {len(alerts_to_send)} alerts, status={send_status} "
                f"(firing={len(firing_to_send)}, resolved={len(resolved_to_send)})")
            
            text = format_alert_message(send_status, alerts_to_send)
            
            req = urllib.request.Request(
                VOCECHAT_URL,
                data=text.encode('utf-8'),
                method='POST'
            )
            req.add_header('Content-Type', 'text/plain')
            req.add_header('x-api-key', API_KEY)
            
            with urllib.request.urlopen(req, timeout=5) as response:
                log(f"[OK] VoceChat response: {response.status}")
            
            self.send_response(200)
            self.end_headers()
            
        except urllib.error.HTTPError as e:
            error_body = e.read().decode('utf-8', errors='replace')
            log(f"[ERROR] HTTP Error {e.code}: {e.reason}")
            log(f"[ERROR] Response body: {error_body}")
            self.send_response(500)
            self.end_headers()
        except Exception as e:
            log(f"[ERROR] Exception: {type(e).__name__}: {e}")
            import traceback
            traceback.print_exc(file=sys.stderr)
            self.send_response(500)
            self.end_headers()

    def log_message(self, format, *args):
        """Отключаем стандартный access-log HTTP-сервера — он дублирует наш log()."""
        pass


def main():
    log(f"[START] Webhook proxy listening on port 80")
    log(f"[START] Forwarding to {VOCECHAT_URL}")
    log(f"[START] Repeat interval: {REPEAT_INTERVAL}")
    server = http.server.HTTPServer(('0.0.0.0', 80), WebhookHandler)
    server.socket.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        log("[STOP] Остановка сервера...")
        server.shutdown()


if __name__ == '__main__':
    main()