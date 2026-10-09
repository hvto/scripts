# Haiku KVN: Scripts

Набор скриптов для установки и настройки сервисов, используемых в инфраструктуре Haiku KVN.

Скрипты рассчитаны в первую очередь на Debian и предназначены для быстрого развёртывания сервисов на новых серверах.

## Scripts

| Script | Description |
| --- | --- |
| `realm.sh` | Установка и настройка [Realm](https://github.com/zhboner/realm) |
| `caddy.sh` | Установка и настройка [Caddy](https://caddyserver.com/) |
| `bbr.sh` | Включение и настройка BBR (оптимизация сети) |
| `fail2ban.sh` | Защита SSH от перебора паролей и ботов |

Список будет дополняться.

## Usage

```bash
curl -fsSL https://raw.githubusercontent.com/hvto/scripts/main/realm.sh | sudo bash
```

```bash
curl -fsSL https://raw.githubusercontent.com/hvto/scripts/main/caddy.sh | sudo bash
```

```bash
curl -fsSL https://raw.githubusercontent.com/hvto/scripts/main/bbr.sh | sudo bash
```

```bash
curl -fsSL https://raw.githubusercontent.com/hvto/scripts/main/fail2ban.sh | sudo bash
```

## Style

Скрипты стараемся держать простыми, предсказуемыми и пригодными для повторного запуска.

**Основные принципы:**

- `#!/usr/bin/env bash`
- `set -euo pipefail`
- минимум внешних зависимостей
- автоматическое определение архитектуры, когда это необходимо
- использование официальных пакетов и релизов
- конфигурация хранится в стандартных системных каталогах
- сервисы управляются через `systemd`
- существующая пользовательская конфигурация не перезаписывается без необходимости
- повторный запуск скрипта должен быть безопасным
- минимум интерактивных вопросов
- понятные сообщения об ошибках
- без лишнего форматирования и декоративного вывода

Если сервис уже установлен, скрипт по возможности должен обновить или привести установку к ожидаемому состоянию, а не создавать вторую установку.
