# 🇷🇺 Стек мониторинга на базе Графини

Импортозамещённый контур мониторинга для инфраструктуры домашнего 1С-сервера на базе **Графини** (российская система визуализации от «Лаборатории Числитель») и стека **Victoria Metrics**.

[![IT Elements](https://img.shields.io/badge/IT_Elements-2026-blue)](https://jet-sit.ru/events/it-elements-2026/)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

> **Цель:** Показать, что архитектура важнее инструментов. Почти весь стек мониторинга заменён (Grafana → Графиня, Prometheus → VictoriaMetrics, Grafana Alerting → vmalert) — а алерты по-прежнему приходят в VoceChat в читаемом формате.

## 📦 Компоненты

### Импортозамещённый стек (этот проект)
- **Визуализация:** Графиня (российская, Лаборатория Числитель)
- **Хранение метрик:** VictoriaMetrics (PromQL-совместимый, open source)
- **Сбор метрик:** vmagent
- **Алертинг:** vmalert + Python-прокси (326 строк)
- **Уведомления:** VoceChat (канал `#vm-alerts`)

### Параллельный стек (западный)
Работает одновременно в том же сервере и мониторит те же сервисы: [1c-home-infrastructure](https://github.com/VladimirProgrammist1C/1c-home-infrastructure) (Grafana + Prometheus).

| Компонент | Западный стек | Импортозамещённый стек |
|-----------|---------------|------------------------|
| **Визуализация** | Grafana | **Графиня** 🇷🇺 |
| **Хранение метрик** | Prometheus | VictoriaMetrics |
| **Алертинг** | Grafana Alerting | vmalert + Python-прокси |
| **Канал уведомлений** | `#alerts` | `#vm-alerts` |

## ⚠️ Приватный реестр образов

Контейнеры Графини собираются из образов приватного реестра вендора `registry.pult.chislitellab.ru:8124`.

**Доступ и инструкция по установке — по запросу:** [chislitellab.ru/grafinya](https://chislitellab.ru/grafinya)

Без `docker login` в реестр стек не поднимется — это ограничение вендора, не этого репозитория.

## 🚀 Быстрый старт

### Требования
- Docker Desktop / Docker Compose
- Существующая сеть `1c-infrastructure` (создаётся основным стеком)
- Доступ к приватному реестру Графини (запрашивается у вендора)

### Установка

1. **Клонируйте репозиторий:**
   ```bash
   git clone <url-репозитория>
   cd grafinya-monitoring-stack
   ```

2. **Авторизуйтесь в реестре Графини:**
   ```bash
   docker login registry.pult.chislitellab.ru:8124
   ```

3. **Настройте переменные окружения:**
   ```powershell
   Copy-Item .env.example .env
   # Отредактируйте .env, указав свои пароли
   ```
   
   Разложите значения по файлам:
   - Секция 1 → `.env_backend`
   - Секция 2 → `.env_frontend`
   - Секция 3 → `.env_mongo`
   - Секция 4 → `.env` (корень, для интерполяции `docker-compose`)

4. **Запустите стек:**
   ```powershell
   docker-compose up -d
   ```

5. **Проверьте статус:**
   ```powershell
   docker-compose ps
   ```

## 🌐 Доступ к сервисам

| Сервис | Адрес | Назначение |
| :--- | :--- | :--- |
| **Графиня** | http://localhost:3004 | Веб-интерфейс (через nginx) |
| **VictoriaMetrics** | http://localhost:8428 | Хранение метрик, PromQL API |
| **vmalert** | http://localhost:8880 | UI алертов и правил |
| **vmagent** | http://localhost:8429 | UI сбора метрик |
| **MongoDB** | `localhost:27017` | БД Графини |

## 📂 Структура проекта

```text
📦 grafinya-monitoring-stack
├── docker-compose.yml              # Оркестрация (11 контейнеров)
├── nginx.conf                      # Reverse proxy для Графини
├── promscrape.yml                  # Конфиг сбора метрик (vmagent)
├── .env.example                    # Шаблон переменных окружения
├── .gitignore                      # Исключения для Git
├── monitoring/                     # Конфигурация мониторинга
│   ├── vm-alerts.yml               # Правила алертов для vmalert
│   ├── webhook-forwarder.py        # Прокси vmalert → VoceChat ⭐
│   └── prometheus.yml              # Конфиг VictoriaMetrics
├── scripts/                        # Скрипты автоматизации
│   ├── backup-experimental.ps1     # Скрипт бэкапа
│   └── readme.md                   # Документация по бэкапам
└── README.md                       # Этот файл
```

## 🔑 Ключевая фишка: Python-прокси (326 строк)

**Проблема:** vmalert отправляет алерты в формате, который VoceChat не понимает.

**Решение:** [`monitoring/webhook-forwarder.py`](monitoring/webhook-forwarder.py) — минимальный HTTP-прокси:
1. Принимает JSON от vmalert на порту `:9093`
2. Форматирует в читаемый текст
3. Добавляет `x-api-key` для авторизации
4. Отправляет в канал `#vm-alerts` VoceChat

**Почему не Alertmanager?** vmalert + прокси проще и легче в отладке для этого сценария. Это **единственное место**, где потребовалась разработка при смене стека.

## 🎯 Зачем этот стек?

**Суверенитет над визуализацией** — самой чувствительной к санкциям части стека мониторинга.

Если завтра Grafana Labs заблокирует Россию (как Datadog в 2022), этот контур продолжит работать:
- ✅ Дашборды на месте (Графиня)
- ✅ Метрики собираются (VictoriaMetrics)
- ✅ Алерты идут (vmalert + прокси)

## 📚 Документация

- 📘 **[`monitoring/vm-alerts.yml`](monitoring/vm-alerts.yml)** — правила алертов для vmalert (критические + предупреждения)
- ⭐ **[`monitoring/webhook-forwarder.py`](monitoring/webhook-forwarder.py)** — прокси vmalert → VoceChat (326 строк)
- 🔧 **[`monitoring/prometheus.yml`](monitoring/prometheus.yml)** — конфиг сбора метрик VictoriaMetrics
- 📡 **[`promscrape.yml`](promscrape.yml)** — конфиг сбора метрик vmagent
- 💾 **[`scripts/readme.md`](scripts/readme.md)** — документация по бэкапам

## 🪟 Windows-specific метрики (опционально)

Файл [`promscrape.yml`](promscrape.yml) содержит job для **Windows Exporter** (`windows-exporter` на порту `:9182`). Это специфично для Windows-хоста.

**Если у вас Linux:**
- Закомментируйте job `windows-exporter` в `promscrape.yml`
- Или замените на `node-exporter`:
  ```yaml
  - job_name: 'node-exporter'
    static_configs:
      - targets: ['host.docker.internal:9100']

## 🔗 Связанные проекты

- **[1c-home-infrastructure](https://github.com/VladimirProgrammist1C/1c-home-infrastructure)** — основной стек мониторинга (Grafana + Prometheus), который мониторится этим контуром.
- **[1c-zup-vocechat-integration](https://github.com/VladimirProgrammist1C/1c-zup-vocechat-integration)** — расширение 1С:ЗУП 3.1 для отправки уведомлений в VoceChat.

## 🛠️ Технологии

- **Графиня** — российская система визуализации мониторинга (Лаборатория Числитель)
- **VictoriaMetrics / vmagent / vmalert** — PromQL-совместимый open source бэкенд
- **MongoDB + Tarantool** — БД и кэш Графини
- **Python 3** — HTTP-прокси для алертов (326 строк)
- **Nginx** — reverse proxy
- **VoceChat** — on-premise мессенджер для уведомлений
- **Docker Compose** — оркестрация контейнеров

## 👤 Автор

**Vladimir Bessonov**

- 📧 Email: bessonov_1989@list.ru
- 🔗 [InfoStart](https://infostart.ru/profile/348559/)
- 🔗 [GitHub](https://github.com/VladimirProgrammist1C)
- 🔗 [ВКонтакте](https://vk.com/club230942526)
- 🔗 [Rutube](https://rutube.ru/channel/766472/)

## 📄 Лицензия

MIT — используйте, модифицируйте, делитесь.