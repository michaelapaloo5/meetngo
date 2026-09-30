package gh.meetngo.meetngo_driver

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

    private var liveness: LivenessChannel? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // Registered by hand rather than through pubspec, because the thing it
        // replaces was a MethodChannel plugin and this is thirty lines. See
        // LivenessChannel for why the plugin is not being used at all.
        val channel = LivenessChannel(applicationContext)
        liveness = channel
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            LIVENESS_CHANNEL,
        ).setMethodCallHandler(channel)
    }

    override fun onDestroy() {
        // The detector holds native memory. Leaving it open leaks it on every
        // rotation, and a driver turning their phone to get the light better is
        // the single most likely rotation in this app.
        liveness?.dispose()
        liveness = null
        super.onDestroy()
    }

    private companion object {
        const val LIVENESS_CHANNEL = "gh.meetngo.meetngo_driver/liveness"
    }
}
