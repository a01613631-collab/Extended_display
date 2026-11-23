import SwiftUI

/// Contenido del menú de la barra (estilo ventana).
struct MenuView: View {
    @EnvironmentObject private var model: AppModel
    @State private var showAdvanced = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if !model.problems.isEmpty { problemsSection }
            if model.status.phase != .waiting { sessionSection }
            Divider()
            displaySection
            connectionSection
            DisclosureGroup("Avanzado", isExpanded: $showAdvanced) {
                advancedSection.padding(.top, 6)
            }
            Divider()
            actions
            if let message = model.status.recordingMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
        .padding(14)
        .frame(width: 380)
        .onAppear { model.refreshPermissions() }
    }

    // MARK: - Encabezado

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: model.menuBarSymbol)
                .font(.title2)
                .foregroundStyle(statusColor)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text("TabDisplay").font(.headline)
                Text(statusText).font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private var statusText: String {
        let status = model.status
        switch status.phase {
        case .waiting:
            if let device = model.adb.devices.first(where: \.isReady) {
                return "Tablet por USB (\(device.model ?? device.serial)), esperando la app…"
            }
            return model.settings.wifiEnabled ? "Esperando la tablet (USB o Wi-Fi)" : "Conecta la tablet por USB"
        case .starting:
            return "Iniciando con \(status.deviceName ?? "la tablet")…"
        case .streaming:
            return "Conectada por \(status.transport?.label ?? "?") — \(status.deviceName ?? "tablet")"
        }
    }

    private var statusColor: Color {
        switch model.status.phase {
        case .streaming: return .green
        case .starting: return .orange
        case .waiting: return model.problems.isEmpty ? .secondary : .orange
        }
    }

    // MARK: - Problemas

    private var problemsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(model.problems, id: \.self) { problem in
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                if !model.hasScreenRecording {
                    Button("Permitir Grabación de pantalla") { model.requestScreenRecording() }
                }
                if !model.hasAccessibility {
                    Button("Permitir Accesibilidad") { model.requestAccessibility() }
                }
            }
            .controlSize(.small)
        }
        .padding(10)
        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Sesión

    private var sessionSection: some View {
        let status = model.status
        let metrics = status.metrics
        let tablet = metrics?.tablet
        return VStack(alignment: .leading, spacing: 4) {
            if let error = status.sessionError {
                Label(error, systemImage: "xmark.octagon.fill")
                    .foregroundStyle(.red)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 3) {
                metricRow("Stream", "\(status.streamWidth)×\(status.streamHeight) \(status.codec == .hevc ? "HEVC" : "H.264") @\(status.fps)")
                if let metrics {
                    metricRow("Enviado", String(format: "%.0f fps · %.1f Mbps (objetivo %d)", metrics.fpsSent, metrics.mbpsSent, metrics.bitrate / 1_000_000))
                    metricRow("Codificación", String(format: "%.1f ms por cuadro", metrics.encodeMs))
                    metricRow("Descartados", "\(metrics.droppedFrames + (tablet?.droppedFrames ?? 0))")
                }
                if let tablet {
                    metricRow("Tablet", String(format: "%.0f fps render", tablet.fpsRendered ?? 0))
                    metricRow("Latencia", formatLatency(tablet))
                }
            }
            .font(.callout.monospacedDigit())
        }
    }

    private func metricRow(_ title: String, _ value: String) -> some View {
        GridRow {
            Text(title).foregroundStyle(.secondary)
            Text(value)
        }
    }

    private func formatLatency(_ tablet: TabletStats) -> String {
        let latency = tablet.latencyMs.map { String(format: "%.0f ms captura→pantalla", $0) } ?? "—"
        let rtt = tablet.rttMs.map { String(format: "RTT %.1f ms", $0) } ?? "RTT —"
        return "\(latency) · \(rtt)"
    }

    // MARK: - Pantalla

    private var displaySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Modo", selection: $model.settings.mode) {
                ForEach(DisplayMode.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)

            if model.settings.mode == .extend {
                Picker("Resolución", selection: $model.settings.preset) {
                    ForEach(DisplayPreset.all) { Text($0.label).tag($0) }
                }
            }
            Picker("Códec", selection: $model.settings.codec) {
                ForEach(VideoCodec.allCases) { Text($0.label).tag($0) }
            }
            Toggle("120 Hz (experimental)", isOn: $model.settings.highRefreshRate)
            Picker("Bitrate USB", selection: $model.settings.usbBitrateMbps) {
                ForEach(AppSettings.usbBitrateOptions, id: \.self) { Text("\($0) Mbps").tag($0) }
            }
        }
    }

    // MARK: - Conexión

    private var connectionSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Permitir conexión por Wi-Fi", isOn: $model.settings.wifiEnabled)
            if model.settings.wifiEnabled {
                Picker("Bitrate máximo Wi-Fi", selection: $model.settings.wifiMaxBitrateMbps) {
                    ForEach(AppSettings.wifiBitrateOptions, id: \.self) { Text("\($0) Mbps").tag($0) }
                }
                Text("La tablet se empareja sola la primera vez que se conecta por cable.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Toggle("Abrir al iniciar sesión", isOn: Binding(
                get: { model.launchAtLogin },
                set: { model.setLaunchAtLogin($0) }))
            if let error = model.launchAtLoginError {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
    }

    // MARK: - Avanzado

    private var advancedSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Mantener el monitor al desconectar", selection: $model.settings.gracePeriodSeconds) {
                ForEach(AppSettings.graceOptions, id: \.self) { Text($0 == 0 ? "No" : "\($0) s").tag($0) }
            }
            Toggle("Abrir la app de la tablet al conectar el cable", isOn: $model.settings.autoLaunchTabletApp)
            Toggle("Presión del S Pen como tableta (experimental)", isOn: $model.settings.stylusPressure)
            TextField("Ruta de adb (vacío = automática)", text: $model.settings.adbPath)
                .textFieldStyle(.roundedBorder)
            Text("adb: \(model.adb.adbPath ?? "no encontrado")")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            ForEach(model.adb.devices) { device in
                Label("\(device.model ?? device.serial) — \(deviceStateLabel(device))",
                      systemImage: device.reverseActive ? "cable.connector" : "cable.connector.slash")
                    .font(.caption)
            }
            if model.settings.wifiEnabled {
                Button("Revocar emparejamiento Wi-Fi") { model.revokePairing() }
                    .controlSize(.small)
            }
        }
    }

    private func deviceStateLabel(_ device: DeviceWatcher.Device) -> String {
        switch device.state {
        case "device": return device.reverseActive ? "adb reverse activo" : "conectada"
        case "unauthorized": return "sin autorizar (acepta la huella RSA)"
        case "offline": return "sin conexión"
        default: return device.state
        }
    }

    // MARK: - Acciones

    private var actions: some View {
        HStack {
            Button("Reconectar") { model.reconnect() }
            Button(model.status.isRecording ? "Grabando…" : "Grabar prueba 10 s") { model.recordTest() }
                .disabled(model.status.isRecording || model.status.phase != .waiting)
                .help("Fase 1: graba el monitor a ~/Desktop/test.h264 sin la tablet")
            Spacer()
            Button {
                model.openDisplaySettings()
            } label: {
                Image(systemName: "gearshape")
            }
            .help("Ajustes de Pantallas (acomodar el monitor)")
            Button("Salir") { model.quit() }
        }
        .controlSize(.small)
    }
}
