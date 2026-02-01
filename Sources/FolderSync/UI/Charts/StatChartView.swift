import Charts
import SwiftUI

struct StatChartView: View {
    let history: [Double]
    let color: Color
    let title: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Chart {
                ForEach(Array(history.enumerated()), id: \.offset) { index, value in
                    AreaMark(
                        x: .value("Time", index),
                        y: .value("Speed", value)
                    )
                    .foregroundStyle(color.opacity(0.1))
                    .interpolationMethod(.monotone)

                    LineMark(
                        x: .value("Time", index),
                        y: .value("Speed", value)
                    )
                    .foregroundStyle(color)
                    .interpolationMethod(.monotone)
                }
            }
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .chartYScale(domain: 0...max(history.max() ?? 1, 1))
            .frame(height: 30)
            .animation(.easeInOut, value: history)
        }
    }
}
