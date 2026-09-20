package com.hoilai.mm.music

import android.content.Intent
import android.os.IBinder
import com.ryanheise.audioservice.AudioService

/**
 * Exposes audio_service's existing MediaBrowser session to vivo MusicWidgetMix.
 *
 * OriginOS binds cooperating players with a vendor-specific action. AudioService
 * only recognises the standard MediaBrowserService action, so translate the
 * action before delegating while keeping the same session and binder.
 */
class VivoAudioService : AudioService() {
    override fun onBind(intent: Intent?): IBinder? {
        if (intent?.action == VIVO_MUSIC_WIDGET_SERVICE) {
            return super.onBind(Intent(MEDIA_BROWSER_SERVICE))
        }
        return super.onBind(intent)
    }

    private companion object {
        const val VIVO_MUSIC_WIDGET_SERVICE = "com.vivo.musicwidgetmix.support.service"
        const val MEDIA_BROWSER_SERVICE = "android.media.browse.MediaBrowserService"
    }
}
