import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

/// Un cuadro codificado, ya en Annex B.
struct EncodedFrame {
    let data: Data
    let isKeyframe: Bool
    /// Momento de captura (µs, reloj de host): va en el `timestampUs` del VIDEO_FRAME.
    let timestampUs: UInt64
    /// SPS/PPS (+VPS) en Annex B. Solo en keyframes.
    let parameterSets: Data?
    /// Tiempo desde que se entregó el cuadro al codificador hasta que salió.
    let encodeDurationUs: UInt64
}

enum VideoCodec: String, Codable, CaseIterable, Identifiable {
    case h264
    case hevc

    var id: String { rawValue }
    var mime: String { self == .h264 ? CodecMime.h264 : CodecMime.hevc }
    var label: String { self == .h264 ? "H.264" : "HEVC (experimental)" }
    var codecType: CMVideoCodecType { self == .h264 ? kCMVideoCodecType_H264 : kCMVideoCodecType_HEVC }
}

/// VTCompressionSession por hardware en modo de baja latencia. Salida AVCC → Annex B.
/// `encode` y `requestKeyframe` deben llamarse desde una sola cola (la de captura).
final class VideoEncoder {
    enum EncoderError: LocalizedError {
        case createFailed(OSStatus)

        var errorDescription: String? {
            switch self {
            case .createFailed(let status):
                return "No se pudo crear el codificador por hardware (OSStatus \(status))."
            }
        }
    }

    let codec: VideoCodec
    let width: Int
    let height: Int
    let fps: Int
    private(set) var bitrate: Int
    private(set) var lowLatencyMode = false

    /// Se llama en un hilo interno de VideoToolbox.
    var onFrame: ((EncodedFrame) -> Void)?
    /// Se llama cada vez que el codificador termina un cuadro (salga o se descarte), en un hilo
    /// de VideoToolbox. Sirve para alimentar el siguiente cuadro sin hacer fila.
    var onEncodeComplete: (() -> Void)?

    private var session: VTCompressionSession?
    private let lock = NSLock()
    private var forceKeyframe = true
    private var inFlight = 0
    private var lastPtsUs: UInt64 = 0
    private var submitTimes: [UInt64: UInt64] = [:]

    private static let startCode: [UInt8] = [0, 0, 0, 1]

    init(codec: VideoCodec, width: Int, height: Int, fps: Int, bitrate: Int) throws {
        self.codec = codec
        self.width = width
        self.height = height
        self.fps = fps
        self.bitrate = bitrate
        try createSession()
    }

    deinit {
        invalidate()
    }

    func invalidate() {
        lock.lock()
        let session = self.session
        self.session = nil
        lock.unlock()
        if let session {
            VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
            VTCompressionSessionInvalidate(session)
        }
    }

    /// Cuadros entregados al codificador que aún no salen.
    var framesInFlight: Int {
        lock.lock()
        defer { lock.unlock() }
        return inFlight
    }

    func requestKeyframe() {
        lock.lock()
        forceKeyframe = true
        lock.unlock()
    }

    func setBitrate(_ newBitrate: Int) {
        guard newBitrate != bitrate, let session else { return }
        bitrate = newBitrate
        setProperty(session, kVTCompressionPropertyKey_AverageBitRate, NSNumber(value: newBitrate))
        setDataRateLimit(session)
    }

    /// Codifica un cuadro. `timestampUs` es el momento de captura (o "ahora" en re-codificaciones).
    func encode(_ pixelBuffer: CVPixelBuffer, timestampUs: UInt64) {
        lock.lock()
        guard let session else {
            lock.unlock()
            return
        }
        let keyframe = forceKeyframe
        forceKeyframe = false
        // VideoToolbox exige PTS crecientes; una re-codificación puede llegar "antes" que la captura.
        let ptsUs = max(timestampUs, lastPtsUs + 1)
        lastPtsUs = ptsUs
        submitTimes[ptsUs] = HostClock.nowUs()
        if submitTimes.count > 64 { submitTimes.removeAll(keepingCapacity: true) }
        inFlight += 1
        lock.unlock()

        let pts = CMTime(value: CMTimeValue(ptsUs), timescale: 1_000_000)
        let properties: CFDictionary? = keyframe
            ? [kVTEncodeFrameOptionKey_ForceKeyFrame: kCFBooleanTrue] as CFDictionary
            : nil
        let status = VTCompressionSessionEncodeFrame(
            session,
            imageBuffer: pixelBuffer,
            presentationTimeStamp: pts,
            duration: .invalid,
            frameProperties: properties,
            infoFlagsOut: nil
        ) { [weak self] status, flags, sampleBuffer in
            self?.handleOutput(status: status, flags: flags, sampleBuffer: sampleBuffer)
        }
        if status != noErr {
            Log.encoder.error("VTCompressionSessionEncodeFrame: \(status)")
            if keyframe { requestKeyframe() }
            finishFrame()
            return
        }
        // Obliga a VideoToolbox a entregar este cuadro YA, sin esperar al siguiente. Sin esto,
        // el codificador puede retener un cuadro hasta que llega otro: con la pantalla quieta, el
        // final de un trazo del S Pen aparecería hasta 250 ms tarde (el siguiente "refresco").
        // Bloquea la cola de captura solo lo que tarda el hardware (pocos ms).
        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: pts)
    }

    // MARK: - Sesión

    private func createSession() throws {
        // Primero con control de tasa de baja latencia; si el códec no lo soporta (p. ej. -12902
        // con HEVC en algunos chips), se reintenta sin él.
        var lastStatus: OSStatus = noErr
        for lowLatency in [true, false] {
            var specification: [CFString: Any] = [
                kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true,
            ]
            if lowLatency {
                specification[kVTVideoEncoderSpecification_EnableLowLatencyRateControl] = true
            }
            var newSession: VTCompressionSession?
            let status = VTCompressionSessionCreate(
                allocator: nil,
                width: Int32(width),
                height: Int32(height),
                codecType: codec.codecType,
                encoderSpecification: specification as CFDictionary,
                imageBufferAttributes: nil,
                compressedDataAllocator: nil,
                outputCallback: nil,
                refcon: nil,
                compressionSessionOut: &newSession
            )
            if status == noErr, let newSession {
                session = newSession
                lowLatencyMode = lowLatency
                configure(newSession)
                VTCompressionSessionPrepareToEncodeFrames(newSession)
                Log.encoder.info("Codificador \(self.codec.rawValue, privacy: .public) \(self.width)×\(self.height) @\(self.fps) \(self.bitrate / 1_000_000) Mbps, baja latencia: \(lowLatency)")
                return
            }
            lastStatus = status
            Log.encoder.warning("VTCompressionSessionCreate(lowLatency: \(lowLatency)) falló: \(status)")
        }
        throw EncoderError.createFailed(lastStatus)
    }

    private func configure(_ session: VTCompressionSession) {
        setProperty(session, kVTCompressionPropertyKey_RealTime, kCFBooleanTrue)
        setProperty(session, kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse)
        switch codec {
        case .h264:
            // Constrained High = High sin B-frames; si no se acepta, High normal.
            if !setProperty(session, kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_H264_ConstrainedHigh_AutoLevel, quiet: true) {
                setProperty(session, kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_H264_High_AutoLevel)
            }
            setProperty(session, kVTCompressionPropertyKey_H264EntropyMode, kVTH264EntropyMode_CABAC, quiet: true)
        case .hevc:
            setProperty(session, kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_HEVC_Main_AutoLevel)
        }
        setProperty(session, kVTCompressionPropertyKey_ExpectedFrameRate, NSNumber(value: fps))
        setProperty(session, kVTCompressionPropertyKey_AverageBitRate, NSNumber(value: bitrate))
        setDataRateLimit(session)
        // Keyframes bajo demanda; el intervalo máximo solo es una red de seguridad.
        setProperty(session, kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, NSNumber(value: 10))
        setProperty(session, kVTCompressionPropertyKey_MaxKeyFrameInterval, NSNumber(value: fps * 10))
        setProperty(session, kVTCompressionPropertyKey_MaxFrameDelayCount, NSNumber(value: 0), quiet: true)
        setProperty(session, kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality, kCFBooleanTrue, quiet: true)
        // Metadatos de color (VUI) para que la tablet interprete bien el 709 de la captura.
        setProperty(session, kVTCompressionPropertyKey_ColorPrimaries, kCVImageBufferColorPrimaries_ITU_R_709_2, quiet: true)
        setProperty(session, kVTCompressionPropertyKey_TransferFunction, kCVImageBufferTransferFunction_ITU_R_709_2, quiet: true)
        setProperty(session, kVTCompressionPropertyKey_YCbCrMatrix, kCVImageBufferYCbCrMatrix_ITU_R_709_2, quiet: true)
    }

    /// Tope de ráfaga: 1.5× el promedio en ventanas de 1 s, para que un cuadro enorme no
    /// llene el socket de golpe.
    private func setDataRateLimit(_ session: VTCompressionSession) {
        let bytesPerSecond = Double(bitrate) * 1.5 / 8
        let limits = [bytesPerSecond, 1.0] as CFArray
        setProperty(session, kVTCompressionPropertyKey_DataRateLimits, limits, quiet: true)
    }

    @discardableResult
    private func setProperty(_ session: VTCompressionSession, _ key: CFString, _ value: CFTypeRef?, quiet: Bool = false) -> Bool {
        let status = VTSessionSetProperty(session, key: key, value: value)
        if status != noErr && !quiet {
            Log.encoder.warning("No se pudo fijar \(key as String, privacy: .public): \(status)")
        }
        return status == noErr
    }

    // MARK: - Salida

    /// Un cuadro salió (o se descartó) del codificador.
    private func finishFrame() {
        lock.lock()
        inFlight = max(0, inFlight - 1)
        lock.unlock()
        onEncodeComplete?()
    }

    private func handleOutput(status: OSStatus, flags: VTEncodeInfoFlags, sampleBuffer: CMSampleBuffer?) {
        // VideoToolbox llama a este handler exactamente una vez por cuadro entregado.
        defer { finishFrame() }
        guard status == noErr else {
            Log.encoder.error("Error de codificación: \(status)")
            requestKeyframe()
            return
        }
        guard !flags.contains(.frameDropped), let sampleBuffer, CMSampleBufferDataIsReady(sampleBuffer),
              let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer)
        else { return }

        let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[CFString: Any]]
        let notSync = attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool ?? false
        let isKeyframe = !notSync

        // Copia contigua del bloque AVCC.
        let length = CMBlockBufferGetDataLength(blockBuffer)
        var avcc = [UInt8](repeating: 0, count: length)
        guard CMBlockBufferCopyDataBytes(blockBuffer, atOffset: 0, dataLength: length, destination: &avcc) == kCMBlockBufferNoErr else {
            return
        }

        let (parameterSets, nalLengthSize) = Self.parameterSets(formatDescription, codec: codec)
        guard let annexB = Self.annexB(fromAVCC: avcc, nalLengthSize: nalLengthSize) else {
            Log.encoder.error("AVCC mal formado; se pide keyframe")
            requestKeyframe()
            return
        }

        let ptsUs = HostClock.microseconds(sampleBuffer.presentationTimeStamp)
        lock.lock()
        let submitted = submitTimes.removeValue(forKey: ptsUs)
        lock.unlock()
        let now = HostClock.nowUs()
        let encodeDuration = submitted.map { now > $0 ? now - $0 : 0 } ?? 0

        onFrame?(EncodedFrame(
            data: annexB,
            isKeyframe: isKeyframe,
            timestampUs: ptsUs,
            parameterSets: isKeyframe ? parameterSets : nil,
            encodeDurationUs: encodeDuration
        ))
    }

    /// SPS/PPS (H.264) o VPS/SPS/PPS (HEVC) en Annex B, y el tamaño del prefijo de longitud AVCC.
    static func parameterSets(_ format: CMFormatDescription, codec: VideoCodec) -> (Data?, Int) {
        var count = 0
        var nalLength: Int32 = 4
        let status: OSStatus
        switch codec {
        case .h264:
            status = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                format, parameterSetIndex: 0, parameterSetPointerOut: nil, parameterSetSizeOut: nil,
                parameterSetCountOut: &count, nalUnitHeaderLengthOut: &nalLength)
        case .hevc:
            status = CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
                format, parameterSetIndex: 0, parameterSetPointerOut: nil, parameterSetSizeOut: nil,
                parameterSetCountOut: &count, nalUnitHeaderLengthOut: &nalLength)
        }
        guard status == noErr else { return (nil, 4) }

        var data = Data()
        for index in 0..<count {
            var pointer: UnsafePointer<UInt8>?
            var size = 0
            let result: OSStatus
            switch codec {
            case .h264:
                result = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                    format, parameterSetIndex: index, parameterSetPointerOut: &pointer,
                    parameterSetSizeOut: &size, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)
            case .hevc:
                result = CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
                    format, parameterSetIndex: index, parameterSetPointerOut: &pointer,
                    parameterSetSizeOut: &size, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)
            }
            guard result == noErr, let pointer else { continue }
            data.append(contentsOf: startCode)
            data.append(pointer, count: size)
        }
        return (data.isEmpty ? nil : data, Int(nalLength))
    }

    /// Convierte AVCC (prefijo de longitud big-endian por NAL) a Annex B (start codes).
    static func annexB(fromAVCC avcc: [UInt8], nalLengthSize: Int) -> Data? {
        guard (1...4).contains(nalLengthSize) else { return nil }
        var output = Data(capacity: avcc.count + 16)
        var offset = 0
        while offset + nalLengthSize <= avcc.count {
            var nalLength = 0
            for i in 0..<nalLengthSize {
                nalLength = (nalLength << 8) | Int(avcc[offset + i])
            }
            offset += nalLengthSize
            guard nalLength > 0, offset + nalLength <= avcc.count else { return nil }
            output.append(contentsOf: startCode)
            output.append(contentsOf: avcc[offset..<(offset + nalLength)])
            offset += nalLength
        }
        return output
    }
}
