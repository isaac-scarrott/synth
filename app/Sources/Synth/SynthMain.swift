// Process entry: `--browser-check` runs the engine self-check instead of the UI
// (SynthApp keeps everything else).
@main
enum SynthMain {
    @MainActor
    static func main() {
        if CommandLine.arguments.contains("--browser-check") {
            BrowserCheck.run()
        }
        SynthApp.main()
    }
}
