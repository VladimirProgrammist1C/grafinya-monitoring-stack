# Интерактивный бэкап стека мониторинга на базе Графини

**Версия:** 2.0 (cleaned for public release)  
**Автор:** Vladimir Bessonov  
**Дата:** 17.08.2026

---

## 📌 Назначение

Скрипт предназначен для создания выборочного бэкапа стека мониторинга на базе Графини (MongoDB, VictoriaMetrics и другие не‑1С‑сервисы).

Бэкап выполняется отдельно от основной продакшн‑инфраструктуры 1С и не влияет на неё.

---

## 📦 Что бэкапится

Скрипт выполняет **два этапа**:

| Этап | Что сохраняется | Метод | Результат |
|------|-----------------|-------|-----------|
| **1** | Конфигурационные файлы проекта:<br>• `.env_backend`, `.env_frontend`, `.env_mongo`, `.env`<br>• `docker-compose.yml`<br>• `nginx.conf`<br>• Все файлы из папки `monitoring/` (vm-alerts.yml, prometheus.yml, webhook-forwarder.py) | Копирование через `robocopy` | Папка `ProjectConfigs` с полной структурой проекта (исключая `.git`, `node_modules`, `temp`, `backups`) |
| **2** | Docker‑тома:<br>• `grafinya-monitoring-stack_grafinya_mongo-data` (данные MongoDB)<br>• `grafinya-monitoring-stack_grafinya_security-log-data` (логи безопасности)<br>• `grafinya-monitoring-stack_victoriametrics-data` (метрики VictoriaMetrics) | Создание `tar.gz`‑архивов (побайтовая копия) | Отдельные файлы `.tar.gz` для каждого тома |

> **Важно:** Данные Tarantool **не бэкапятся**, так как в текущей конфигурации они хранятся только в оперативной памяти и не сохраняются на диске (том не смонтирован).

---

## 🖥️ Требования

| Компонент | Версия | Примечание |
|-----------|--------|------------|
| Windows | 10/11 Pro | Хост‑система |
| Docker Desktop | 4.x+ | Должен быть запущен |
| PowerShell | 5.1+ | Для выполнения скрипта |
| Контейнеры стека | запущены | Тома должны быть доступны для чтения |
| Свободное место на диске | ≥ 5 ГБ | Для хранения бэкапов (рекомендуется) |

---

## 📁 Структура проекта

```text
📦 grafinya-monitoring-stack
├── docker-compose.yml              # Оркестрация 11 контейнеров
├── nginx.conf                      # Reverse proxy для Графини
├── promscrape.yml                  # Конфиг vmagent (метрики хоста, Windows Exporter)
├── .env.example                    # Шаблон переменных окружения (4 секции)
├── .gitignore                      # Исключения Git (секреты, бэкапы, логи)
├── README.md                       # Этот файл
├── monitoring/                     # Конфигурация мониторинга
│   ├── prometheus.yml              # Конфиг сбора метрик VictoriaMetrics
│   ├── vm-alerts.yml               # Правила алертов для vmalert
│   └── webhook-forwarder.py        # Прокси vmalert → VoceChat ⭐
└── scripts/                        # Скрипты автоматизации
    ├── backup-experimental.ps1     # Интерактивный бэкап (конфиги + тома)
    └── readme.md                   # Документация по бэкапам
```

> ⚠️ **Локально, вне Git** (создаются из `.env.example` и исключены в `.gitignore`):
> ```text
> ├── .env                # Переменные корня для интерполяции docker-compose
> ├── .env_backend        # Секреты backend Графини
> ├── .env_frontend       # Переменные frontend Графини
> └── .env_mongo          # Секреты MongoDB
> ```

---

## ▶️ Запуск

1. Откройте PowerShell.

2. Перейдите в папку со скриптом:

   ```powershell
   cd scripts
   ```

3. При первом запуске может потребоваться разрешить выполнение сценариев:

   ```powershell
   Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
   ```

4. Запустите скрипт:

   ```powershell
   .\backup-experimental.ps1
   ```

5. В появившемся меню выберите действие:

   - `1` – только этап 1 (конфиги)
   - `2` – только этап 2 (архивация томов)
   - `a` – выполнить все этапы последовательно
   - `s` – показать итоги и завершить
   - `q` – выйти без сохранения

### Адаптивные пути

- **Корень проекта** — переменная окружения `GRAFINYA_PROJECT_ROOT` или папка на уровень выше скрипта;
- **Корень бэкапов** — переменная окружения `GRAFINYA_BACKUP_ROOT` или папка `backups/` внутри проекта.

Пример переопределения:

```powershell
$env:GRAFINYA_PROJECT_ROOT = "C:\my-grafinya"
$env:GRAFINYA_BACKUP_ROOT  = "D:\backups\grafinya"
.\backup-experimental.ps1
```

---

## 📂 Где искать бэкап

Все бэкапы сохраняются в корень бэкапов (по умолчанию — `backups/` внутри проекта):

```text
<BackupRoot>\Backup_ГГГГ-ММ-ДД_ЧЧ-ММ-СС\
```

Внутри вы найдёте:

- `ProjectConfigs/` – скопированные конфиги проекта
- `backup.log` – полный лог выполнения
- `grafinya-monitoring-stack_grafinya_mongo-data.tar.gz` – архив MongoDB
- `grafinya-monitoring-stack_grafinya_security-log-data.tar.gz` – архив Security Log
- `grafinya-monitoring-stack_victoriametrics-data.tar.gz` – архив VictoriaMetrics

> ⚠️ Бэкап содержит чувствительные данные (пароли из `.env*`) — не передавайте третьим лицам и не коммитьте в Git (папка `backups/` исключена в `.gitignore`).

---

## 🔄 Восстановление (вручную)

Восстановление пока не автоматизировано, но вы можете сделать это вручную:

### 1. Конфиги проекта

Просто скопируйте папку `ProjectConfigs` обратно в корень проекта (с заменой) и перезапустите контейнеры.

### 2. Тома

Для каждого `.tar.gz`‑архива выполните команду (пример для MongoDB):

```powershell
docker run --rm `
  -v grafinya-monitoring-stack_grafinya_mongo-data:/target `
  -v <BackupRoot>\Backup_ГГГГ-ММ-ДД_ЧЧ-ММ-СС:/backup `
  alpine tar -xzf /backup/grafinya-monitoring-stack_grafinya_mongo-data.tar.gz -C /target
```

После этого перезапустите соответствующий контейнер:

```powershell
docker restart grafinya-mongo
```

Аналогично для остальных томов.

---

## ⚠️ Устранение неисправностей

| Проблема | Решение |
|----------|---------|
| `mongodump` не найден | В скрипте убран этап `mongodump`, используется только архивация томов. Если вы всё же хотите дампы – установите `mongodb-database-tools` в контейнер. |
| Контейнер `grafinya-mongo` не запущен | Запустите его перед бэкапом: `docker start grafinya-mongo` |
| Том не найден | Имена томов формируются из имени проекта в `docker-compose.yml` (`name: grafinya-monitoring-stack`). Проверьте список: `docker volume ls` |
| Недостаточно места на диске | Очистите старые бэкапы в корне бэкапов |
| Robocopy завершается с кодом > 7 | Проверьте права доступа к папке проекта и убедитесь, что проект не используется другими процессами |

---

## 🔗 Связанные файлы

- [Основной бэкап инфраструктуры 1С](https://github.com/VladimirProgrammist1C/1c-home-infrastructure/blob/dev/scripts/backup-scripts/full-backup-rus.ps1) – для продакшн‑среды (отдельный проект)
- [Документация по развёртыванию стека](../README.md) – основной README этого проекта

---

## 📜 Changelog

- **v2.0 (17.08.2026)** – подготовка к публичному релизу: адаптивные пути без хардкода, имена томов и контейнеров приведены в соответствие с публичным `docker-compose.yml` (`grafinya-*`), исправлены ссылки в разделе «Связанные файлы».
- **v1.1 (17.07.2026)** – удалён этап `mongodump`, оставлена только архивация томов (рекомендованный способ).
- **v1.0 (14.07.2026)** – первый релиз.

---
