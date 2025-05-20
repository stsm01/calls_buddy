import Foundation
import os.log

private let logger = Logger(subsystem: "com.callsbuddy", category: "OpenAIService")

class OpenAIService {
    private let apiKey: String
    private let baseURL = "https://api.openai.com/v1/audio/transcriptions"
    
    init(apiKey: String) {
        self.apiKey = apiKey
        logger.info("OpenAIService инициализирован")
    }
    
    func transcribeAudio(fileURL: URL) async throws -> String {
        logger.info("Подготовка запроса к OpenAI API")
        let boundary = UUID().uuidString
        
        var request = URLRequest(url: URL(string: baseURL)!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        
        var data = Data()
        
        // Добавляем файл
        logger.info("Добавление аудио файла в запрос")
        data.append("--\(boundary)\r\n".data(using: .utf8)!)
        data.append("Content-Disposition: form-data; name=\"file\"; filename=\"audio.m4a\"\r\n".data(using: .utf8)!)
        data.append("Content-Type: audio/m4a\r\n\r\n".data(using: .utf8)!)
        data.append(try Data(contentsOf: fileURL))
        data.append("\r\n".data(using: .utf8)!)
        
        // Добавляем модель
        logger.info("Добавление параметров модели в запрос")
        data.append("--\(boundary)\r\n".data(using: .utf8)!)
        data.append("Content-Disposition: form-data; name=\"model\"\r\n\r\n".data(using: .utf8)!)
        data.append("whisper-1\r\n".data(using: .utf8)!)
        
        // Завершаем boundary
        data.append("--\(boundary)--\r\n".data(using: .utf8)!)
        
        request.httpBody = data
        
        logger.info("Отправка запроса к OpenAI API")
        let (responseData, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            logger.error("Неверный формат ответа от сервера")
            throw NSError(domain: "OpenAIService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Неверный формат ответа от сервера"])
        }
        
        guard (200...299).contains(httpResponse.statusCode) else {
            logger.error("Ошибка сервера: \(httpResponse.statusCode)")
            throw NSError(domain: "OpenAIService", code: httpResponse.statusCode, userInfo: [NSLocalizedDescriptionKey: "Ошибка сервера: \(httpResponse.statusCode)"])
        }
        
        logger.info("Получен успешный ответ от сервера")
        
        struct TranscriptionResponse: Codable {
            let text: String
        }
        
        let transcription = try JSONDecoder().decode(TranscriptionResponse.self, from: responseData)
        logger.info("Расшифровка успешно декодирована")
        return transcription.text
    }
} 