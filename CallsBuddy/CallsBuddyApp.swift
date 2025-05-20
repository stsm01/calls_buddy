import SwiftUI
import AVFoundation
import CoreAudio
import os.log

private let logger = Logger(subsystem: "com.callsbuddy", category: "AudioRecorder")

@main
struct CallsBuddyApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(width: 200, height: 120)
        }
    }
}

class AudioRecorder: ObservableObject {
    private var audioEngine: AVAudioEngine?
    private var audioFile: AVAudioFile?
    private var isRecording = false
    private var systemAudioDevice: AudioDeviceID?
    private var audioLevelTimer: Timer?
    private let openAIService: OpenAIService
    
    @Published var isRecordingNow = false
    @Published var audioLevel: Float = 0.0
    @Published var transcribedText: String = ""
    @Published var isTranscribing: Bool = false
    @Published var transcriptionError: String?
    
    init() {
        // Загружаем ключ из config.plist
        let configURL = Bundle.main.url(forResource: "config", withExtension: "plist")
        var apiKey: String? = nil
        if let url = configURL, let data = try? Data(contentsOf: url) {
            if let dict = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] {
                apiKey = dict["OPENAI_API_KEY"] as? String
            }
        }
        guard let key = apiKey else {
            fatalError("OPENAI_API_KEY не найден в config.plist")
        }
        self.openAIService = OpenAIService(apiKey: key)
        setupSystemAudioDevice()
    }
    
    deinit {
        cleanup()
    }
    
    private func cleanup() {
        logger.info("Начинаем очистку ресурсов")
        if isRecording {
            logger.info("Останавливаем активную запись")
            stopRecording()
        }
        
        if let engine = audioEngine {
            logger.info("Останавливаем аудио движок")
            engine.stop()
            engine.inputNode.removeTap(onBus: 0)
            audioEngine = nil
        }
        
        if let file = audioFile {
            logger.info("Закрываем аудио файл: \(file.url.path)")
            audioFile = nil
        }
        
        isRecording = false
        isRecordingNow = false
        audioLevel = 0
        logger.info("Очистка ресурсов завершена")
    }
    
    private func setupSystemAudioDevice() {
        var propertySize: UInt32 = 0
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        
        var result = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &propertySize
        )
        
        let deviceCount = Int(propertySize) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: deviceCount)
        
        result = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &propertySize,
            &deviceIDs
        )
        
        for deviceID in deviceIDs {
            var hasOutput = false
            var streamAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreamConfiguration,
                mScope: kAudioDevicePropertyScopeOutput,
                mElement: kAudioObjectPropertyElementMain
            )
            
            var streamSize: UInt32 = 0
            result = AudioObjectGetPropertyDataSize(deviceID, &streamAddress, 0, nil, &streamSize)
            
            let bufferList = UnsafeMutablePointer<AudioBufferList>.allocate(capacity: Int(streamSize))
            result = AudioObjectGetPropertyData(deviceID, &streamAddress, 0, nil, &streamSize, bufferList)
            
            let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
            for buffer in buffers {
                if buffer.mNumberChannels > 0 {
                    hasOutput = true
                    break
                }
            }
            
            bufferList.deallocate()
            
            if hasOutput {
                systemAudioDevice = deviceID
                break
            }
        }
    }
    
    func loadAudioFile() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.audio]
        
        if panel.runModal() == .OK {
            if let fileURL = panel.url {
                logger.info("Выбран файл для расшифровки: \(fileURL.path)")
                Task {
                    await transcribeAudio(fileURL: fileURL)
                }
            }
        }
    }
    
    func startRecording() {
        logger.info("Начинаем запись аудио")
        
        // Очищаем предыдущие ресурсы
        cleanup()
        
        do {
            // Создаем новый аудио движок
            audioEngine = AVAudioEngine()
            
            guard let audioEngine = audioEngine else {
                logger.error("Не удалось создать аудио движок")
                return
            }
            
            let inputNode = audioEngine.inputNode
            let recordingFormat = inputNode.outputFormat(forBus: 0)
            logger.info("Формат записи: \(recordingFormat)")
            
            // Создаем настройки для записи в формате PCM
            let settings: [String: Any] = [
                AVFormatIDKey: Int(kAudioFormatLinearPCM),
                AVSampleRateKey: 44100.0,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false
            ]
            
            let callsFolder = URL(fileURLWithPath: "/Users/stanislavsmirnov/Desktop/calls")
            try? FileManager.default.createDirectory(at: callsFolder, withIntermediateDirectories: true)
            let saveURL = callsFolder.appendingPathComponent("recording_\(Date().timeIntervalSince1970).wav")
            logger.info("Сохранение в папку calls: \(saveURL.path)")
            
            // Проверяем, не существует ли уже файл
            if FileManager.default.fileExists(atPath: saveURL.path) {
                try? FileManager.default.removeItem(at: saveURL)
                logger.info("Удален существующий файл: \(saveURL.path)")
            }
            
            audioFile = try AVAudioFile(forWriting: saveURL, settings: settings)
            logger.info("Аудио файл создан успешно с настройками: \(settings)")
            
            // Настраиваем громкость через аудио движок
            audioEngine.mainMixerNode.outputVolume = 1.0
            
            var bufferCount = 0
            inputNode.installTap(onBus: 0, bufferSize: 4096, format: recordingFormat) { buffer, time in
                do {
                    // Усиливаем сигнал перед записью
                    let channelData = buffer.floatChannelData?[0]
                    let frameLength = UInt32(buffer.frameLength)
                    let gain: Float = 2.0 // Усиление в 2 раза
                    
                    // Создаем временный буфер для усиленного сигнала
                    let tempBuffer = AVAudioPCMBuffer(pcmFormat: recordingFormat, frameCapacity: frameLength)!
                    tempBuffer.frameLength = frameLength
                    
                    // Копируем и усиливаем данные
                    for i in 0..<Int(frameLength) {
                        tempBuffer.floatChannelData?[0][i] = (channelData?[i] ?? 0) * gain
                    }
                    
                    try self.audioFile?.write(from: tempBuffer)
                    bufferCount += 1
                    
                    if bufferCount % 100 == 0 {
                        logger.info("Записано буферов: \(bufferCount)")
                    }
                } catch {
                    logger.error("Ошибка при записи буфера: \(error.localizedDescription)")
                }
                
                // Calculate audio level with enhanced sensitivity
                let channelData = buffer.floatChannelData?[0]
                let frameLength = UInt32(buffer.frameLength)
                var sum: Float = 0
                var peak: Float = 0
                
                for i in 0..<Int(frameLength) {
                    let sample = abs(channelData?[i] ?? 0)
                    sum += sample * sample
                    peak = max(peak, sample)
                }
                
                let rms = sqrt(sum / Float(frameLength))
                let db = 20 * log10(rms)
                
                // Используем и RMS, и пиковое значение для более чувствительной визуализации
                let normalizedValue = min(1.0, max(0.0, (db + 10) / 10)) // Уменьшаем диапазон для большей чувствительности
                let peakValue = min(1.0, max(0.0, peak * 5)) // Усиливаем пиковые значения
                
                DispatchQueue.main.async {
                    // Комбинируем RMS и пиковое значение для более динамичной визуализации
                    let combinedValue = (normalizedValue + peakValue) / 2
                    self.audioLevel = combinedValue
                }
            }
            
            audioEngine.prepare()
            try audioEngine.start()
            
            isRecording = true
            isRecordingNow = true
            logger.info("Запись успешно начата")
            
        } catch {
            logger.error("Ошибка при записи: \(error.localizedDescription)")
            print("Ошибка при записи: \(error.localizedDescription)")
        }
    }
    
    func stopRecording() {
        logger.info("Останавливаем запись")
        
        if let audioEngine = audioEngine {
            audioEngine.stop()
            audioEngine.inputNode.removeTap(onBus: 0)
        }
        
        if let audioFile = audioFile {
            let fileURL = audioFile.url
            logger.info("Аудио файл сохранен: \(fileURL.path)")
            
            // Проверяем размер файла
            if let fileSize = try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? Int64 {
                logger.info("Размер файла: \(fileSize) байт")
            }
            
            // Проверяем, что файл существует и доступен
            if FileManager.default.fileExists(atPath: fileURL.path) {
                logger.info("Файл существует и доступен")
                if let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path) {
                    logger.info("Атрибуты файла: \(attributes)")
                }
            } else {
                logger.error("Файл не существует после записи!")
            }
            
            self.audioFile = nil
            isRecording = false
            isRecordingNow = false
            audioLevel = 0
            
            // Запускаем расшифровку
            logger.info("Запускаем процесс расшифровки")
            Task {
                await transcribeAudio(fileURL: fileURL)
            }
        } else {
            logger.warning("Нет активного аудио файла для остановки")
        }
    }
    
    private func transcribeAudio(fileURL: URL) async {
        DispatchQueue.main.async {
            self.isTranscribing = true
            self.transcriptionError = nil
        }
        
        do {
            let text = try await openAIService.transcribeAudio(fileURL: fileURL)
            
            // Создаем папку calls_texts в папке calls
            let callsFolder = URL(fileURLWithPath: "/Users/stanislavsmirnov/Desktop/calls")
            let textsFolderURL = callsFolder.appendingPathComponent("calls_texts", isDirectory: true)
            try? FileManager.default.createDirectory(at: textsFolderURL, withIntermediateDirectories: true)
            
            // Форматируем дату и время
            let dateFormatter = DateFormatter()
            dateFormatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
            let timestamp = dateFormatter.string(from: Date())
            
            // Создаем имя файла с датой и временем
            let textFileName = "call_\(timestamp).txt"
            let textFileURL = textsFolderURL.appendingPathComponent(textFileName)
            
            // Сохраняем текст в файл с UTF-8 BOM
            var textData = Data([0xEF, 0xBB, 0xBF]) // UTF-8 BOM
            textData.append(text.data(using: .utf8)!)
            try textData.write(to: textFileURL)
            
            logger.info("Текст сохранен в файл: \(textFileURL.path)")
            
            DispatchQueue.main.async {
                self.transcribedText = text
                self.isTranscribing = false
            }
        } catch {
            logger.error("Ошибка при расшифровке: \(error.localizedDescription)")
            DispatchQueue.main.async {
                self.transcriptionError = error.localizedDescription
                self.isTranscribing = false
            }
        }
    }
}

struct AudioLevelView: View {
    let level: Float
    
    var body: some View {
        GeometryReader { geometry in
            Path { path in
                let width = geometry.size.width
                let height = geometry.size.height
                let midHeight = height / 2
                let amplitude = height * 2.0 * CGFloat(level) // Увеличиваем амплитуду
                
                path.move(to: CGPoint(x: 0, y: midHeight))
                
                let points = 8 // Увеличиваем количество точек
                let segmentWidth = width / CGFloat(points)
                
                for i in 0..<points {
                    let x = CGFloat(i) * segmentWidth
                    let nextX = CGFloat(i + 1) * segmentWidth
                    let controlX1 = x + segmentWidth * 0.25
                    let controlX2 = x + segmentWidth * 0.75
                    
                    // Добавляем более сильные случайные колебания
                    let randomFactor = CGFloat.random(in: 0.7...1.3)
                    let currentAmplitude = amplitude * randomFactor
                    
                    path.addCurve(
                        to: CGPoint(x: nextX, y: midHeight),
                        control1: CGPoint(x: controlX1, y: midHeight - currentAmplitude),
                        control2: CGPoint(x: controlX2, y: midHeight + currentAmplitude)
                    )
                }
            }
            .stroke(Color.blue, lineWidth: 2)
        }
        .frame(height: 20)
    }
}

struct FolderPathView: View {
    let path: String
    
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "folder")
                .foregroundColor(.secondary)
            Text(path)
                .font(.caption)
                .foregroundColor(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.secondary.opacity(0.1))
        .cornerRadius(6)
    }
}

struct ContentView: View {
    @StateObject private var audioRecorder = AudioRecorder()
    
    var body: some View {
        VStack(spacing: 8) {
            if audioRecorder.isRecordingNow {
                AudioLevelView(level: audioRecorder.audioLevel)
                    .padding(.horizontal)
            }
            
            HStack {
                Button(action: {
                    if audioRecorder.isRecordingNow {
                        audioRecorder.stopRecording()
                    } else {
                        audioRecorder.startRecording()
                    }
                }) {
                    Image(systemName: audioRecorder.isRecordingNow ? "stop.circle.fill" : "record.circle")
                        .font(.title)
                        .foregroundColor(audioRecorder.isRecordingNow ? .red : .blue)
                }
                .buttonStyle(.plain)
                .help(audioRecorder.isRecordingNow ? "Остановить запись" : "Начать запись")
                
                Button(action: {
                    audioRecorder.loadAudioFile()
                }) {
                    Image(systemName: "square.and.arrow.down")
                        .font(.title2)
                }
                .buttonStyle(.plain)
                .help("Загрузить аудиофайл")
            }
            .padding()
            
            if audioRecorder.isTranscribing {
                ProgressView("Расшифровка аудио...")
                    .padding()
            }
            
            if let error = audioRecorder.transcriptionError {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.red)
                    Text("Ошибка")
                        .foregroundColor(.red)
                }
                .padding()
            } else if !audioRecorder.transcribedText.isEmpty {
                HStack {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                    Text("Запись сохранена")
                        .foregroundColor(.green)
                }
                .padding()
            }
        }
        .frame(width: 300, height: 400)
    }
}

#Preview {
    ContentView()
} 