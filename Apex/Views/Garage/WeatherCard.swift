import SwiftUI

struct WeatherCard: View {
    let weather: WeatherSnapshot?
    let error: String?
    let hasLocation: Bool

    var body: some View {
        Card(title: "Wetter & Fahrbedingungen", symbol: "cloud.sun.fill") {
            if let weather {
                content(weather)
            } else if !hasLocation {
                Text("Erlaube den Standortzugriff, um Wetter und Fahrbedingungen in deiner Nähe zu sehen.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else if let error {
                Label(error, systemImage: "wifi.exclamationmark")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                HStack {
                    ProgressView()
                    Text("Wetter wird geladen …")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private func content(_ w: WeatherSnapshot) -> some View {
        let conditions = DrivingConditions(weather: w)
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: w.condition.symbol)
                .symbolRenderingMode(.multicolor)
                .font(.system(size: 42))
            VStack(alignment: .leading, spacing: 2) {
                Text("\(Int(w.temperature.rounded()))°")
                    .font(.system(size: 42, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                Text("\(w.condition.text) · gefühlt \(Int(w.apparentTemperature.rounded()))°")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Gauge(value: Double(conditions.grip), in: 0...100) {
                Text("Grip")
            } currentValueLabel: {
                Text("\(conditions.grip)")
                    .monospacedDigit()
            }
            .gaugeStyle(.accessoryCircular)
            .tint(Gradient(colors: [.red, .orange, .green]))
        }

        Label(conditions.headline, systemImage: conditions.level.symbol)
            .font(.headline)
            .foregroundStyle(conditions.level.color)

        VStack(alignment: .leading, spacing: 10) {
            ForEach(conditions.items) { item in
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: item.symbol)
                        .foregroundStyle(item.level.color)
                        .frame(width: 24)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.title)
                            .font(.subheadline.weight(.semibold))
                        Text(item.detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }

        HStack(spacing: 0) {
            MiniStat(value: "\(Int(w.windSpeed.rounded()))", caption: "Wind km/h")
            MiniStat(value: "\(Int(w.windGusts.rounded()))", caption: "Böen km/h")
            MiniStat(value: "\(Int(w.humidity.rounded())) %", caption: "Feuchte")
            if let sunset = w.sunset {
                MiniStat(value: Fmt.time(sunset), caption: "Sonnenunterg.")
            }
        }
        .padding(.vertical, 10)
        .background(.background.tertiary, in: .rect(cornerRadius: 14))

        if !w.hours.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 18) {
                    ForEach(w.hours) { hour in
                        VStack(spacing: 6) {
                            Text(hour.date.formatted(.dateTime.hour()))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Image(systemName: WeatherCondition(code: hour.code, isDay: isDay(hour.date, w)).symbol)
                                .symbolRenderingMode(.multicolor)
                                .font(.title3)
                                .frame(height: 24)
                            Text("\(Int(hour.temperature.rounded()))°")
                                .font(.subheadline.weight(.semibold))
                            Text(hour.precipitationProbability > 0 ? "\(hour.precipitationProbability) %" : " ")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.blue)
                        }
                    }
                }
                .padding(.vertical, 4)
            }
        }

        Text("Wetterdaten: Open-Meteo.com (CC BY 4.0)")
            .font(.caption2)
            .foregroundStyle(.tertiary)
    }

    private func isDay(_ date: Date, _ w: WeatherSnapshot) -> Bool {
        guard let sunrise = w.sunrise, let sunset = w.sunset else {
            let hour = Calendar.current.component(.hour, from: date)
            return hour >= 7 && hour < 20
        }
        let calendar = Calendar.current
        let minutes = calendar.component(.hour, from: date) * 60 + calendar.component(.minute, from: date)
        let rise = calendar.component(.hour, from: sunrise) * 60 + calendar.component(.minute, from: sunrise)
        let set = calendar.component(.hour, from: sunset) * 60 + calendar.component(.minute, from: sunset)
        return minutes >= rise && minutes < set
    }
}
