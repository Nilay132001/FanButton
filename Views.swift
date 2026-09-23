import SwiftUI

/// Temperatures and fan speeds, shown in both the panel and the widget.
struct ReadingsView: View {
    @ObservedObject var model: FanModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let status = model.status {
                HStack(spacing: 16) {
                    temperature("CPU", status.cpu)
                    temperature("GPU", status.gpu)
                }
                ForEach(status.fans, id: \.index) { fan in
                    HStack {
                        Image(systemName: "fanblades")
                        Text("Fan \(fan.index + 1)")
                        Spacer()
                        Text("\(fan.actualRpm) rpm").monospacedDigit()
                        Text(fan.mode == "manual" ? "Manual" : "Auto")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(width: 44, alignment: .trailing)
                    }
                }
            } else if model.error == nil {
                Text("Reading sensors…").foregroundStyle(.secondary)
            }
            if let error = model.error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func temperature(_ label: String, _ value: Double?) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value.map { "\(Int($0.rounded()))°C" } ?? "—")
                .font(.title2.weight(.semibold))
                .monospacedDigit()
        }
    }
}

/// What the menu-bar icon opens.
struct PanelView: View {
    @ObservedObject var model: FanModel
    var onPopOut: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ReadingsView(model: model)
            Divider()
            speedControl
            HStack {
                Button("Boost fans", action: model.boost)
                Button("Automatic (macOS)", action: model.automatic)
            }
            .disabled(model.busy || model.status == nil)
            Divider()
            HStack {
                Button("Pop out as widget", action: onPopOut)
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }
        }
        .padding(14)
        .frame(width: 290)
    }

    @ViewBuilder private var speedControl: some View {
        let floor = Double(model.floor), ceiling = Double(model.ceiling)
        if ceiling > floor {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Fan speed")
                    Spacer()
                    Text("\(Int(model.target)) rpm").monospacedDigit()
                }
                Slider(value: $model.target, in: floor...ceiling, step: 100)
                HStack {
                    Text("Lowest is the speed macOS picked itself.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Apply", action: model.apply).disabled(model.busy)
                }
            }
        } else if model.status != nil {
            Text("Fans are already at full speed.").font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// The floating desktop widget.
struct WidgetView: View {
    @ObservedObject var model: FanModel
    var onClose: () -> Void

    var body: some View {
        ReadingsView(model: model)
            .padding(12)
            .padding(.top, 6)
            .frame(width: 210, alignment: .leading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
            .overlay(alignment: .topTrailing) {
                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .padding(6)
                .help("Close widget")
            }
    }
}
