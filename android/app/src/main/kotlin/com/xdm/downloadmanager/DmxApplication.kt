package com.xdm.downloadmanager

import android.app.Application
import android.system.Os
import android.util.Base64
import android.util.Log
import java.io.File
import java.io.FileInputStream
import java.security.cert.CertificateFactory

/**
 * Process-level setup shared by the foreground and background Flutter engines.
 *
 * The libtorrent 2.1.1 Android binary uses OpenSSL for HTTPS tracker/web-seed
 * connections and requires SSL_CERT_FILE to be present before its session is
 * created. Android stores its trusted roots as individual DER files, so build
 * one PEM bundle in the app's private files directory and export its path
 * before Flutter (and the background service) can initialize libtorrent.
 */
class DmxApplication : Application() {
    override fun onCreate() {
        super.onCreate()
        configureLibtorrentCertificates()
    }

    private fun configureLibtorrentCertificates() {
        val bundle = File(filesDir, "libtorrent-ca-bundle.pem")
        try {
            if (!bundle.exists() || bundle.length() == 0L) {
                createCaBundle(bundle)
            }
            if (bundle.isFile && bundle.length() > 0L) {
                // Os.setenv updates the native process environment, which is
                // what the libtorrent/OpenSSL code reads via getenv().
                Os.setenv("SSL_CERT_FILE", bundle.absolutePath, true)
                Log.i(TAG, "Configured libtorrent SSL_CERT_FILE: ${bundle.absolutePath}")
            } else {
                Log.w(TAG, "Could not create a trusted CA bundle for libtorrent")
            }
        } catch (error: Exception) {
            Log.e(TAG, "Failed to configure libtorrent SSL_CERT_FILE", error)
        }
    }

    private fun createCaBundle(destination: File) {
        val factory = CertificateFactory.getInstance("X.509")
        val pem = StringBuilder()
        val systemCertFiles = listOf(
            File("/system/etc/security/cacerts"),
            File("/apex/com.android.conscrypt/cacerts"),
        ).asSequence()
            .filter { it.isDirectory }
            .flatMap { directory ->
                directory.listFiles()
                    .orEmpty()
                    .asSequence()
                    .filter { it.isFile && it.name.matches(Regex("[0-9a-fA-F]+\\.\\d+")) }
            }
            .distinctBy { it.absolutePath }
            .sortedBy { it.name }

        systemCertFiles.forEach { certFile ->
            try {
                FileInputStream(certFile).use { input ->
                    val certificate = factory.generateCertificate(input)
                    val encoded = Base64.encodeToString(certificate.encoded, Base64.NO_WRAP)
                    pem.append("-----BEGIN CERTIFICATE-----\n")
                    encoded.chunked(64).forEach { line -> pem.append(line).append('\n') }
                    pem.append("-----END CERTIFICATE-----\n")
                }
            } catch (_: Exception) {
                // Ignore an individual incompatible/invalid system entry.
            }
        }

        if (pem.isNotEmpty()) {
            destination.writeText(pem.toString(), Charsets.US_ASCII)
        }
    }

    companion object {
        private const val TAG = "DmxApplication"
    }
}
