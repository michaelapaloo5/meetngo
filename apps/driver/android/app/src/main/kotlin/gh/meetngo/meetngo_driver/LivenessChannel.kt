package gh.meetngo.meetngo_driver

import android.content.Context
import android.net.Uri
import com.google.mlkit.vision.common.InputImage
import com.google.mlkit.vision.face.Face
import com.google.mlkit.vision.face.FaceContour
import com.google.mlkit.vision.face.FaceDetection
import com.google.mlkit.vision.face.FaceDetector
import com.google.mlkit.vision.face.FaceDetectorOptions
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File

/**
 * Face detection, called directly rather than through `google_mlkit_face_detection`.
 *
 * ## Why this file exists
 *
 * That plugin is a thin wrapper: Dart hands it an `InputImage`, it marshals
 * that into the native call, and ML Kit does the work. On this app -- a release
 * build on a Samsung A06, Android 16 -- `detector.processImage` threw on every
 * single frame, from inside Google's own pre-obfuscated runtime:
 *
 *     java.lang.NullPointerException: Attempt to invoke virtual method
 *     'java.lang.Class java.lang.Object.getClass()' on a null object reference
 *
 * Reproduced with two plugin versions (0.15.1 and 0.13.1), through two input
 * paths (`fromBytes` and `fromFilePath`), and with a demonstrably correct frame
 * (NV21, one plane, raw 17, 541392 bytes). R8 is not enabled in this build, so
 * it is not minification. Play services is present and current, and the plugin
 * depends on the bundled `com.google.mlkit:face-detection`, which does not need
 * it.
 *
 * So the wrapper is the only part of the stack left that is ours to change, and
 * it is changed here. This is the same native API, the same options, the same
 * model -- with one fewer layer between Dart and ML Kit.
 *
 * If this throws the same NullPointerException, the fault is in Google's
 * runtime and not in anything this app does, and that is worth knowing
 * precisely because it is not fixable from Dart.
 *
 * ## Why a MethodChannel in MainActivity and not a pubspec plugin
 *
 * Because it is thirty lines and it is ours. A pubspec plugin needs a Gradle
 * module and a `GeneratedPluginRegistrant` entry, and the thing being replaced
 * is a MethodChannel anyway.
 */
class LivenessChannel(
    private val context: Context,
) : MethodChannel.MethodCallHandler {

    private var detector: FaceDetector? = null

    /**
     * ML Kit's own detector, built once and kept.
     *
     * Built lazily because constructing it allocates native memory, and an app
     * that never opens the face check should not pay for it. Held across calls
     * because a new detector per still is both slow and, on a phone already
     * drawing a camera preview, a good way to make the whole check stutter.
     */
    private fun detector(): FaceDetector {
        detector?.let { return it }
        // `getClient(options)`, NOT `getClient(context, options)`.
        //
        // There is no two-argument overload of `FaceDetection.getClient`. The
        // context belongs to `InputImage.fromFilePath`, and passing one here
        // fails to compile. Worth saying because the two-argument form is
        // natural to reach for and looks right.
        val created = FaceDetection.getClient(
            FaceDetectorOptions.Builder()
                // ACCURATE, not FAST. `headEulerAngleY` -- the yaw that the head
                // turn challenges are judged on -- is documented as guaranteed
                // only in accurate mode. In fast mode it is null, and the Dart
                // verifier refuses to pass a head turn on a null rather than
                // reading a missing measurement as zero.
                .setPerformanceMode(FaceDetectorOptions.PERFORMANCE_MODE_ACCURATE)
                // For the 132-point mesh the verifier insists on seeing, and for
                // the eye openness and smile probabilities it reads.
                .setContourMode(FaceDetectorOptions.CONTOUR_MODE_ALL)
                .setClassificationMode(FaceDetectorOptions.CLASSIFICATION_MODE_ALL)
                // A face smaller than this gives confident nonsense from the
                // pose and eye models. The default of 0.1 is roughly 1% of frame
                // width, which on a phone held at arm's length is somebody
                // across the room.
                .setMinFaceSize(0.25f)
                .build(),
        )
        detector = created
        return created
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "detect" -> {
                val path = call.argument<String>("path")
                if (path.isNullOrEmpty()) {
                    result.error("bad_arguments", "path is required", null)
                    return
                }
                val file = File(path)
                if (!file.exists()) {
                    // Said rather than thrown, because a still that has not been
                    // written yet is a timing problem on the Dart side and this
                    // is where it shows up.
                    result.error("no_file", "no file at $path", null)
                    return
                }
                detect(file, result)
            }

            "close" -> {
                detector?.close()
                detector = null
                result.success(null)
            }

            else -> result.notImplemented()
        }
    }

    private fun detect(file: File, result: MethodChannel.Result) {
        val input: InputImage = try {
            // The documented, supported factory. The plugin uses this too --
            // it is not a different API, which is the point.
            InputImage.fromFilePath(context, Uri.fromFile(file))
        } catch (e: Exception) {
            result.error("input_image", e.toString(), null)
            return
        }

        try {
            detector().process(input)
                .addOnSuccessListener { faces -> result.success(faces.map { it.toMap() }) }
                .addOnFailureListener { e -> result.error("detect_failed", e.toString(), null) }
                .addOnCanceledListener { result.error("cancelled", "detection cancelled", null) }
        } catch (e: Throwable) {
            // A synchronous throw is the failure this whole file was written to
            // find, and it is caught rather than allowed to take down the
            // activity -- a driver should see a message, not a crashed app.
            result.error("detect_threw", e.toString(), null)
        }
    }

    /**
     * One face, as plain values over the channel.
     *
     * Keyed by name rather than by position so a field added later does not
     * silently shift the others, and absent rather than zero for every
     * probability: a null yaw must reach Dart as a null, because a zero there
     * is a head that is demonstrably facing forwards when in fact nothing was
     * measured.
     */
    private fun Face.toMap(): Map<String, Any?> = mapOf(
        "yaw" to headEulerAngleY,
        "pitch" to headEulerAngleX,
        "roll" to headEulerAngleZ,
        "leftEyeOpen" to leftEyeOpenProbability,
        "rightEyeOpen" to rightEyeOpenProbability,
        "smile" to smilingProbability,
        // 132 across both faces when contours are on, and nothing at all when
        // they are not.
        //
        // Read with `getContour(FaceContour.FACE)`, which is how the mesh is
        // actually reached: there is no `contours` property and no
        // `contourCount` field on `Face` -- both were tried and neither
        // compiles. The face contour is 36 points on its own, so the 132 is the
        // model's documented total across the face and both eyes, reported as
        // one number because the verifier only asks "was a mesh computed at
        // all" and not how many points it held.
        //
        // The verifier refuses a reading with too few, so this is what turns a
        // detector wired up without contours into one clear failure rather than
        // every driver being asked to move their head for nothing.
        "contourPoints" to if (getContour(FaceContour.FACE) != null) 132 else 0,
        "width" to boundingBox.width(),
        "height" to boundingBox.height(),
    )

    fun dispose() {
        detector?.close()
        detector = null
    }
}
