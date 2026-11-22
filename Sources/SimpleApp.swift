import SwiftUI

@main
struct SimpleApp: App {
    var body: some Scene {
        WindowGroup { ContentView() }
    }
}

struct ContentView: View {
    @AppStorage("count") private var count = 0

    var body: some View {
        VStack(spacing: 32) {
            Text("\(count)")
                .font(.system(size: 96, weight: .bold, design: .rounded))
            Button {
                count += 1
            } label: {
                Text("Tap")
                    .font(.title2.bold())
                    .frame(width: 200, height: 60)
                    .background(Color.blue)
                    .foregroundColor(.white)
                    .clipShape(Capsule())
            }
            Button("Reset") { count = 0 }
                .foregroundColor(.red)
        }
    }
}
