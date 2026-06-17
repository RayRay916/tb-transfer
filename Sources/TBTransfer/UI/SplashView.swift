import SwiftUI

/// Full-window launch splash shown while AppState performs first discovery.
/// Hosts an animated thunderbolt SF Symbol with a scale+fade entry transition.
struct SplashView: View {
    @Environment(AppState.self) private var app
    @State private var isVisible = false

    var body: some View {
        ZStack {
            // Native-looking translucent background so the splash matches the
            // window's vibrancy even while content is loading.
            Rectangle()
                .fill(.regularMaterial)
                .ignoresSafeArea()

            VStack(spacing: 18) {
                Image(systemName: "bolt.fill")
                    .font(.system(size: 120, weight: .bold))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(
                        .linearGradient(
                            colors: [.accentColor, .blue.opacity(0.7)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .symbolEffect(
                        .variableColor.iterative.reversing,
                        options: .repeating
                    )
                    .shadow(color: .accentColor.opacity(0.35), radius: 18, x: 0, y: 4)

                Text("TBTransfer")
                    .font(.largeTitle.bold())

                Text(app.statusLine)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)

                ProgressView()
                    .progressViewStyle(.linear)
                    .tint(.accentColor)
                    .frame(width: 220)
                    .padding(.top, 4)
            }
            .padding(40)
            .scaleEffect(isVisible ? 1.0 : 0.92)
            .opacity(isVisible ? 1.0 : 0.0)
            .animation(.easeOut(duration: 0.25), value: isVisible)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { isVisible = true }
    }
}

#Preview {
    SplashView()
        .environment(AppState())
        .frame(width: 900, height: 560)
}
