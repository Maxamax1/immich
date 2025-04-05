package app.alextran.immich

import io.flutter.embedding.android.FlutterFragmentActivity // Changed import
import io.flutter.embedding.engine.FlutterEngine
import android.os.Bundle
import android.content.Intent

class MainActivity : FlutterFragmentActivity() { // Changed parent class

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        flutterEngine.plugins.add(BackgroundServicePlugin())
    }

}
