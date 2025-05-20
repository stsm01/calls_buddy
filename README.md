# Calls Buddy

Приложение для записи и транскрибации аудио звонков с использованием OpenAI Whisper API.

## Возможности

- Запись системного аудио
- Визуализация уровня звука в реальном времени
- Автоматическая транскрибация аудио с помощью OpenAI Whisper
- Сохранение транскрипций в текстовые файлы

## Требования

- macOS 12.0 или выше
- Xcode 14.0 или выше
- OpenAI API ключ

## Установка

1. Клонируйте репозиторий:
```bash
git clone https://github.com/stsm01/calls_buddy.git
cd calls_buddy
```

2. Откройте проект в Xcode:
```bash
open CallsBuddy.xcodeproj
```

3. Установите API ключ OpenAI:
```bash
export OPENAI_API_KEY="ваш-api-ключ"
```

4. Соберите и запустите проект в Xcode

## Настройка API ключа

1. Скопируйте файл `CallsBuddy/config.plist` из примера:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>OPENAI_API_KEY</key>
    <string>ваш-ключ-от-OpenAI</string>
</dict>
</plist>
```

2. Поместите свой OpenAI API ключ в поле `<string>...</string>`.
3. Убедитесь, что файл `CallsBuddy/config.plist` добавлен в `.gitignore` и не попадает в репозиторий.

## Использование

1. Запустите приложение
2. Нажмите кнопку записи для начала записи аудио
3. После остановки записи, аудио будет автоматически отправлено на транскрибацию
4. Транскрипция будет сохранена в папке `~/Desktop/calls/calls_texts`

## Лицензия

MIT 