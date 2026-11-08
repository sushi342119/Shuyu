package app.shuyu.reader

import android.app.Activity
import android.app.Instrumentation
import android.os.Bundle

/** Instrumentation runner for speech synthesis verification in the QA package. */
class SessionFixtureInstrumentation : Instrumentation() {
    override fun onCreate(arguments: Bundle?) {
        super.onCreate(arguments)
        start()
    }

    override fun onStart() {
        val results = Bundle()
        val context = targetContext
        try {
            check(context.packageName.endsWith(".render_probe"))
            SpeechFixture.run(context, results)
            finish(Activity.RESULT_OK, results)
        } catch (failure: Throwable) {
            results.putString("stream", "SPEECH_FIXTURE_FAILURE=${failure.javaClass.simpleName}:${failure.message}\n")
            finish(Activity.RESULT_CANCELED, results)
        }
    }
}
