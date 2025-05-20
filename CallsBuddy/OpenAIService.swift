import Foundation
import os.log

private let logger = Logger(subsystem: "com.callsbuddy", category: "OpenAIService")

class OpenAIService {
    private let apiKey: String
    private let baseURL = "https://api.openai.com/v1/audio/transcriptions"
    private let maxRetries = 3
    private let timeoutInterval: TimeInterval = 1200 // 20 минут
    
    init(apiKey: String) {
        self.apiKey = apiKey
        logger.info("OpenAIService инициализирован")
    }
    
    func transcribeAudio(fileURL: URL) async throws -> String {
        var lastError: Error?
        
        for attempt in 1...maxRetries {
            do {
                logger.info("Попытка \(attempt) из \(maxRetries)")
                return try await performTranscription(fileURL: fileURL)
            } catch {
                lastError = error
                logger.error("Попытка \(attempt) не удалась: \(error.localizedDescription)")
                
                if attempt < maxRetries {
                    let delay = TimeInterval(attempt * 2) // Увеличиваем задержку с каждой попыткой
                    logger.info("Ожидание \(delay) секунд перед следующей попыткой")
                    try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                }
            }
        }
        
        throw lastError ?? NSError(domain: "OpenAIService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Все попытки расшифровки не удались"])
    }
    
    private func performTranscription(fileURL: URL) async throws -> String {
        logger.info("Подготовка запроса к OpenAI API")
        let boundary = UUID().uuidString
        
        var request = URLRequest(url: URL(string: baseURL)!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = timeoutInterval
        
        var data = Data()
        
        // Добавляем файл
        logger.info("Добавление аудио файла в запрос")
        let fileData = try Data(contentsOf: fileURL)
        logger.info("Размер файла: \(fileData.count) байт")
        
        // Проверяем размер файла
        if fileData.count > 25 * 1024 * 1024 { // 25MB limit
            logger.error("Файл слишком большой: \(fileData.count) байт")
            throw NSError(domain: "OpenAIService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Файл слишком большой. Максимальный размер: 25MB"])
        }
        
        // Добавляем параметр model
        data.append("--\(boundary)\r\n".data(using: .utf8)!)
        data.append("Content-Disposition: form-data; name=\"model\"\r\n\r\n".data(using: .utf8)!)
        data.append("whisper-1\r\n".data(using: .utf8)!)
        
        // Добавляем параметр response_format
        data.append("--\(boundary)\r\n".data(using: .utf8)!)
        data.append("Content-Disposition: form-data; name=\"response_format\"\r\n\r\n".data(using: .utf8)!)
        data.append("json\r\n".data(using: .utf8)!)
        
        // Добавляем параметр language (опционально)
        data.append("--\(boundary)\r\n".data(using: .utf8)!)
        data.append("Content-Disposition: form-data; name=\"language\"\r\n\r\n".data(using: .utf8)!)
        data.append("ru\r\n".data(using: .utf8)!)
        
        // Добавляем файл
        data.append("--\(boundary)\r\n".data(using: .utf8)!)
        let fileExtension = fileURL.pathExtension.lowercased()
        let mimeType: String
        switch fileExtension {
        case "m4a":
            mimeType = "audio/m4a"
        case "mp3":
            mimeType = "audio/mpeg"
        case "mp4":
            mimeType = "audio/mp4"
        case "wav":
            mimeType = "audio/wav"
        case "webm":
            mimeType = "audio/webm"
        default:
            mimeType = "audio/m4a" // fallback
        }
        data.append("Content-Disposition: form-data; name=\"file\"; filename=\"audio.\(fileExtension)\"\r\n".data(using: .utf8)!)
        data.append("Content-Type: \(mimeType)\r\n\r\n".data(using: .utf8)!)
        data.append(fileData)
        data.append("\r\n".data(using: .utf8)!)
        
        // Завершаем boundary
        data.append("--\(boundary)--\r\n".data(using: .utf8)!)
        
        request.httpBody = data
        
        // Логируем заголовки запроса
        logger.info("Заголовки запроса:")
        request.allHTTPHeaderFields?.forEach { key, value in
            logger.info("\(key): \(value)")
        }
        
        // Логируем первые 100 байт тела запроса для отладки
        if let bodyPreview = String(data: data.prefix(100), encoding: .utf8) {
            logger.info("Начало тела запроса: \(bodyPreview)")
        }
        
        // Логируем размер файла и его тип
        logger.info("Размер файла: \(fileData.count) байт")
        logger.info("Тип файла: \(mimeType)")
        logger.info("Имя файла в запросе: audio.\(fileExtension)")
        
        // Логируем полный URL запроса
        logger.info("URL запроса: \(request.url?.absoluteString ?? "unknown")")
        
        logger.info("Отправка запроса к OpenAI API")
        let (responseData, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            logger.error("Неверный формат ответа от сервера")
            throw NSError(domain: "OpenAIService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Неверный формат ответа от сервера"])
        }
        
        // Логируем ответ
        logger.info("Статус ответа: \(httpResponse.statusCode)")
        logger.info("Заголовки ответа:")
        httpResponse.allHeaderFields.forEach { key, value in
            logger.info("\(key): \(value)")
        }
        
        if let responseString = String(data: responseData, encoding: .utf8) {
            logger.info("Тело ответа: \(responseString)")
        }
        
        if !(200...299).contains(httpResponse.statusCode) {
            logger.error("Получен ответ с ошибкой. Статус: \(httpResponse.statusCode)")
            logger.error("Заголовки ответа: \(httpResponse.allHeaderFields)")
            
            if let responseString = String(data: responseData, encoding: .utf8) {
                logger.error("Тело ответа с ошибкой: \(responseString)")
            }
            
            if let errorJson = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any] {
                logger.error("JSON ответа с ошибкой: \(errorJson)")
                if let error = errorJson["error"] as? [String: Any],
                   let message = error["message"] as? String {
                    logger.error("Сообщение об ошибке: \(message)")
                    throw NSError(domain: "OpenAIService", code: httpResponse.statusCode, userInfo: [NSLocalizedDescriptionKey: message])
                }
            }
            
            // Если не удалось получить сообщение об ошибке из JSON, пробуем прочитать как текст
            if let errorText = String(data: responseData, encoding: .utf8) {
                logger.error("Текст ошибки: \(errorText)")
                throw NSError(domain: "OpenAIService", code: httpResponse.statusCode, userInfo: [NSLocalizedDescriptionKey: "Ошибка сервера: \(errorText)"])
            }
            
            throw NSError(domain: "OpenAIService", code: httpResponse.statusCode, userInfo: [NSLocalizedDescriptionKey: "Ошибка сервера: \(httpResponse.statusCode)"])
        }
        
        logger.info("Получен успешный ответ от сервера")
        
        struct TranscriptionResponse: Codable {
            let text: String
        }
        
        let transcription = try JSONDecoder().decode(TranscriptionResponse.self, from: responseData)
        logger.info("Расшифровка успешно декодирована")
        logger.info("Полученный текст: \(transcription.text)")
        
        return transcription.text
    }
} 